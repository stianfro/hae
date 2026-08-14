import Foundation

public struct FinalTranscriptionService: Sendable {
  public static let windowFrames = 28 * 16_000
  public static let overlapFrames = 44_800

  private let engine: WhisperEngine

  public init(engine: WhisperEngine) {
    self.engine = engine
  }

  public func transcribe(
    pcmURL: URL,
    sessionID: UUID,
    durationFrames: Int64,
    progress: @escaping @Sendable (Double) async -> Void
  ) async throws -> Transcript {
    let reader = try PCMFileReader(url: pcmURL)
    let step = Self.windowFrames - Self.overlapFrames
    var windowStart: Int64 = 0
    var output: [TranscriptSegment] = []

    while windowStart < durationFrames {
      try reader.seek(toFrame: windowStart)
      let remaining = Int(min(Int64(Self.windowFrames), durationFrames - windowStart))
      let samples = try reader.read(frameCount: remaining)
      if samples.isEmpty { break }

      let localSegments = try await engine.transcribe(samples: samples)
      let previousWindowSegment = output.last
      var handledWindowBoundary = previousWindowSegment == nil
      for local in localSegments {
        let offsetMilliseconds = Int(windowStart * 1_000 / 16_000)
        var candidate = TranscriptSegment(
          startMs: local.startMs + offsetMilliseconds,
          endMs: local.endMs + offsetMilliseconds,
          text: local.text
        )
        if let previousWindowSegment, !handledWindowBoundary {
          if candidate.endMs <= previousWindowSegment.endMs { continue }
          candidate.text = TranscriptDeduplicator.removingOverlap(
            previousText: previousWindowSegment.text,
            newText: candidate.text
          )
          handledWindowBoundary = true
        }
        if let previous = output.last {
          if candidate.text.isEmpty || candidate.endMs <= previous.endMs { continue }
          if candidate.startMs < previous.endMs {
            candidate = TranscriptSegment(
              startMs: previous.endMs,
              endMs: max(previous.endMs + 1, candidate.endMs),
              text: candidate.text
            )
          }
        }
        output.append(candidate)
      }

      windowStart += Int64(step)
      await progress(min(1, Double(windowStart) / Double(max(1, durationFrames))))
    }
    await progress(1)
    return Transcript(sessionID: sessionID, isFinal: true, segments: output)
  }
}
