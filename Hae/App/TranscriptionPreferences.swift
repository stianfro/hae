import Combine
import Foundation

#if canImport(HaeCore)
  import HaeCore
#endif

@MainActor
final class TranscriptionPreferences: ObservableObject {
  @Published private(set) var provider: TranscriptionProvider
  @Published private(set) var configuration: HostedTranscriptionConfiguration

  private let defaults: UserDefaults
  private let credentials: any HostedCredentialStoring
  private static let preferencesKey = "transcriptionPreferences"

  init(
    defaults: UserDefaults = .standard,
    credentials: any HostedCredentialStoring = HostedCredentialStore()
  ) {
    self.defaults = defaults
    self.credentials = credentials
    let saved = defaults.data(forKey: Self.preferencesKey)
      .flatMap { try? JSONDecoder().decode(SavedPreferences.self, from: $0) }
    provider = saved?.provider ?? .local
    configuration = saved?.configuration ?? HostedTranscriptionConfiguration()
  }

  func apiKey(for configuration: HostedTranscriptionConfiguration) throws -> String? {
    try credentials.apiKey(for: configuration.validatedEndpoint())
  }

  /// A nil API key preserves this endpoint's saved key. An empty key removes it.
  func save(
    provider: TranscriptionProvider,
    configuration: HostedTranscriptionConfiguration,
    apiKey: String? = nil
  ) throws {
    var configuration = configuration
    configuration.baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    configuration.model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
    configuration.language = configuration.language.trimmingCharacters(in: .whitespacesAndNewlines)

    if provider == .hosted {
      _ = try configuration.validatedEndpoint()
    }
    let data = try JSONEncoder().encode(
      SavedPreferences(provider: provider, configuration: configuration)
    )
    if let apiKey {
      try credentials.save(
        apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
        for: configuration.validatedEndpoint()
      )
    }
    defaults.set(data, forKey: Self.preferencesKey)
    self.configuration = configuration
    self.provider = provider
  }
}

private struct SavedPreferences: Codable {
  let provider: TranscriptionProvider
  let configuration: HostedTranscriptionConfiguration
}
