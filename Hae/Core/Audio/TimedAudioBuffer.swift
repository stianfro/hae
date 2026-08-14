import Foundation

public enum AudioSource: String, Codable, CaseIterable, Sendable {
  case system
  case microphone
}

public struct TimedAudioBuffer: Equatable, Sendable {
  public let source: AudioSource
  public let startFrame: Int64
  public let samples: [Float]

  public init(source: AudioSource, startFrame: Int64, samples: [Float]) {
    self.source = source
    self.startFrame = startFrame
    self.samples = samples
  }

  public var endFrame: Int64 {
    startFrame + Int64(samples.count)
  }
}

struct AudioTimeline: Sendable {
  private(set) var buffers: [TimedAudioBuffer] = []

  mutating func insert(_ buffer: TimedAudioBuffer) {
    guard !buffer.samples.isEmpty else { return }
    let insertionIndex =
      buffers.firstIndex { existing in
        existing.startFrame > buffer.startFrame
      } ?? buffers.endIndex
    buffers.insert(buffer, at: insertionIndex)
  }

  func read(startFrame: Int64, count: Int) -> [Float] {
    guard count > 0 else { return [] }
    let endFrame = startFrame + Int64(count)
    var output = [Float](repeating: 0, count: count)

    for buffer in buffers {
      if buffer.startFrame >= endFrame { break }
      if buffer.endFrame <= startFrame { continue }

      let overlapStart = max(startFrame, buffer.startFrame)
      let overlapEnd = min(endFrame, buffer.endFrame)
      let sourceOffset = Int(overlapStart - buffer.startFrame)
      let outputOffset = Int(overlapStart - startFrame)
      let overlapCount = Int(overlapEnd - overlapStart)
      output.replaceSubrange(
        outputOffset..<(outputOffset + overlapCount),
        with: buffer.samples[sourceOffset..<(sourceOffset + overlapCount)]
      )
    }
    return output
  }

  mutating func discard(before frame: Int64) {
    buffers.removeAll { $0.endFrame <= frame }
  }
}
