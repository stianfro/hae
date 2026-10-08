import Foundation

/// Deliberately limited to typed metadata. Never add request, response, or transcript text.
public struct DiagnosticEvent: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case debugEnabled
    case recordingStarted
    case recordingStopped
    case transcriptionStarted
    case transcriptionSucceeded
    case transcriptionFailed
    case hostedRequestStarted
    case hostedResponseReceived
    case hostedRequestFailed
    case transcriptionCancelled
  }

  public enum Failure: String, Codable, Sendable {
    case invalidConfiguration
    case invalidAPIKey
    case invalidAudio
    case unreadableAudio
    case http
    case invalidResponse
    case network
    case timeout
    case cancelled
    case other
  }

  public let timestamp: Date
  public let kind: Kind
  public let operationID: UUID?
  public let chunk: Int?
  public let chunkCount: Int?
  public let audioBytes: Int?
  public let audioDurationMS: Int?
  public let responseBytes: Int?
  public let elapsedMS: Int?
  public let statusCode: Int?
  public let networkCode: Int?
  public let hasAPIKey: Bool?
  public let responseFormat: HostedTranscriptionResponseFormat?
  public let failure: Failure?

  public init(
    kind: Kind,
    timestamp: Date = Date(),
    operationID: UUID? = nil,
    chunk: Int? = nil,
    chunkCount: Int? = nil,
    audioBytes: Int? = nil,
    audioDurationMS: Int? = nil,
    responseBytes: Int? = nil,
    elapsedMS: Int? = nil,
    statusCode: Int? = nil,
    networkCode: Int? = nil,
    hasAPIKey: Bool? = nil,
    responseFormat: HostedTranscriptionResponseFormat? = nil,
    failure: Failure? = nil
  ) {
    self.timestamp = timestamp
    self.kind = kind
    self.operationID = operationID
    self.chunk = chunk
    self.chunkCount = chunkCount
    self.audioBytes = audioBytes
    self.audioDurationMS = audioDurationMS
    self.responseBytes = responseBytes
    self.elapsedMS = elapsedMS
    self.statusCode = statusCode
    self.networkCode = networkCode
    self.hasAPIKey = hasAPIKey
    self.responseFormat = responseFormat
    self.failure = failure
  }
}
