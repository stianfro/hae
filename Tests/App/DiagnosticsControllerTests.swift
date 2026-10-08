import Foundation
import HaeCore
import Testing

@testable import HaeApplication

@Suite
@MainActor
struct DiagnosticsControllerTests {
  @Test
  func defaultOffDoesNotTouchLoggerOrCreateDirectory() async {
    let suite = makeDefaults()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let logger = StubDiagnosticLogger()
    let controller = DiagnosticsController(
      defaults: suite.defaults, directory: directory, logger: logger)
    await controller.record(event)
    await controller.waitForPendingOperations()
    #expect(!controller.isEnabled)
    #expect(!controller.isWorking)
    #expect(await logger.callCount == 0)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test
  func defaultOffRealLoggerDoesNotCreateDirectory() async {
    let suite = makeDefaults()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let controller = DiagnosticsController(defaults: suite.defaults, directory: directory)
    await controller.record(event)
    await controller.waitForPendingOperations()
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test
  func enablingPersistsAndInitializationPrecedesFirstRecord() async {
    let suite = makeDefaults()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let logger = StubDiagnosticLogger()
    let controller = DiagnosticsController(defaults: suite.defaults, logger: logger)
    controller.setEnabled(true)
    await controller.record(event)
    #expect(controller.isEnabled)
    #expect(!controller.isWorking)
    #expect(suite.defaults.bool(forKey: "debugLoggingEnabled"))
    #expect(await logger.calls == ["enable", "record"])

    let restoredLogger = StubDiagnosticLogger()
    let restored = DiagnosticsController(defaults: suite.defaults, logger: restoredLogger)
    await restored.record(event)
    #expect(restored.isEnabled)
    #expect(await restoredLogger.calls == ["enable", "record"])
  }

  @Test
  func disablingImmediatelyRejectsNewEventsAndPersists() async {
    let suite = makeDefaults()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let logger = StubDiagnosticLogger()
    let controller = DiagnosticsController(defaults: suite.defaults, logger: logger)
    controller.setEnabled(true)
    await controller.waitForPendingOperations()
    controller.setEnabled(false)
    await controller.record(event)
    await controller.waitForPendingOperations()
    #expect(!controller.isEnabled)
    #expect(!suite.defaults.bool(forKey: "debugLoggingEnabled"))
    #expect(await logger.calls == ["enable", "disable"])
  }

  @Test
  func rapidToggleDoesNotApplyAnObsoleteEnable() async {
    let suite = makeDefaults()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let logger = StubDiagnosticLogger()
    let controller = DiagnosticsController(defaults: suite.defaults, logger: logger)
    controller.setEnabled(true)
    controller.setEnabled(false)
    await controller.waitForPendingOperations()
    #expect(!controller.isEnabled)
    #expect(!controller.isWorking)
    #expect(await logger.calls == ["disable"])
  }

  @Test
  func failedEnableResetsPersistedFlagWithoutLeakingError() async {
    let suite = makeDefaults()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let logger = StubDiagnosticLogger(failEnabling: true)
    let controller = DiagnosticsController(defaults: suite.defaults, logger: logger)
    controller.setEnabled(true)
    await controller.waitForPendingOperations()
    #expect(!controller.isEnabled)
    #expect(!controller.isWorking)
    #expect(!suite.defaults.bool(forKey: "debugLoggingEnabled"))
    #expect(
      controller.notice
        == "Could not enable debug logging. Check available disk space and try again.")
    await controller.record(event)
    #expect(await logger.calls == ["enable", "disable"])
    assertSafe(controller.notice)
  }

  @Test
  func failedRecordPublishesSafeNoticeAndDoesNotThrow() async {
    let suite = makeDefaults()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let logger = StubDiagnosticLogger(failRecording: true)
    let controller = DiagnosticsController(defaults: suite.defaults, logger: logger)
    controller.setEnabled(true)
    await controller.record(event)
    #expect(controller.isEnabled)
    #expect(
      controller.notice
        == "Could not write to the debug log. Check available disk space and try again.")
    assertSafe(controller.notice)
  }

  @Test
  func clearIsExplicitAndLeavesLoggingPreferenceUnchanged() async {
    let suite = makeDefaults()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let logger = StubDiagnosticLogger()
    let controller = DiagnosticsController(defaults: suite.defaults, logger: logger)
    controller.clearLog()
    await controller.waitForPendingOperations()
    #expect(!controller.isEnabled)
    #expect(!controller.isWorking)
    #expect(await logger.calls == ["clear"])
    #expect(controller.notice == "Debug log cleared. Logging is off.")
  }

  @Test
  func failedClearDoesNotLeakError() async {
    let suite = makeDefaults()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    let logger = StubDiagnosticLogger(failClearing: true)
    let controller = DiagnosticsController(defaults: suite.defaults, logger: logger)
    controller.clearLog()
    await controller.waitForPendingOperations()
    #expect(!controller.isWorking)
    #expect(
      controller.notice
        == "Could not clear the debug log. Check available disk space and try again.")
    assertSafe(controller.notice)
  }

  private var event: DiagnosticEvent {
    DiagnosticEvent(kind: .hostedRequestStarted, hasAPIKey: false)
  }

  private func makeDefaults() -> (name: String, defaults: UserDefaults) {
    let name = "no.froystein.hae.diagnostics.tests.\(UUID().uuidString)"
    return (name, UserDefaults(suiteName: name)!)
  }

  private func assertSafe(_ notice: String?) {
    #expect(notice != nil)
    #expect(notice?.contains("private-debug-path") == false)
    #expect(notice?.contains("secret-key") == false)
    #expect(notice?.contains("private.example.com") == false)
  }
}

private actor StubDiagnosticLogger: DiagnosticLogging {
  private(set) var calls: [String] = []
  let failEnabling: Bool
  let failRecording: Bool
  let failClearing: Bool

  init(failEnabling: Bool = false, failRecording: Bool = false, failClearing: Bool = false) {
    self.failEnabling = failEnabling
    self.failRecording = failRecording
    self.failClearing = failClearing
  }

  var callCount: Int { calls.count }

  func setEnabled(_ enabled: Bool) throws {
    calls.append(enabled ? "enable" : "disable")
    if enabled && failEnabling { throw unsafeError }
  }

  func record(_ event: DiagnosticEvent) throws {
    calls.append("record")
    if failRecording { throw unsafeError }
  }

  func exportData() throws -> Data {
    calls.append("export")
    return Data()
  }

  func clear() throws {
    calls.append("clear")
    if failClearing { throw unsafeError }
  }

  private var unsafeError: NSError {
    NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
      userInfo: [
        NSLocalizedDescriptionKey: "private-debug-path secret-key https://private.example.com"
      ]
    )
  }
}
