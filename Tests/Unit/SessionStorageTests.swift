import CoreGraphics
import Foundation
import Testing

@testable import HaeCore

@Test
func manifestTransitions() throws {
  var manifest = makeManifest()
  try manifest.transition(to: .captured)
  try manifest.transition(to: .finalizing)
  try manifest.transition(to: .completed)
  #expect(manifest.status == .completed)
  #expect(throws: SessionTransitionError.self) {
    try manifest.transition(to: .recording)
  }
}

@Test
func atomicReplacement() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let destination = directory.appendingPathComponent("value.json")
  defer { try? FileManager.default.removeItem(at: directory) }

  try AtomicFileWriter.write(Data("one".utf8), to: destination)
  try AtomicFileWriter.write(Data("two".utf8), to: destination)
  #expect(try String(contentsOf: destination, encoding: .utf8) == "two")
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["value.json"])
}

@Test
func repositoryRoundTrip() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = SessionRepository(sessionsDirectory: directory)
  let (manifest, paths) = try await repository.createSession(model: makeDescriptor())
  let loaded = try await repository.load(paths: paths)
  #expect(loaded == manifest)
}

@Test
func diskSpacePolicyUsesRequiredThresholds() {
  #expect(
    DiskSpacePolicy.status(availableBytes: 999_999_999) == .critical(availableBytes: 999_999_999))
  #expect(
    DiskSpacePolicy.status(availableBytes: 1_000_000_000) == .warning(availableBytes: 1_000_000_000)
  )
  #expect(
    DiskSpacePolicy.status(availableBytes: 2_999_999_999) == .warning(availableBytes: 2_999_999_999)
  )
  #expect(
    DiskSpacePolicy.status(availableBytes: 3_000_000_000)
      == .sufficient(availableBytes: 3_000_000_000))
}

@Test
func retentionPolicyCalculatesAudioExpiry() throws {
  let stoppedAt = Date(timeIntervalSince1970: 1_700_000_000)
  var manifest = makeManifest()
  manifest.stoppedAt = stoppedAt
  try manifest.transition(to: .captured)
  try manifest.transition(to: .finalizing)
  try manifest.transition(to: .completed)

  #expect(
    !AudioRetentionPolicy.sevenDays.shouldDeleteAudio(
      for: manifest,
      now: stoppedAt.addingTimeInterval(7 * 24 * 60 * 60 - 1)
    )
  )
  #expect(
    AudioRetentionPolicy.sevenDays.shouldDeleteAudio(
      for: manifest,
      now: stoppedAt.addingTimeInterval(7 * 24 * 60 * 60)
    )
  )
  #expect(AudioRetentionPolicy.immediately.shouldDeleteAudio(for: manifest, now: stoppedAt))
  #expect(!AudioRetentionPolicy.forever.shouldDeleteAudio(for: manifest, now: .distantFuture))
}

@Test
func retentionNeverDeletesIncompleteSessionAudio() {
  #expect(!AudioRetentionPolicy.immediately.shouldDeleteAudio(for: makeManifest()))
}

@Test
func recoveryRepairsPartialRecording() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = SessionRepository(sessionsDirectory: directory)
  let (_, paths) = try await repository.createSession(model: makeDescriptor())
  try Data([0, 1, 2, 3, 4]).write(to: paths.mixedPCM)
  let recoveryDate = Date(timeIntervalSince1970: 1_800_000_000)

  let sessions = try await repository.recoverSessions(now: recoveryDate)

  #expect(sessions.count == 1)
  #expect(sessions[0].manifest.status == .interrupted)
  #expect(sessions[0].manifest.durationFrames == 2)
  #expect(sessions[0].manifest.stoppedAt == recoveryDate)
  #expect(sessions[0].manifest.failure?.stage == "recovery")
  #expect(
    try FileManager.default.attributesOfItem(atPath: paths.mixedPCM.path)[.size] as? NSNumber
      == NSNumber(value: 4)
  )
}

@Test
func recoveryMakesInterruptedFinalizationRetryable() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = SessionRepository(sessionsDirectory: directory)
  var (manifest, paths) = try await repository.createSession(model: makeDescriptor())
  try Data([0, 1, 2, 3]).write(to: paths.mixedPCM)
  try manifest.transition(to: .captured)
  try manifest.transition(to: .finalizing)
  try await repository.save(manifest, paths: paths)

  let sessions = try await repository.recoverSessions()

  #expect(sessions[0].manifest.status == .interrupted)
  #expect(sessions[0].manifest.durationFrames == 2)
  #expect(sessions[0].manifest.failure?.stage == "recovery")
}

@Test
func repositoryRenamesAndDeletesSessions() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let repository = SessionRepository(sessionsDirectory: directory)
  let (_, paths) = try await repository.createSession(model: makeDescriptor())
  try Data([0, 1]).write(to: paths.mixedPCM)

  let renamed = try await repository.renameSession(paths: paths, title: "  Weekly sync  ")
  #expect(renamed.title == "Weekly sync")
  await #expect(throws: SessionRepositoryError.emptyTitle) {
    try await repository.renameSession(paths: paths, title: "  ")
  }

  try await repository.deleteAudio(paths: paths)
  #expect(!FileManager.default.fileExists(atPath: paths.mixedPCM.path))
  #expect(FileManager.default.fileExists(atPath: paths.manifest.path))

  try await repository.deleteSession(paths: paths)
  #expect(!FileManager.default.fileExists(atPath: paths.directory.path))
}

@Test
func repositoryExportsTranscriptFormats() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: destination)
  }
  let repository = SessionRepository(sessionsDirectory: directory)
  let (_, paths) = try await repository.createSession(model: makeDescriptor())
  let transcript = Transcript(
    sessionID: UUID(),
    isFinal: true,
    segments: [TranscriptSegment(startMs: 0, endMs: 1_000, text: "Hei")]
  )
  _ = try await repository.renameSession(paths: paths, title: "Test / export")
  try await TranscriptStore().write(transcript, paths: paths, title: "Test / export")

  let exported = try await repository.exportTranscripts(paths: paths, to: destination)

  #expect(exported.lastPathComponent == "Test-export")
  #expect(
    FileManager.default.fileExists(atPath: exported.appendingPathComponent("transcript.json").path))
  #expect(
    FileManager.default.fileExists(atPath: exported.appendingPathComponent("transcript.md").path))
  #expect(
    FileManager.default.fileExists(atPath: exported.appendingPathComponent("transcript.txt").path))
  #expect(
    FileManager.default.fileExists(atPath: exported.appendingPathComponent("transcript.srt").path))
}

@Test
func displaySelectionUsesSavedDisplayAndFallsBack() {
  let displays = [
    CaptureDisplayDevice(id: 10, name: "Main", width: 1_920, height: 1_080),
    CaptureDisplayDevice(id: 20, name: "Second", width: 2_560, height: 1_440),
  ]

  #expect(
    CaptureDisplayRepository.preferredDisplay(from: displays, savedID: 20, mainID: 10)?.id == 20
  )
  #expect(
    CaptureDisplayRepository.preferredDisplay(from: displays, savedID: 30, mainID: 10)?.id == 10
  )
  #expect(CaptureDisplayRepository.preferredDisplay(from: [], savedID: nil, mainID: 10) == nil)
}

@Test
func transcriptStoreWritesCopyReadyPlainText() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let paths = SessionPaths(directory: directory)
  let transcript = Transcript(
    sessionID: UUID(),
    isFinal: true,
    segments: [
      TranscriptSegment(startMs: 0, endMs: 1_000, text: "Første linje."),
      TranscriptSegment(startMs: 1_000, endMs: 2_000, text: "Second line."),
    ]
  )

  try await TranscriptStore().write(transcript, paths: paths, title: "Test")

  #expect(
    try String(contentsOf: paths.transcriptText, encoding: .utf8) == "Første linje.\nSecond line.\n"
  )
  #expect(FileManager.default.fileExists(atPath: paths.transcriptJSON.path))
  #expect(FileManager.default.fileExists(atPath: paths.transcriptMarkdown.path))
  #expect(FileManager.default.fileExists(atPath: paths.transcriptSRT.path))
}

private func makeManifest() -> SessionManifest {
  SessionManifest(
    title: "Test",
    model: SessionModelReference(id: "model", sha256: String(repeating: "0", count: 64))
  )
}

private func makeDescriptor() -> WhisperModelDescriptor {
  WhisperModelDescriptor(
    id: "model",
    displayName: "Model",
    fileName: "model.bin",
    sha256: String(repeating: "0", count: 64),
    format: .ggml,
    quantization: "q5_0",
    supportedLanguages: ["no"],
    defaultLanguage: "no",
    stability: .stable
  )
}
