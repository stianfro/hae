import Accelerate
import Foundation

public struct MixerConfiguration: Equatable, Sendable {
  public var sampleRate: Int
  public var systemGain: Float
  public var microphoneGain: Float
  public var outputChunkFrames: Int

  public init(
    sampleRate: Int = 16_000,
    systemGain: Float = 1,
    microphoneGain: Float = 0.9,
    outputChunkFrames: Int = 1_600
  ) {
    self.sampleRate = sampleRate
    self.systemGain = systemGain
    self.microphoneGain = microphoneGain
    self.outputChunkFrames = outputChunkFrames
  }
}

public struct TimelineMixer: Sendable {
  private var systemTimeline = AudioTimeline()
  private var microphoneTimeline = AudioTimeline()
  private var latestSystemEnd: Int64?
  private var latestMicrophoneEnd: Int64?
  private var outputCursor: Int64 = 0

  public let configuration: MixerConfiguration

  public init(configuration: MixerConfiguration = MixerConfiguration()) {
    self.configuration = configuration
  }

  public mutating func ingest(_ buffer: TimedAudioBuffer) -> [[Float]] {
    switch buffer.source {
    case .system:
      systemTimeline.insert(buffer)
      latestSystemEnd = max(latestSystemEnd ?? 0, buffer.endFrame)
    case .microphone:
      microphoneTimeline.insert(buffer)
      latestMicrophoneEnd = max(latestMicrophoneEnd ?? 0, buffer.endFrame)
    }

    guard let latestSystemEnd, let latestMicrophoneEnd else { return [] }
    return drain(upTo: min(latestSystemEnd, latestMicrophoneEnd))
  }

  public mutating func flush() -> [[Float]] {
    let watermark = max(latestSystemEnd ?? 0, latestMicrophoneEnd ?? 0)
    return drain(upTo: watermark)
  }

  private mutating func drain(upTo watermark: Int64) -> [[Float]] {
    guard watermark > outputCursor else { return [] }
    var chunks: [[Float]] = []

    while outputCursor < watermark {
      let count = min(configuration.outputChunkFrames, Int(watermark - outputCursor))
      let system = systemTimeline.read(startFrame: outputCursor, count: count)
      let microphone = microphoneTimeline.read(startFrame: outputCursor, count: count)
      chunks.append(mix(system: system, microphone: microphone))
      outputCursor += Int64(count)
      systemTimeline.discard(before: outputCursor)
      microphoneTimeline.discard(before: outputCursor)
    }
    return chunks
  }

  private func mix(system: [Float], microphone: [Float]) -> [Float] {
    precondition(system.count == microphone.count)
    var systemScaled = [Float](repeating: 0, count: system.count)
    var microphoneScaled = [Float](repeating: 0, count: microphone.count)
    var mixed = [Float](repeating: 0, count: system.count)
    var systemGain = configuration.systemGain
    var microphoneGain = configuration.microphoneGain

    vDSP_vsmul(system, 1, &systemGain, &systemScaled, 1, vDSP_Length(system.count))
    vDSP_vsmul(
      microphone,
      1,
      &microphoneGain,
      &microphoneScaled,
      1,
      vDSP_Length(microphone.count)
    )
    vDSP_vadd(systemScaled, 1, microphoneScaled, 1, &mixed, 1, vDSP_Length(mixed.count))

    for index in mixed.indices {
      let sample = mixed[index]
      let limited = abs(sample) <= 1 ? sample : tanh(sample)
      mixed[index] = min(1, max(-1, limited))
    }
    return mixed
  }
}
