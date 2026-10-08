import Foundation
import Testing

@testable import HaeCore

@Suite
struct DiagnosticLogTests {
  private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

  @Test
  func disabledLogDoesNotCreateDirectories() async throws {
    let directory = testDirectory()
    defer { removeTestDirectory(directory) }
    let log = DiagnosticLog(directory: directory)

    try await log.record(DiagnosticEvent(kind: .recordingStarted))
    try await log.setEnabled(false)
    #expect(try await log.exportData().isEmpty)
    try await log.clear()

    #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
  }

  @Test
  func enableIsExplicitAndDisablingStopsWrites() async throws {
    let directory = testDirectory()
    defer { removeTestDirectory(directory) }
    let log = DiagnosticLog(directory: directory)
    try await log.setEnabled(true)
    try await log.setEnabled(true)
    try await log.record(DiagnosticEvent(kind: .recordingStarted))
    let beforeDisable = try Data(contentsOf: logFile(in: directory))

    try await log.setEnabled(false)
    try await log.record(DiagnosticEvent(kind: .recordingStopped))

    #expect(try Data(contentsOf: logFile(in: directory)) == beforeDisable)
    #expect(try decode(await log.exportData()).map(\.kind) == [.debugEnabled, .recordingStarted])
  }

  @Test
  func relaunchPreservesBoundedEventsButStartsDisabled() async throws {
    let directory = testDirectory()
    defer { removeTestDirectory(directory) }
    let first = DiagnosticLog(directory: directory, maximumEntries: 3)
    try await first.setEnabled(true)
    try await first.record(DiagnosticEvent(kind: .recordingStarted))
    try await first.record(DiagnosticEvent(kind: .recordingStopped))

    let relaunched = DiagnosticLog(directory: directory, maximumEntries: 3)
    try await relaunched.record(DiagnosticEvent(kind: .transcriptionStarted))
    #expect(try decode(await relaunched.exportData()).count == 3)
    try await relaunched.setEnabled(true)
    try await relaunched.record(DiagnosticEvent(kind: .transcriptionSucceeded))

    #expect(
      try decode(await relaunched.exportData()).map(\.kind)
        == [.recordingStopped, .debugEnabled, .transcriptionSucceeded])
    #expect(try decode(Data(contentsOf: logFile(in: directory))).count == 3)
  }

  @Test
  func keepsNewestEntriesWithinCountLimit() async throws {
    let directory = testDirectory()
    defer { removeTestDirectory(directory) }
    let log = DiagnosticLog(directory: directory, maximumEntries: 3)
    try await log.setEnabled(true)
    for chunk in 0..<5 {
      try await log.record(DiagnosticEvent(kind: .hostedRequestStarted, chunk: chunk))
    }

    #expect(try decode(await log.exportData()).compactMap(\.chunk) == [2, 3, 4])
    let lowerLimit = DiagnosticLog(directory: directory, maximumEntries: 2)
    #expect(try decode(await lowerLimit.exportData()).compactMap(\.chunk) == [3, 4])
  }

  @Test
  func keepsNewestEntriesWithinByteLimit() async throws {
    let directory = testDirectory()
    defer { removeTestDirectory(directory) }
    let event = DiagnosticEvent(
      kind: .hostedResponseReceived, timestamp: timestamp, responseBytes: 42, statusCode: 200
    )
    let budget = try encodedLine(event).count
    let log = DiagnosticLog(directory: directory, maximumBytes: budget)
    try await log.setEnabled(true)
    for _ in 0..<5 { try await log.record(event) }

    let data = try await log.exportData()
    #expect(data.count == budget)
    #expect(try decode(data) == [event])
    #expect(try Data(contentsOf: logFile(in: directory)).count <= budget)
  }

  @Test(arguments: [0, -1])
  func nonpositiveLimitsKeepNoEvents(limit: Int) async throws {
    let directory = testDirectory()
    defer { removeTestDirectory(directory) }
    let log = DiagnosticLog(directory: directory, maximumEntries: limit, maximumBytes: limit)
    try await log.setEnabled(true)
    try await log.record(DiagnosticEvent(kind: .recordingStarted))

    #expect(try await log.exportData().isEmpty)
    #expect(try Data(contentsOf: logFile(in: directory)).isEmpty)
  }

  @Test
  func clearRemovesOnlyOwnedLogAndEnabledLoggingCanContinue() async throws {
    let directory = testDirectory()
    defer { removeTestDirectory(directory) }
    let log = DiagnosticLog(directory: directory)
    try await log.setEnabled(true)
    let unrelated = directory.appendingPathComponent("unrelated.txt")
    try Data("Keep this file".utf8).write(to: unrelated)

    try await log.clear()
    #expect(!FileManager.default.fileExists(atPath: logFile(in: directory).path))
    #expect(try String(contentsOf: unrelated, encoding: .utf8) == "Keep this file")
    #expect(try await log.exportData().isEmpty)
    try await log.record(DiagnosticEvent(kind: .recordingStarted))
    #expect(try decode(await log.exportData()).map(\.kind) == [.recordingStarted])
  }

  @Test
  func storagePermissionsArePrivateAndAtomicWritesLeaveNoTemporaryFiles() async throws {
    let directory = testDirectory()
    defer { removeTestDirectory(directory) }
    try createTestDirectory(directory, permissions: 0o755)
    let file = logFile(in: directory)
    try Data().write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    let log = DiagnosticLog(directory: directory)
    try await log.setEnabled(true)
    try await log.record(DiagnosticEvent(kind: .recordingStarted))

    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path) == [
        file.lastPathComponent
      ])
  }

  @Test
  func exportDecodesAndReencodesOnlyTypedFields() async throws {
    let directory = testDirectory()
    defer { removeTestDirectory(directory) }
    try createTestDirectory(directory)
    let event = DiagnosticEvent(kind: .hostedRequestFailed, timestamp: timestamp, failure: .http)
    var object = try #require(
      JSONSerialization.jsonObject(with: encodedLine(event)) as? [String: Any]
    )
    object["authorization"] = "Bearer private-api-key"
    object["endpoint"] = "https://private-host.example/path"
    object["transcript"] = "Confidential meeting text"
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(Data("\nnot JSON private-api-key\n".utf8))
    data.append(
      Data("{\"kind\":\"private-api-key\",\"timestamp\":\"2023-11-14T22:13:20Z\"}\n".utf8))
    data.append(
      Data(
        "{\"kind\":\"hostedRequestFailed\",\"timestamp\":\"2023-11-14T22:13:20Z\",\"statusCode\":\"secret\"}\n"
          .utf8))
    try data.write(to: logFile(in: directory))
    let log = DiagnosticLog(directory: directory)

    let exported = try await log.exportData()
    #expect(try decode(exported) == [event])
    let text = String(decoding: exported, as: UTF8.self)
    #expect(!text.contains("private-api-key"))
    #expect(!text.contains("private-host"))
    #expect(!text.contains("Confidential"))
    #expect(!text.contains("secret"))
    try await log.setEnabled(true)
    #expect(
      try decode(Data(contentsOf: logFile(in: directory))).map(\.kind) == [
        .hostedRequestFailed, .debugEnabled,
      ])
  }

  @Test
  func oversizedInputIsRejectedWithoutExportingItAndReplacedOnEnable() async throws {
    let directory = testDirectory()
    defer { removeTestDirectory(directory) }
    try createTestDirectory(directory)
    try Data(repeating: 0x61, count: 4_096).write(to: logFile(in: directory))
    let log = DiagnosticLog(directory: directory, maximumBytes: 256)

    #expect(try await log.exportData().isEmpty)
    try await log.setEnabled(true)
    #expect(try decode(await log.exportData()).map(\.kind) == [.debugEnabled])
    #expect(try Data(contentsOf: logFile(in: directory)).count <= 256)
  }

  @Test
  func symbolicLinkLogIsNotReadOrOverwritten() async throws {
    let directory = testDirectory()
    defer { removeTestDirectory(directory) }
    try createTestDirectory(directory)
    let destination = directory.deletingLastPathComponent().appendingPathComponent("private.txt")
    let original = Data("Private file".utf8)
    try original.write(to: destination)
    try FileManager.default.createSymbolicLink(
      at: logFile(in: directory), withDestinationURL: destination)
    let log = DiagnosticLog(directory: directory)

    await #expect(throws: (any Error).self) { try await log.exportData() }
    await #expect(throws: (any Error).self) { try await log.setEnabled(true) }
    #expect(try Data(contentsOf: destination) == original)
    try await log.clear()
    #expect(try Data(contentsOf: destination) == original)
    #expect(!FileManager.default.fileExists(atPath: logFile(in: directory).path))
  }

  @Test
  func typedMetadataRoundTripsWithISO8601Timestamps() async throws {
    let directory = testDirectory()
    defer { removeTestDirectory(directory) }
    let log = DiagnosticLog(directory: directory)
    let event = DiagnosticEvent(
      kind: .hostedRequestFailed, timestamp: timestamp, operationID: UUID(),
      chunk: 2, chunkCount: 3, audioBytes: 32_000, audioDurationMS: 1_000,
      responseBytes: 120, elapsedMS: 500, statusCode: 503, networkCode: -1_001,
      hasAPIKey: true, responseFormat: .verboseJSON, failure: .timeout
    )
    try await log.setEnabled(true)
    try await log.record(event)

    let data = try await log.exportData()
    #expect(try decode(data).last == event)
    #expect(String(decoding: data, as: UTF8.self).contains("2023-11-14T22:13:20Z"))
    #expect(data.last == 0x0A)
  }

  private func testDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("hae-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("Diagnostics", isDirectory: true)
  }

  private func removeTestDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
  }

  private func logFile(in directory: URL) -> URL {
    directory.appendingPathComponent("diagnostics.jsonl")
  }

  private func createTestDirectory(_ directory: URL, permissions: Int = 0o700) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: permissions]
    )
  }

  private func encodedLine(_ event: DiagnosticEvent) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(event)
    data.append(0x0A)
    return data
  }

  private func decode(_ data: Data) throws -> [DiagnosticEvent] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try data.split(separator: 0x0A).map {
      try decoder.decode(DiagnosticEvent.self, from: Data($0))
    }
  }
}
