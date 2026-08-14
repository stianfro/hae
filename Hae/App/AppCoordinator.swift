import AppKit
import Foundation
import OSLog

#if canImport(HaeCore)
  import HaeCore
#endif

enum ApplicationState: Equatable {
  case idle
  case preparing
  case recording
  case finalizing(Double)
  case completed
  case failed(String)
}

@MainActor
final class AppCoordinator: ObservableObject {
  @Published private(set) var state: ApplicationState = .idle
  @Published private(set) var meter = AudioMeterSnapshot(system: 0, microphone: 0)
  @Published private(set) var activeMicrophoneName = "System default"
  @Published private(set) var modelNotice: String?
  @Published private(set) var sessionDirectory: URL?
  @Published private(set) var transcriptActionNotice: String?

  private static let logger = Logger(subsystem: "no.froystein.hae", category: "session")
  private let permissionManager = PermissionManager()
  private let whisperEngine = WhisperEngine()
  private var repository: SessionRepository?
  private var manifest: SessionManifest?
  private var paths: SessionPaths?
  private var captureEngine: CaptureEngine?
  private var audioPipeline: AudioPipeline?
  private var modelLoadTask: Task<Void, Error>?
  private var activity: NSObjectProtocol?

  var isBusy: Bool {
    switch state {
    case .preparing, .recording, .finalizing:
      true
    default:
      false
    }
  }

  var statusText: String {
    switch state {
    case .idle:
      "Ready"
    case .preparing:
      "Preparing recording"
    case .recording:
      "Recording"
    case .finalizing(let progress):
      "Transcribing, \(Int(progress * 100))%"
    case .completed:
      "Transcript complete"
    case .failed(let message):
      message
    }
  }

  var hasCompletedTranscript: Bool {
    guard case .completed = state, let paths else { return false }
    return FileManager.default.fileExists(atPath: paths.transcriptText.path)
  }

  func toggleRecording() {
    switch state {
    case .recording:
      Task { await stopRecording() }
    case .idle, .completed, .failed:
      Task { await startRecording() }
    case .preparing, .finalizing:
      break
    }
  }

  func startRecording() async {
    state = .preparing
    modelNotice = nil
    transcriptActionNotice = nil
    do {
      let permissions = await permissionManager.requestRequiredPermissions()
      guard permissions.screenCapture == .granted else {
        throw CoordinatorError.screenPermissionDenied
      }
      guard permissions.microphone == .granted else {
        throw CoordinatorError.microphonePermissionDenied
      }

      let manifestURL = try locateModelManifest()
      let modelManifest = try ModelManager.loadManifest(from: manifestURL)
      guard let descriptor = modelManifest.models.first else {
        throw ModelManagerError.noModels
      }
      let sessionsDirectory = try SessionRepository.applicationSupportSessionsDirectory()
      let repository = SessionRepository(sessionsDirectory: sessionsDirectory)
      let (manifest, paths) = try await repository.createSession(model: descriptor)
      let writer = try DurablePCMWriter(url: paths.mixedPCM)
      let pipeline = AudioPipeline(writer: writer) { [weak self] snapshot in
        Task { @MainActor [weak self] in self?.meter = snapshot }
      }
      let microphone = MicrophoneDeviceRepository.selectedDevice(
        savedID: UserDefaults.standard.string(forKey: "microphoneDeviceID")
      )
      activeMicrophoneName = microphone?.name ?? "System default"

      let capture = CaptureEngine(
        audioHandler: pipeline.enqueue,
        stoppedHandler: { [weak self] error in
          Task { @MainActor [weak self] in self?.captureStopped(error) }
        }
      )

      self.repository = repository
      self.manifest = manifest
      self.paths = paths
      captureEngine = capture
      audioPipeline = pipeline
      sessionDirectory = paths.directory
      beginProtectedActivity()

      let metadata = try await capture.start(microphoneDeviceID: microphone?.id)
      var updatedManifest = manifest
      updatedManifest.captureDisplayID = metadata.displayID
      updatedManifest.microphoneDeviceID = metadata.microphoneDeviceID
      try await repository.save(updatedManifest, paths: paths)
      self.manifest = updatedManifest
      state = .recording
      Self.logger.info("Recording started")

      modelLoadTask = Task { [whisperEngine] in
        let modelDirectory = try Self.locateModelDirectory()
        let manager = ModelManager(manifest: modelManifest)
        let verified = try await manager.verifyDefaultModel(in: modelDirectory)
        try await whisperEngine.loadModel(
          at: verified.modelURL,
          vadModelURL: verified.vadURL
        )
      }
      Task { [weak self] in
        do {
          try await self?.modelLoadTask?.value
        } catch {
          await MainActor.run {
            self?.modelNotice =
              "Model unavailable. Recording will be kept: "
              + error.localizedDescription
          }
        }
      }
    } catch {
      await handleStartFailure(error)
    }
  }

  func stopRecording() async {
    guard case .recording = state,
      let captureEngine,
      let audioPipeline,
      let repository,
      var manifest,
      let paths
    else { return }

    state = .finalizing(0)
    do {
      try await captureEngine.stop()
      let durationFrames = try await audioPipeline.finish()
      manifest.durationFrames = durationFrames
      manifest.stoppedAt = Date()
      try manifest.transition(to: .captured)
      try await repository.save(manifest, paths: paths)
      try manifest.transition(to: .finalizing)
      manifest.finalizationProgress = 0
      try await repository.save(manifest, paths: paths)
      self.manifest = manifest
      Self.logger.info("Durable capture closed with \(durationFrames) frames")

      guard let modelLoadTask else { throw CoordinatorError.modelUnavailable }
      try await modelLoadTask.value
      let service = FinalTranscriptionService(engine: whisperEngine)
      let transcript = try await service.transcribe(
        pcmURL: paths.mixedPCM,
        sessionID: manifest.id,
        durationFrames: durationFrames
      ) { [weak self] progress in
        await self?.updateFinalizationProgress(progress)
      }
      try await TranscriptStore().write(transcript, paths: paths, title: manifest.title)

      var completed = self.manifest ?? manifest
      completed.finalizationProgress = 1
      try completed.transition(to: .completed)
      try await repository.save(completed, paths: paths)
      self.manifest = completed
      state = .completed
      Self.logger.info("Final transcription completed")
      endProtectedActivity()
      clearActiveComponents()
    } catch {
      await handleFinalizationFailure(error)
    }
  }

  func openSessionDirectory() {
    guard let sessionDirectory else { return }
    NSWorkspace.shared.activateFileViewerSelecting([sessionDirectory])
  }

  func copyTranscriptToClipboard() {
    guard hasCompletedTranscript, let transcriptURL = paths?.transcriptText else {
      transcriptActionNotice = "The completed transcript is unavailable."
      return
    }
    do {
      let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      guard pasteboard.setString(transcript, forType: .string) else {
        transcriptActionNotice = "Could not copy the transcript."
        return
      }
      transcriptActionNotice = "Copied transcript to clipboard."
    } catch {
      transcriptActionNotice = "Could not read transcript.txt: \(error.localizedDescription)"
    }
  }

  func openTranscriptText() {
    guard hasCompletedTranscript, let transcriptURL = paths?.transcriptText else {
      transcriptActionNotice = "The completed transcript is unavailable."
      return
    }
    if NSWorkspace.shared.open(transcriptURL) {
      transcriptActionNotice = "Opened transcript.txt."
    } else {
      transcriptActionNotice = "No application could open transcript.txt."
    }
  }

  func importModels() {
    let panel = NSOpenPanel()
    panel.title = "Choose the verified model folder"
    panel.message = "Select the folder containing the NB-Whisper and Silero VAD model files."
    panel.prompt = "Import"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let sourceDirectory = panel.url else { return }

    modelNotice = "Verifying local model files"
    Task {
      let accessed = sourceDirectory.startAccessingSecurityScopedResource()
      defer {
        if accessed { sourceDirectory.stopAccessingSecurityScopedResource() }
      }
      do {
        let modelManifest = try ModelManager.loadManifest(from: locateModelManifest())
        let manager = ModelManager(manifest: modelManifest)
        let verified = try await manager.verifyDefaultModel(in: sourceDirectory)
        let destination = try Self.applicationSupportModelDirectory()
        try await Task.detached {
          try Self.install(verified.modelURL, in: destination)
          try Self.install(verified.vadURL, in: destination)
        }.value
        modelNotice = "Verified transcription models installed"
      } catch {
        modelNotice = "Model import failed: \(error.localizedDescription)"
      }
    }
  }

  func openPrivacySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func updateFinalizationProgress(_ progress: Double) async {
    state = .finalizing(progress)
    guard let repository, var manifest, let paths else { return }
    manifest.finalizationProgress = progress
    try? await repository.save(manifest, paths: paths)
    self.manifest = manifest
  }

  private func captureStopped(_ error: Error) {
    guard case .recording = state else { return }
    Self.logger.error("Capture stream stopped: \(error.localizedDescription, privacy: .public)")
    Task { await interruptRecording(error) }
  }

  private func interruptRecording(_ error: Error) async {
    guard let audioPipeline, let repository, var manifest, let paths else {
      state = .failed(error.localizedDescription)
      return
    }
    let frames = (try? await audioPipeline.finish()) ?? manifest.durationFrames
    manifest.durationFrames = frames
    manifest.stoppedAt = Date()
    manifest.failure = SessionFailure(stage: "capture", message: error.localizedDescription)
    try? manifest.transition(to: .interrupted)
    try? await repository.save(manifest, paths: paths)
    self.manifest = manifest
    state = .failed("Recording interrupted. Audio was preserved.")
    endProtectedActivity()
    clearActiveComponents()
  }

  private func handleStartFailure(_ error: Error) async {
    if let captureEngine { try? await captureEngine.stop() }
    if let audioPipeline { _ = try? await audioPipeline.finish() }
    if let repository, var manifest, let paths {
      manifest.stoppedAt = Date()
      manifest.failure = SessionFailure(stage: "start", message: error.localizedDescription)
      try? manifest.transition(to: .failed)
      try? await repository.save(manifest, paths: paths)
    }
    state = .failed(error.localizedDescription)
    endProtectedActivity()
    clearActiveComponents()
  }

  private func handleFinalizationFailure(_ error: Error) async {
    if let repository, var manifest, let paths {
      manifest.failure = SessionFailure(stage: "transcription", message: error.localizedDescription)
      try? manifest.transition(to: .failed)
      try? await repository.save(manifest, paths: paths)
      self.manifest = manifest
    }
    state = .failed("Transcription failed. Audio was preserved: \(error.localizedDescription)")
    endProtectedActivity()
    clearActiveComponents()
  }

  private func locateModelManifest() throws -> URL {
    if let bundled = Bundle.main.url(forResource: "ModelManifest", withExtension: "json") {
      return bundled
    }
    let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Hae/Core/Models/ModelManifest.json")
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw ModelManagerError.invalidManifest
    }
    return source
  }

  nonisolated private static func locateModelDirectory() throws -> URL {
    if let override = ProcessInfo.processInfo.environment["HAE_MODEL_DIRECTORY"] {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Models"),
      FileManager.default.fileExists(atPath: bundled.path)
    {
      return bundled
    }
    let installed = try applicationSupportModelDirectory()
    if FileManager.default.fileExists(atPath: installed.path) {
      return installed
    }
    let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("LocalModels", isDirectory: true)
    guard FileManager.default.fileExists(atPath: local.path) else {
      throw CoordinatorError.modelUnavailable
    }
    return local
  }

  nonisolated private static func applicationSupportModelDirectory() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return support.appendingPathComponent("Hae/Models", isDirectory: true)
  }

  nonisolated private static func install(_ source: URL, in directory: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(source.lastPathComponent)
    let temporary = directory.appendingPathComponent(".\(source.lastPathComponent).importing")
    if manager.fileExists(atPath: temporary.path) { try manager.removeItem(at: temporary) }
    try manager.copyItem(at: source, to: temporary)
    if manager.fileExists(atPath: destination.path) {
      _ = try manager.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try manager.moveItem(at: temporary, to: destination)
    }
  }

  private func beginProtectedActivity() {
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled],
      reason: "Recording and transcribing a local meeting"
    )
    ProcessInfo.processInfo.disableSuddenTermination()
  }

  private func endProtectedActivity() {
    guard let currentActivity = activity else { return }
    ProcessInfo.processInfo.endActivity(currentActivity)
    activity = nil
    ProcessInfo.processInfo.enableSuddenTermination()
  }

  private func clearActiveComponents() {
    captureEngine = nil
    audioPipeline = nil
    modelLoadTask = nil
    meter = AudioMeterSnapshot(system: 0, microphone: 0)
  }
}

private enum CoordinatorError: Error, LocalizedError {
  case screenPermissionDenied
  case microphonePermissionDenied
  case modelUnavailable

  var errorDescription: String? {
    switch self {
    case .screenPermissionDenied:
      "Screen Recording permission is required to capture system audio."
    case .microphonePermissionDenied:
      "Microphone permission is required for the Phase 0 two-source test."
    case .modelUnavailable:
      "The verified local transcription model is unavailable."
    }
  }
}
