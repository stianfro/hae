import AVFoundation
import Foundation

public struct AudioMeterSnapshot: Equatable, Sendable {
  public let system: Float
  public let microphone: Float

  public init(system: Float, microphone: Float) {
    self.system = system
    self.microphone = microphone
  }
}

public final class AudioPipeline: @unchecked Sendable {
  private struct ConvertedBuffer {
    let source: AudioSource
    let presentationTimeSeconds: Double
    let samples: [Float]
  }

  private let queue = DispatchQueue(label: "no.froystein.hae.audio.processing")
  private let writer: DurablePCMWriter
  private let meterHandler: @Sendable (AudioMeterSnapshot) -> Void
  private var converters: [AudioSource: PCMConverter] = [:]
  private var pendingStartBuffers: [AudioSource: [ConvertedBuffer]] = [:]
  private var mixer = TimelineMixer()
  private var originSeconds: Double?
  private var meterLevels: [AudioSource: Float] = [.system: 0, .microphone: 0]
  private var nextOutputFrame: [AudioSource: Int64] = [:]
  private var lastFedFrame: [AudioSource: Int64] = [:]
  private var lastMeterEmissionNanoseconds: UInt64?
  private var storedError: Error?
  private var isFinishing = false

  public init(
    writer: DurablePCMWriter,
    meterHandler: @escaping @Sendable (AudioMeterSnapshot) -> Void
  ) {
    self.writer = writer
    self.meterHandler = meterHandler
  }

  public func enqueue(_ buffer: CapturedAudioBuffer) {
    queue.async { [self] in
      guard !isFinishing, storedError == nil else { return }
      do {
        let converter: PCMConverter
        if let existing = converters[buffer.source] {
          converter = existing
        } else {
          let created = try PCMConverter()
          converters[buffer.source] = created
          converter = created
        }
        let samples = try converter.convert(buffer.pcmBuffer)
        let converted = ConvertedBuffer(
          source: buffer.source,
          presentationTimeSeconds: buffer.presentationTimeSeconds,
          samples: samples
        )
        accept(converted)
      } catch {
        storedError = error
      }
    }
  }

  public func finish() async throws -> Int64 {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        isFinishing = true
        if originSeconds == nil {
          startTimelineIfPossible(force: true)
        }
        if let originSeconds {
          for (source, converter) in converters {
            do {
              let samples = try converter.finish()
              guard !samples.isEmpty else { continue }
              let startFrame = nextOutputFrame[source] ?? 0
              ingest(
                ConvertedBuffer(
                  source: source,
                  presentationTimeSeconds: originSeconds
                    + Double(startFrame) / PCMConverter.targetSampleRate,
                  samples: samples
                )
              )
            } catch {
              storedError = error
            }
          }
        }
        mixer.flush().forEach(writer.append)
        if let storedError {
          continuation.resume(throwing: storedError)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
    return try await writer.finish()
  }

  public func currentWrittenFrames() async -> Int64 {
    await writer.currentFrameCount()
  }

  private func accept(_ buffer: ConvertedBuffer) {
    meterLevels[buffer.source] = AudioLevelMeter.normalizedLevel(samples: buffer.samples)
    publishMeterIfNeeded()

    if originSeconds == nil {
      pendingStartBuffers[buffer.source, default: []].append(buffer)
      let pending = pendingStartBuffers.values.flatMap { $0 }
      let timestamps = pending.map(\.presentationTimeSeconds)
      let pendingSpan = (timestamps.max() ?? 0) - (timestamps.min() ?? 0)
      startTimelineIfPossible(force: pendingSpan >= 0.5)
      return
    }
    ingest(buffer)
  }

  private func startTimelineIfPossible(force: Bool) {
    let hasBothSources = AudioSource.allCases.allSatisfy {
      !(pendingStartBuffers[$0] ?? []).isEmpty
    }
    guard force || hasBothSources else { return }
    let buffers = pendingStartBuffers.values.flatMap { $0 }
    guard let earliest = buffers.map(\.presentationTimeSeconds).min() else { return }
    originSeconds = earliest
    pendingStartBuffers.removeAll()
    buffers.sorted { $0.presentationTimeSeconds < $1.presentationTimeSeconds }.forEach(ingest)
  }

  private func ingest(_ buffer: ConvertedBuffer) {
    guard let originSeconds else { return }
    let rawStart = (buffer.presentationTimeSeconds - originSeconds) * PCMConverter.targetSampleRate
    var samples = buffer.samples
    var startFrame = Int64(rawStart.rounded())
    if let next = nextOutputFrame[buffer.source],
      abs(startFrame - next) <= Int64(PCMConverter.targetSampleRate * 0.05)
    {
      startFrame = next
    }
    if startFrame < 0 {
      let clipCount = min(samples.count, Int(-startFrame))
      samples.removeFirst(clipCount)
      startFrame = 0
    }
    nextOutputFrame[buffer.source] = startFrame + Int64(samples.count)
    let timed = TimedAudioBuffer(source: buffer.source, startFrame: startFrame, samples: samples)
    feed(timed)
  }

  private func publishMeterIfNeeded() {
    let now = DispatchTime.now().uptimeNanoseconds
    let updateInterval: UInt64 = 100_000_000
    if let lastMeterEmissionNanoseconds,
      now &- lastMeterEmissionNanoseconds < updateInterval
    {
      return
    }
    lastMeterEmissionNanoseconds = now
    meterHandler(
      AudioMeterSnapshot(
        system: meterLevels[.system] ?? 0,
        microphone: meterLevels[.microphone] ?? 0
      )
    )
  }

  private func feed(_ buffer: TimedAudioBuffer) {
    lastFedFrame[buffer.source] = max(lastFedFrame[buffer.source] ?? 0, buffer.endFrame)
    mixer.ingest(buffer).forEach(writer.append)

    let other: AudioSource = buffer.source == .system ? .microphone : .system
    let latenessFrames = Int64(PCMConverter.targetSampleRate * 0.5)
    let safeSilenceEnd = buffer.endFrame - latenessFrames
    let otherEnd = lastFedFrame[other] ?? 0
    guard safeSilenceEnd > otherEnd else { return }

    let silenceCount = Int(safeSilenceEnd - otherEnd)
    let silence = TimedAudioBuffer(
      source: other,
      startFrame: otherEnd,
      samples: [Float](repeating: 0, count: silenceCount)
    )
    lastFedFrame[other] = safeSilenceEnd
    mixer.ingest(silence).forEach(writer.append)
  }
}
