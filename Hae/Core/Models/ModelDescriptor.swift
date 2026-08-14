import Foundation

public enum ModelFormat: String, Codable, Sendable {
  case ggml
}

public enum ModelStability: String, Codable, Sendable {
  case stable
  case experimental
}

public struct WhisperModelDescriptor: Codable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let fileName: String
  public let sha256: String
  public let format: ModelFormat
  public let quantization: String
  public let supportedLanguages: [String]
  public let defaultLanguage: String
  public let stability: ModelStability

  public init(
    id: String,
    displayName: String,
    fileName: String,
    sha256: String,
    format: ModelFormat,
    quantization: String,
    supportedLanguages: [String],
    defaultLanguage: String,
    stability: ModelStability
  ) {
    self.id = id
    self.displayName = displayName
    self.fileName = fileName
    self.sha256 = sha256
    self.format = format
    self.quantization = quantization
    self.supportedLanguages = supportedLanguages
    self.defaultLanguage = defaultLanguage
    self.stability = stability
  }
}

public struct ModelManifest: Codable, Equatable, Sendable {
  public let models: [WhisperModelDescriptor]
  public let vad: VADModelDescriptor
}

public struct VADModelDescriptor: Codable, Equatable, Sendable {
  public let fileName: String
  public let sha256: String
}
