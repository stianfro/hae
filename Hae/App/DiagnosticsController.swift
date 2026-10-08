import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

#if canImport(HaeCore)
  import HaeCore
#endif

protocol DiagnosticLogging: Sendable {
  func setEnabled(_ enabled: Bool) async throws
  func record(_ event: DiagnosticEvent) async throws
  func exportData() async throws -> Data
  func clear() async throws
}

extension DiagnosticLog: DiagnosticLogging {}

@MainActor
final class DiagnosticsController: ObservableObject {
  @Published private(set) var isEnabled: Bool
  @Published private(set) var isWorking = false
  @Published private(set) var notice: String?

  private static let enabledKey = "debugLoggingEnabled"
  private let defaults: UserDefaults
  private let logger: any DiagnosticLogging
  private var pendingOperations: Task<Void, Never>?
  private var pendingOperationID: UInt64 = 0
  private var generation: UInt64 = 0
  private var workingCount = 0

  init(
    defaults: UserDefaults = .standard,
    directory: URL? = nil,
    logger: (any DiagnosticLogging)? = nil
  ) {
    self.defaults = defaults
    self.logger = logger ?? DiagnosticLog(directory: directory ?? Self.defaultDirectory)
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    if isEnabled { applyEnabledState(true) }
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
    applyEnabledState(enabled)
  }

  func record(_ event: DiagnosticEvent) async {
    guard isEnabled else { return }
    let eventGeneration = generation
    let operation = enqueue { [weak self] in
      guard let self, self.isEnabled, self.generation == eventGeneration else { return }
      do {
        try await self.logger.record(event)
      } catch {
        self.notice = "Could not write to the debug log. Check available disk space and try again."
      }
    }
    await operation.value
  }

  func exportLog() {
    guard !isWorking else { return }
    beginWorking()
    Task { [weak self] in
      guard let self else { return }
      defer { self.endWorking() }
      let panel = NSSavePanel()
      panel.title = "Export debug log"
      panel.message = "Save a local copy of the diagnostic metadata. Nothing is uploaded."
      panel.prompt = "Export"
      panel.nameFieldStringValue = "hae-debug-log.jsonl"
      panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .plainText]
      panel.allowsOtherFileTypes = true
      panel.canCreateDirectories = true
      guard await panel.begin() == .OK, let destination = panel.url else { return }
      let accessed = destination.startAccessingSecurityScopedResource()
      defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
      let operation = self.enqueue { [weak self] in
        guard let self else { return }
        do {
          let data = try await self.logger.exportData()
          try await Task.detached(priority: .utility) {
            try data.write(to: destination, options: .atomic)
          }.value
          self.notice = "Debug log exported. Review it before sharing it with anyone."
        } catch {
          self.notice = "Could not export the debug log. Choose a writable location and try again."
        }
      }
      await operation.value
    }
  }

  func clearLog() {
    guard !isWorking else { return }
    beginWorking()
    enqueue { [weak self] in
      guard let self else { return }
      defer { self.endWorking() }
      do {
        try await self.logger.clear()
        self.notice =
          self.isEnabled
          ? "Debug log cleared. New diagnostic events will still be recorded."
          : "Debug log cleared. Logging is off."
      } catch {
        self.notice = "Could not clear the debug log. Check available disk space and try again."
      }
    }
  }

  /// Waits for already queued log operations, without starting any disk access.
  func waitForPendingOperations() async {
    await pendingOperations?.value
  }

  private func applyEnabledState(_ enabled: Bool) {
    generation &+= 1
    let requestedGeneration = generation
    beginWorking()
    enqueue { [weak self] in
      guard let self else { return }
      defer { self.endWorking() }
      guard self.generation == requestedGeneration else { return }
      do {
        try await self.logger.setEnabled(enabled)
        guard self.generation == requestedGeneration else { return }
        self.notice =
          enabled
          ? "Debug logging is on. Only new diagnostic events will be recorded."
          : "Debug logging is off. Existing entries are kept until you clear the log."
      } catch {
        guard self.generation == requestedGeneration else { return }
        self.isEnabled = false
        self.defaults.set(false, forKey: Self.enabledKey)
        if enabled { try? await self.logger.setEnabled(false) }
        self.notice =
          enabled
          ? "Could not enable debug logging. Check available disk space and try again."
          : "Logging is off, but its status could not be written to the debug log."
      }
    }
  }

  @discardableResult
  private func enqueue(
    _ action: @escaping @MainActor @Sendable () async -> Void
  ) -> Task<Void, Never> {
    let previous = pendingOperations
    pendingOperationID &+= 1
    let operationID = pendingOperationID
    let operation = Task { @MainActor [weak self] in
      await previous?.value
      await action()
      if let self, self.pendingOperationID == operationID {
        self.pendingOperations = nil
      }
    }
    pendingOperations = operation
    return operation
  }

  private func beginWorking() {
    workingCount += 1
    isWorking = true
  }

  private func endWorking() {
    workingCount -= 1
    isWorking = workingCount > 0
  }

  private static var defaultDirectory: URL {
    let support =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support")
    return support.appendingPathComponent("Hae/Diagnostics", isDirectory: true)
  }
}
