import Foundation

public struct VerifiedModelFiles: Equatable, Sendable {
  public let model: WhisperModelDescriptor
  public let modelURL: URL
  public let vadURL: URL
}

public enum ModelManagerError: Error, LocalizedError, Sendable {
  case invalidManifest
  case noModels
  case missingFile(String)

  public var errorDescription: String? {
    switch self {
    case .invalidManifest:
      "The bundled model manifest is invalid."
    case .noModels:
      "No transcription model is configured."
    case .missingFile(let name):
      "Required local model file is missing: \(name)."
    }
  }
}

public actor ModelManager {
  private let manifest: ModelManifest

  public init(manifest: ModelManifest) {
    self.manifest = manifest
  }

  public static func loadManifest(from url: URL) throws -> ModelManifest {
    try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url))
  }

  public func verifyDefaultModel(in directory: URL) throws -> VerifiedModelFiles {
    guard let model = manifest.models.first else { throw ModelManagerError.noModels }
    let modelURL = directory.appendingPathComponent(model.fileName)
    let vadURL = directory.appendingPathComponent(manifest.vad.fileName)

    for url in [modelURL, vadURL] where !FileManager.default.fileExists(atPath: url.path) {
      throw ModelManagerError.missingFile(url.lastPathComponent)
    }

    try HashVerifier.verify(modelURL, expectedSHA256: model.sha256)
    try HashVerifier.verify(vadURL, expectedSHA256: manifest.vad.sha256)
    return VerifiedModelFiles(model: model, modelURL: modelURL, vadURL: vadURL)
  }
}
