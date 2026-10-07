import Foundation

public enum TranscriptionProvider: String, Codable, CaseIterable, Sendable {
  case local
  case hosted
}

public enum HostedTranscriptionResponseFormat: String, Codable, CaseIterable, Sendable {
  case json
  case verboseJSON = "verbose_json"
}

public struct HostedTranscriptionConfiguration: Codable, Equatable, Sendable {
  public var baseURL: String
  public var model: String
  public var language: String
  public var responseFormat: HostedTranscriptionResponseFormat

  public init(
    baseURL: String = "",
    model: String = "whisper-1",
    language: String = "",
    responseFormat: HostedTranscriptionResponseFormat = .json
  ) {
    self.baseURL = baseURL
    self.model = model
    self.language = language
    self.responseFormat = responseFormat
  }

  public func validatedEndpoint() throws -> URL {
    let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
      var components = URLComponents(string: address),
      components.scheme?.lowercased() == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.port.map({ (1...65_535).contains($0) }) ?? true
    else {
      throw HostedTranscriptionError.invalidBaseURL
    }
    let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !modelName.isEmpty, modelName.count <= 512,
      !modelName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw HostedTranscriptionError.invalidModel
    }
    let languageCode = language.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      languageCode.isEmpty
        || (languageCode.utf8.count == 2
          && languageCode.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }))
    else {
      throw HostedTranscriptionError.invalidLanguage
    }
    components.scheme = "https"
    components.host = host.lowercased()
    if components.port == 443 { components.port = nil }
    while components.percentEncodedPath.hasSuffix("/") {
      components.percentEncodedPath.removeLast()
    }
    guard let url = components.url else { throw HostedTranscriptionError.invalidBaseURL }
    return url.appendingPathComponent("audio").appendingPathComponent("transcriptions")
  }
}

public enum HostedTranscriptionError: Error, LocalizedError, Equatable, Sendable {
  case invalidBaseURL
  case invalidModel
  case invalidLanguage
  case invalidAPIKey
  case invalidAudio
  case unreadableAudio
  case httpStatus(Int)
  case invalidResponse
  case networkFailure
  case timedOut

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      "Enter an HTTPS API base URL without credentials, a query, or a fragment, for example https://api.example.com/v1."
    case .invalidModel:
      "Enter the hosted speech-to-text model ID supplied by your provider."
    case .invalidLanguage:
      "Use a two-letter language code, for example nb or en, or leave language empty for automatic detection."
    case .invalidAPIKey:
      "The API key contains invalid characters. Replace it in Settings."
    case .invalidAudio:
      "The recording is incomplete or is not valid 16 kHz mono PCM audio. Your local recording has not been changed."
    case .unreadableAudio:
      "Hæ could not read the saved recording. Check that its audio file is still available."
    case .httpStatus(let status):
      switch status {
      case 300..<400:
        "The hosted endpoint redirected the request. For privacy, Hæ does not follow redirects. Set the final HTTPS API base URL in Settings."
      case 401, 403:
        "The hosted endpoint rejected access. Check the API key and the model permissions in Settings."
      case 404:
        "The hosted audio transcription endpoint or model was not found. Check the base URL and speech-to-text model ID."
      case 400, 415, 422:
        "The hosted endpoint rejected the audio request. Check the model and response format, and confirm it supports audio/transcriptions with WAV uploads."
      case 413:
        "The hosted endpoint rejected the audio upload size. It must accept WAV chunks of up to 9.6 MB."
      case 429:
        "The hosted endpoint is rate-limiting requests. Wait and retry transcription."
      case 500..<600:
        "The hosted endpoint is temporarily unavailable. Retry transcription later."
      default:
        "The hosted endpoint returned HTTP \(status). Check the endpoint settings and retry transcription."
      }
    case .invalidResponse:
      "The hosted endpoint returned an unsupported transcription response. Use a compatible JSON response format and speech-to-text model."
    case .networkFailure:
      "Hæ could not reach the hosted endpoint securely. Check the URL, network connection, and server certificate."
    case .timedOut:
      "The hosted transcription request timed out. Check the endpoint and retry transcription."
    }
  }
}
