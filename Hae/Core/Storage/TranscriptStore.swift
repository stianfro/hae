import Foundation

public actor TranscriptStore {
  private let encoder: JSONEncoder

  public init() {
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  public func write(_ transcript: Transcript, paths: SessionPaths, title: String) throws {
    try AtomicFileWriter.write(encoder.encode(transcript), to: paths.transcriptJSON)

    let plainText = transcript.segments.map(\.text).joined(separator: "\n") + "\n"
    try AtomicFileWriter.write(Data(plainText.utf8), to: paths.transcriptText)

    let markdown =
      "# \(title)\n\n"
      + transcript.segments.map { segment in
        "**\(Self.markdownTimestamp(milliseconds: segment.startMs))** \(segment.text)"
      }.joined(separator: "\n\n") + "\n"
    try AtomicFileWriter.write(Data(markdown.utf8), to: paths.transcriptMarkdown)

    let srt = transcript.segments.enumerated().map { index, segment in
      "\(index + 1)\n\(Self.srtTimestamp(milliseconds: segment.startMs)) --> "
        + "\(Self.srtTimestamp(milliseconds: segment.endMs))\n\(segment.text)\n"
    }.joined(separator: "\n")
    try AtomicFileWriter.write(Data(srt.utf8), to: paths.transcriptSRT)
  }

  public static func srtTimestamp(milliseconds: Int) -> String {
    let clamped = max(0, milliseconds)
    let hours = clamped / 3_600_000
    let minutes = (clamped / 60_000) % 60
    let seconds = (clamped / 1_000) % 60
    let remainder = clamped % 1_000
    return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, remainder)
  }

  private static func markdownTimestamp(milliseconds: Int) -> String {
    let totalSeconds = max(0, milliseconds) / 1_000
    return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
  }
}
