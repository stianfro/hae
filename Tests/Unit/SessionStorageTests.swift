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
