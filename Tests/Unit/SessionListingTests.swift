import Foundation
import Testing

@testable import HaeCore

@Test
func sessionListingDoesNotCreateMissingDirectory() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = SessionRepository(sessionsDirectory: directory)

  #expect(try await repository.listSessions().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test
func sessionListingPreservesActiveStatesAndPartialAudio() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = SessionRepository(sessionsDirectory: directory)
  let model = SessionModelReference(id: "local-model", sha256: String(repeating: "0", count: 64))
  let (recording, recordingPaths) = try await repository.createSession(
    modelReference: model,
    language: "no",
    now: Date(timeIntervalSince1970: 1_700_000_000)
  )
  var (finalizing, finalizingPaths) = try await repository.createSession(
    modelReference: model,
    language: "no",
    now: Date(timeIntervalSince1970: 1_700_000_100)
  )
  try finalizing.transition(to: .captured)
  try finalizing.transition(to: .finalizing)
  try await repository.save(finalizing, paths: finalizingPaths)
  let partialAudio = Data([0, 1, 2, 3, 4])
  try partialAudio.write(to: recordingPaths.mixedPCM)
  try partialAudio.write(to: finalizingPaths.mixedPCM)
  let recordingJSON = try Data(contentsOf: recordingPaths.manifest)
  let finalizingJSON = try Data(contentsOf: finalizingPaths.manifest)

  let sessions = try await repository.listSessions()

  #expect(sessions.map(\.manifest.id) == [finalizing.id, recording.id])
  #expect(sessions.map(\.manifest.status) == [.finalizing, .recording])
  #expect(sessions.allSatisfy { $0.hasAudio })
  #expect(sessions.allSatisfy { !$0.hasTranscript })
  #expect(try Data(contentsOf: recordingPaths.manifest) == recordingJSON)
  #expect(try Data(contentsOf: finalizingPaths.manifest) == finalizingJSON)
  #expect(try Data(contentsOf: recordingPaths.mixedPCM) == partialAudio)
  #expect(try Data(contentsOf: finalizingPaths.mixedPCM) == partialAudio)
}

@Test
func sessionListingRefreshesAvailabilitySnapshots() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = SessionRepository(sessionsDirectory: directory)
  let (_, paths) = try await repository.createSession(
    modelReference: SessionModelReference(id: "local-model", sha256: "hash"),
    language: "no"
  )

  let missing = try #require(try await repository.listSessions().first)
  #expect(!missing.hasAudio)
  #expect(!missing.hasTranscript)

  try Data([1]).write(to: paths.mixedPCM)
  let partial = try #require(try await repository.listSessions().first)
  #expect(!partial.hasAudio)
  #expect(try Data(contentsOf: paths.mixedPCM) == Data([1]))

  try Data([1, 2]).write(to: paths.mixedPCM)
  try Data("Transcript\n".utf8).write(to: paths.transcriptText)
  let available = try #require(try await repository.listSessions().first)
  #expect(available.hasAudio)
  #expect(available.hasTranscript)
  #expect(!missing.hasAudio)
  #expect(!missing.hasTranscript)

  try await repository.deleteAudio(paths: paths)
  try FileManager.default.removeItem(at: paths.transcriptText)
  let deleted = try #require(try await repository.listSessions().first)
  #expect(!deleted.hasAudio)
  #expect(!deleted.hasTranscript)
  #expect(available.hasAudio)
  #expect(available.hasTranscript)
}

@Test
func sessionListingHostedMetadataRoundTripsWithoutCredentials() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = SessionRepository(sessionsDirectory: directory)
  let model = SessionModelReference(id: "hosted-whisper", sha256: "")
  let configuration = HostedTranscriptionConfiguration(
    baseURL: "https://inference.example.com/v1",
    model: model.id,
    language: "no",
    responseFormat: .verboseJSON
  )
  let (manifest, paths) = try await repository.createSession(
    modelReference: model,
    language: configuration.language,
    hostedConfiguration: configuration,
    now: Date(timeIntervalSince1970: 1_700_000_000.5)
  )

  let loaded = try await repository.load(paths: paths)
  #expect(loaded == manifest)
  #expect(loaded.model == model)
  #expect(loaded.language == "no")
  #expect(loaded.hostedConfiguration == configuration)
  #expect(loaded.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
  let listed = try #require(try await repository.listSessions().first)
  #expect(listed.manifest == manifest)

  let encoded = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: paths.manifest)) as? [String: Any]
  )
  let hosted = try #require(encoded["hostedConfiguration"] as? [String: Any])
  #expect(Set(hosted.keys) == ["baseURL", "model", "language", "responseFormat"])
  #expect(encoded["apiKey"] == nil)
  #expect(encoded["authorization"] == nil)
}

@Test
func sessionListingLegacyManifestWithoutHostedConfigurationRemainsLocal() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = SessionRepository(sessionsDirectory: directory)
  let id = UUID()
  let paths = SessionPaths(directory: directory.appendingPathComponent(id.uuidString))
  let legacyJSON = Data(
    """
    {
      "schemaVersion": 1,
      "id": "\(id.uuidString)",
      "title": "Legacy local recording",
      "status": "interrupted",
      "createdAt": "2023-11-14T22:13:20Z",
      "startedAt": "2023-11-14T22:13:20Z",
      "durationFrames": 2,
      "sampleRate": 16000,
      "channels": 1,
      "sampleFormat": "pcm_s16le",
      "model": {"id": "legacy-local-model", "sha256": "legacy-hash"},
      "language": "no",
      "separateTracks": false
    }
    """.utf8
  )
  try AtomicFileWriter.write(legacyJSON, to: paths.manifest)
  try Data([0, 1, 2, 3]).write(to: paths.mixedPCM)

  let loaded = try await repository.load(paths: paths)
  #expect(loaded.id == id)
  #expect(loaded.hostedConfiguration == nil)
  #expect(loaded.model.id == "legacy-local-model")
  let listed = try #require(try await repository.listSessions().first)
  #expect(listed.manifest == loaded)
  #expect(listed.hasAudio)
  #expect(try Data(contentsOf: paths.manifest) == legacyJSON)

  try await repository.save(loaded, paths: paths)
  let roundTripped = try await repository.load(paths: paths)
  #expect(roundTripped == loaded)
  #expect(roundTripped.hostedConfiguration == nil)
}

@Test
func sessionListingPinsOriginalHostedDestinationForRetry() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = SessionRepository(sessionsDirectory: directory)
  let original = HostedTranscriptionConfiguration(
    baseURL: "https://original.example.com/v1", model: "original-model", language: "no"
  )
  var currentConfiguration = original
  var (manifest, paths) = try await repository.createSession(
    modelReference: SessionModelReference(id: currentConfiguration.model, sha256: ""),
    language: currentConfiguration.language,
    hostedConfiguration: currentConfiguration
  )
  currentConfiguration.baseURL = "https://different.example.com/v1"
  currentConfiguration.model = "different-model"
  currentConfiguration.language = "en"
  currentConfiguration.responseFormat = .verboseJSON
  _ = try await repository.createSession(
    modelReference: SessionModelReference(id: currentConfiguration.model, sha256: ""),
    language: currentConfiguration.language,
    hostedConfiguration: currentConfiguration
  )

  try manifest.transition(to: .captured)
  try manifest.transition(to: .finalizing)
  try manifest.transition(to: .failed)
  try await repository.save(manifest, paths: paths)
  var retry = try await repository.load(paths: paths)
  try retry.transition(to: .finalizing)
  try await repository.save(retry, paths: paths)

  let listed = try #require(
    try await repository.listSessions().first { $0.manifest.id == manifest.id }
  )
  #expect(listed.manifest.status == .finalizing)
  #expect(listed.manifest.hostedConfiguration == original)
  #expect(listed.manifest.hostedConfiguration != currentConfiguration)
  #expect(listed.manifest.model.id == original.model)
  #expect(listed.manifest.language == original.language)
}
