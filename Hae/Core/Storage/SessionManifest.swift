import Foundation

public enum SessionStatus: String, Codable, Sendable {
  case recording
  case captured
  case finalizing
  case completed
  case interrupted
  case failed
}

public struct SessionModelReference: Codable, Equatable, Sendable {
  public let id: String
  public let sha256: String
}

public struct SessionFailure: Codable, Equatable, Sendable {
  public let stage: String
  public let message: String

  public init(stage: String, message: String) {
    self.stage = stage
    self.message = message
  }
}

public struct SessionManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let id: UUID
  public var title: String
  public var status: SessionStatus
  public let createdAt: Date
  public let startedAt: Date
  public var stoppedAt: Date?
  public var durationFrames: Int64
  public let sampleRate: Int
  public let channels: Int
  public let sampleFormat: String
  public let model: SessionModelReference
  public let language: String
  public var captureDisplayID: UInt32?
  public var microphoneDeviceID: String?
  public var separateTracks: Bool
  public var finalizationProgress: Double?
  public var failure: SessionFailure?

  public init(
    id: UUID = UUID(),
    title: String,
    status: SessionStatus = .recording,
    createdAt: Date = Date(),
    startedAt: Date = Date(),
    model: SessionModelReference,
    language: String = "no"
  ) {
    schemaVersion = 1
    self.id = id
    self.title = title
    self.status = status
    self.createdAt = createdAt
    self.startedAt = startedAt
    stoppedAt = nil
    durationFrames = 0
    sampleRate = 16_000
    channels = 1
    sampleFormat = "pcm_s16le"
    self.model = model
    self.language = language
    captureDisplayID = nil
    microphoneDeviceID = nil
    separateTracks = false
    finalizationProgress = nil
    failure = nil
  }
}

public enum SessionTransitionError: Error, Equatable, Sendable {
  case invalid(from: SessionStatus, to: SessionStatus)
}

extension SessionManifest {
  public mutating func transition(to newStatus: SessionStatus) throws {
    let allowed: [SessionStatus: Set<SessionStatus>] = [
      .recording: [.captured, .interrupted, .failed],
      .captured: [.finalizing, .interrupted, .failed],
      .finalizing: [.completed, .interrupted, .failed],
      .completed: [],
      .interrupted: [.finalizing, .failed],
      .failed: [.finalizing],
    ]
    guard allowed[status, default: []].contains(newStatus) else {
      throw SessionTransitionError.invalid(from: status, to: newStatus)
    }
    status = newStatus
  }
}
