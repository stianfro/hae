import Foundation

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let startMs: Int
  public let endMs: Int
  public var text: String
  public let speakerId: String?
  public let source: String
  public let isFinal: Bool

  public init(
    id: UUID = UUID(),
    startMs: Int,
    endMs: Int,
    text: String,
    speakerId: String? = nil,
    source: String = "mixed",
    isFinal: Bool = true
  ) {
    self.id = id
    self.startMs = startMs
    self.endMs = endMs
    self.text = text
    self.speakerId = speakerId
    self.source = source
    self.isFinal = isFinal
  }
}

public struct Transcript: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let sessionID: UUID
  public let isFinal: Bool
  public let segments: [TranscriptSegment]

  public init(sessionID: UUID, isFinal: Bool, segments: [TranscriptSegment]) {
    schemaVersion = 1
    self.sessionID = sessionID
    self.isFinal = isFinal
    self.segments = segments
  }
}
