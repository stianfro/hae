import Foundation
import HaeCore
import Testing

@testable import HaeApplication

@Suite(.serialized)
@MainActor
struct TranscriptionPreferencesTests {
  @Test
  func defaultsToLocalWithoutLookingUpCredentials() {
    withPreferences { preferences, credentials, _ in
      #expect(preferences.provider == .local)
      #expect(preferences.configuration == HostedTranscriptionConfiguration())
      #expect(credentials.lookups.isEmpty)
    }
  }

  @Test
  func persistsConfigurationButNeverAPIKey() throws {
    try withPreferences { preferences, credentials, defaults in
      let configuration = HostedTranscriptionConfiguration(
        baseURL: " https://inference.example.com/v1/ ",
        model: " speech-model ",
        language: " nb ",
        responseFormat: .verboseJSON
      )
      try preferences.save(provider: .hosted, configuration: configuration, apiKey: " secret-key ")
      let restored = TranscriptionPreferences(defaults: defaults, credentials: credentials)
      #expect(restored.provider == .hosted)
      #expect(restored.configuration.baseURL == "https://inference.example.com/v1/")
      #expect(restored.configuration.model == "speech-model")
      #expect(restored.configuration.language == "nb")
      #expect(restored.configuration.responseFormat == .verboseJSON)
      #expect(try restored.apiKey(for: restored.configuration) == "secret-key")
      let data = try #require(defaults.data(forKey: "transcriptionPreferences"))
      #expect(!String(decoding: data, as: UTF8.self).contains("secret-key"))
    }
  }

  @Test
  func usesNormalizedEndpointAndNeverReusesKeyForAnotherServer() throws {
    try withPreferences { preferences, credentials, _ in
      let original = HostedTranscriptionConfiguration(
        baseURL: "HTTPS://Inference.Example.com:443/v1/")
      try preferences.save(provider: .hosted, configuration: original, apiKey: "original-key")
      let equivalent = HostedTranscriptionConfiguration(baseURL: "https://inference.example.com/v1")
      #expect(try preferences.apiKey(for: equivalent) == "original-key")
      let other = HostedTranscriptionConfiguration(baseURL: "https://other.example.com/v1")
      #expect(try preferences.apiKey(for: other) == nil)
      #expect(credentials.values.count == 1)
    }
  }

  @Test
  func leavingKeyUnchangedPreservesItAndEmptyKeyRemovesIt() throws {
    try withPreferences { preferences, _, _ in
      var configuration = HostedTranscriptionConfiguration(
        baseURL: "https://inference.example.com/v1")
      try preferences.save(provider: .hosted, configuration: configuration, apiKey: "original-key")
      configuration.model = "another-speech-model"
      try preferences.save(provider: .hosted, configuration: configuration)
      #expect(try preferences.apiKey(for: configuration) == "original-key")
      try preferences.save(provider: .hosted, configuration: configuration, apiKey: "")
      #expect(try preferences.apiKey(for: configuration) == nil)
    }
  }

  @Test
  func localModeDoesNotRequireHostedConfigurationOrTouchKeychain() throws {
    try withPreferences { preferences, credentials, _ in
      try preferences.save(provider: .local, configuration: HostedTranscriptionConfiguration())
      #expect(preferences.provider == .local)
      #expect(credentials.values.isEmpty)
      #expect(credentials.lookups.isEmpty)
    }
  }

  @Test
  func invalidHostedConfigurationDoesNotChangePreferencesOrCredentials() {
    withPreferences { preferences, credentials, defaults in
      let configuration = HostedTranscriptionConfiguration(
        baseURL: "http://inference.example.com/v1")
      #expect(throws: HostedTranscriptionError.invalidBaseURL) {
        try preferences.save(provider: .hosted, configuration: configuration, apiKey: "secret")
      }
      #expect(preferences.provider == .local)
      #expect(preferences.configuration == HostedTranscriptionConfiguration())
      #expect(defaults.data(forKey: "transcriptionPreferences") == nil)
      #expect(credentials.values.isEmpty)
    }
  }

  @Test
  func failedKeychainSaveDoesNotEnableHostedOrPersistDraft() {
    withPreferences { preferences, credentials, defaults in
      credentials.failSaves = true
      let configuration = HostedTranscriptionConfiguration(
        baseURL: "https://inference.example.com/v1")
      #expect(throws: StubCredentialError.unavailable) {
        try preferences.save(provider: .hosted, configuration: configuration, apiKey: "secret")
      }
      #expect(preferences.provider == .local)
      #expect(defaults.data(forKey: "transcriptionPreferences") == nil)
    }
  }

  @Test
  func corruptStoredPreferencesDefaultToLocal() {
    withPreferences { _, credentials, defaults in
      defaults.set(Data("not valid JSON".utf8), forKey: "transcriptionPreferences")
      let restored = TranscriptionPreferences(defaults: defaults, credentials: credentials)
      #expect(restored.provider == .local)
      #expect(credentials.lookups.isEmpty)
    }
  }

  private func withPreferences(
    _ body: (TranscriptionPreferences, StubCredentialStore, UserDefaults) throws -> Void
  ) rethrows {
    let suite = "no.froystein.hae.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let credentials = StubCredentialStore()
    try body(
      TranscriptionPreferences(defaults: defaults, credentials: credentials), credentials, defaults)
  }
}

private final class StubCredentialStore: HostedCredentialStoring {
  var values: [URL: String] = [:]
  var lookups: [URL] = []
  var failSaves = false

  func apiKey(for endpoint: URL) throws -> String? {
    lookups.append(endpoint)
    return values[endpoint]
  }

  func save(apiKey: String, for endpoint: URL) throws {
    if failSaves { throw StubCredentialError.unavailable }
    values[endpoint] = apiKey.isEmpty ? nil : apiKey
  }
}

private enum StubCredentialError: Error, Equatable {
  case unavailable
}
