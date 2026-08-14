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
  @Published private(set) var availableMicrophones: [MicrophoneDevice] = []
  @Published private(set) var selectedMicrophoneID: String?
  @Published private(set) var modelNotice: String?
  @Published private(set) var storageNotice: String?
  @Published private(set) var signalWarnings: [String] = []
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
  private var recordingMonitorTask: Task<Void, Never>?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var activity: NSObjectProtocol?
  private var lastSystemSignalAt: Date?
  private var lastMicrophoneSignalAt: Date?

  init() {
    refreshMicrophones()
    observeLifecycleNotifications()
    Task { [weak self] in
      await self?.restoreSessionState()
    }
  }

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

  var canRetryTranscription: Bool {
    guard !isBusy, let manifest, let paths else { return false }
    guard Self.isRetryable(manifest.status) else { return false }
    let frameCount =
      (try? SessionRepository.completePCMFrameCount(
        at: paths.mixedPCM,
        repairTrailingByte: false
      )) ?? 0
    return frameCount > 0
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
    repository = nil
    manifest = nil
    paths = nil
    sessionDirectory = nil
    modelNotice = nil
    storageNotice = nil
    signalWarnings = []
    transcriptActionNotice = nil
    refreshMicrophones()
    do {
      let permissions = await permissionManager.requestRequiredPermissions()
      guard permissions.screenCapture == .granted else {
        throw CoordinatorError.screenPermissionDenied
      }
      guard permissions.microphone == .granted else {
        throw CoordinatorError.microphonePermissionDenied
      }

      let sessionsDirectory = try SessionRepository.applicationSupportSessionsDirectory()
      switch try DiskSpacePolicy.status(for: sessionsDirectory) {
      case .critical:
        throw CoordinatorError.diskSpaceCritical
      case .warning(let availableBytes):
        storageNotice =
          "Low disk space: \(Self.formatByteCount(availableBytes)) available."
      case .sufficient:
        break
      }

      let manifestURL = try locateModelManifest()
      let modelManifest = try ModelManager.loadManifest(from: manifestURL)
      guard let descriptor = modelManifest.models.first else {
        throw ModelManagerError.noModels
      }
      let repository = SessionRepository(sessionsDirectory: sessionsDirectory)
      let (manifest, paths) = try await repository.createSession(model: descriptor)
      let writer = try DurablePCMWriter(url: paths.mixedPCM)
      let pipeline = AudioPipeline(writer: writer) { [weak self] snapshot in
        Task { @MainActor [weak self] in self?.updateMeter(snapshot) }
      }
      let microphone = MicrophoneDeviceRepository.selectedDevice(savedID: selectedMicrophoneID)
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

      let metadata = try await capture.start(microphoneDeviceID: selectedMicrophoneID)
      var updatedManifest = manifest
      updatedManifest.captureDisplayID = metadata.displayID
      updatedManifest.microphoneDeviceID = metadata.microphoneDeviceID
      try await repository.save(updatedManifest, paths: paths)
      self.manifest = updatedManifest
      state = .recording
      let now = Date()
      lastSystemSignalAt = now
      lastMicrophoneSignalAt = now
      startRecordingMonitor()
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

    recordingMonitorTask?.cancel()
    recordingMonitorTask = nil
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
      await finalizeSession(manifest, repository: repository, paths: paths)
    } catch {
      await interruptRecording(error, stopCapture: false)
    }
  }

  func retryTranscription() {
    guard canRetryTranscription else { return }
    Task { await retryCurrentTranscription() }
  }

  func openSessionDirectory() {
    guard let sessionDirectory else { return }
    NSWorkspace.shared.activateFileViewerSelecting([sessionDirectory])
  }

  func refreshMicrophones() {
    let devices = MicrophoneDeviceRepository.availableDevices()
    availableMicrophones = devices
    let defaults = UserDefaults.standard
    let savedID = defaults.string(forKey: "microphoneDeviceID")
    if let savedID, devices.contains(where: { $0.id == savedID }) {
      selectedMicrophoneID = savedID
    } else {
      selectedMicrophoneID = nil
      defaults.removeObject(forKey: "microphoneDeviceID")
    }
    if !isBusy {
      activeMicrophoneName =
        MicrophoneDeviceRepository.selectedDevice(savedID: selectedMicrophoneID)?.name
        ?? "System default"
    }
  }

  func selectMicrophone(id: String?) {
    guard !isBusy else { return }
    guard id == nil || availableMicrophones.contains(where: { $0.id == id }) else {
      refreshMicrophones()
      return
    }
    selectedMicrophoneID = id
    if let id {
      UserDefaults.standard.set(id, forKey: "microphoneDeviceID")
    } else {
      UserDefaults.standard.removeObject(forKey: "microphoneDeviceID")
    }
    activeMicrophoneName =
      MicrophoneDeviceRepository.selectedDevice(savedID: id)?.name ?? "System default"
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

  private func observeLifecycleNotifications() {
    let center = NSWorkspace.shared.notificationCenter
    let interruptions: [(Notification.Name, CoordinatorError)] = [
      (NSWorkspace.willSleepNotification, .systemSleep),
      (NSWorkspace.willPowerOffNotification, .systemShutdown),
    ]
    workspaceObservers = interruptions.map { name, error in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.state == .recording else { return }
          await self.interruptRecording(error, stopCapture: true)
        }
      }
    }
  }

  private func restoreSessionState() async {
    do {
      let sessionsDirectory = try SessionRepository.applicationSupportSessionsDirectory()
      let repository = SessionRepository(sessionsDirectory: sessionsDirectory)
      let sessions = try await repository.recoverSessions()
      guard state == .idle, paths == nil else { return }

      guard
        let recent = sessions.first(where: { session in
          if session.manifest.status == .completed {
            return FileManager.default.fileExists(atPath: session.paths.transcriptText.path)
          }
          guard Self.isRetryable(session.manifest.status) else { return false }
          return
            ((try? SessionRepository.completePCMFrameCount(
              at: session.paths.mixedPCM,
              repairTrailingByte: false
            )) ?? 0) > 0
        })
      else { return }

      if Self.isRetryable(recent.manifest.status) {
        self.repository = repository
        manifest = recent.manifest
        paths = recent.paths
        sessionDirectory = recent.paths.directory
        state = .failed("Recording recovered. Transcription can be retried.")
        return
      }

      self.repository = repository
      manifest = recent.manifest
      paths = recent.paths
      sessionDirectory = recent.paths.directory
      state = .completed
    } catch {
      Self.logger.error(
        "Session recovery failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func retryCurrentTranscription() async {
    guard let repository, var manifest, let paths else { return }
    do {
      let durationFrames = try SessionRepository.completePCMFrameCount(
        at: paths.mixedPCM,
        repairTrailingByte: true
      )
      guard durationFrames > 0 else { throw CoordinatorError.recordingUnavailable }
      manifest.durationFrames = durationFrames
      if manifest.status == .finalizing {
        try manifest.transition(to: .interrupted)
      }
      self.manifest = manifest
      beginProtectedActivity()
      await finalizeSession(manifest, repository: repository, paths: paths)
    } catch {
      await handleFinalizationFailure(error)
    }
  }

  private func finalizeSession(
    _ sourceManifest: SessionManifest,
    repository: SessionRepository,
    paths: SessionPaths
  ) async {
    do {
      var finalizing = sourceManifest
      if finalizing.status != .finalizing {
        try finalizing.transition(to: .finalizing)
      }
      finalizing.finalizationProgress = 0
      finalizing.failure = nil
      try await repository.save(finalizing, paths: paths)
      manifest = finalizing
      state = .finalizing(0)

      try await loadWhisperModelIfNeeded()
      let service = FinalTranscriptionService(engine: whisperEngine)
      let transcript = try await service.transcribe(
        pcmURL: paths.mixedPCM,
        sessionID: finalizing.id,
        durationFrames: finalizing.durationFrames
      ) { [weak self] progress in
        await self?.updateFinalizationProgress(progress)
      }
      try await TranscriptStore().write(transcript, paths: paths, title: finalizing.title)

      var completed = self.manifest ?? finalizing
      completed.finalizationProgress = 1
      try completed.transition(to: .completed)
      try await repository.save(completed, paths: paths)
      manifest = completed
      state = .completed
      Self.logger.info("Final transcription completed")
      endProtectedActivity()
      clearActiveComponents()
    } catch {
      await handleFinalizationFailure(error)
    }
  }

  private func loadWhisperModelIfNeeded() async throws {
    if let modelLoadTask {
      try await modelLoadTask.value
      return
    }
    let manifestURL = try locateModelManifest()
    let modelManifest = try ModelManager.loadManifest(from: manifestURL)
    let task = Task { [whisperEngine] in
      let modelDirectory = try Self.locateModelDirectory()
      let manager = ModelManager(manifest: modelManifest)
      let verified = try await manager.verifyDefaultModel(in: modelDirectory)
      try await whisperEngine.loadModel(
        at: verified.modelURL,
        vadModelURL: verified.vadURL
      )
    }
    modelLoadTask = task
    try await task.value
  }

  private func updateMeter(_ snapshot: AudioMeterSnapshot) {
    meter = snapshot
    let now = Date()
    if snapshot.system > 0.03 { lastSystemSignalAt = now }
    if snapshot.microphone > 0.03 { lastMicrophoneSignalAt = now }
  }

  private func startRecordingMonitor() {
    recordingMonitorTask?.cancel()
    recordingMonitorTask = Task { [weak self] in
      var elapsedSeconds = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        elapsedSeconds += 1
        self.updateSignalWarnings()
        if elapsedSeconds.isMultiple(of: 10) {
          await self.checkpointRecording()
        }
      }
    }
  }

  private func updateSignalWarnings() {
    guard case .recording = state else {
      signalWarnings = []
      return
    }
    let now = Date()
    var warnings: [String] = []
    if now.timeIntervalSince(lastMicrophoneSignalAt ?? now) >= 5 {
      warnings.append("No microphone signal")
    }
    if now.timeIntervalSince(lastSystemSignalAt ?? now) >= 5 {
      warnings.append("No system audio detected")
    }
    signalWarnings = warnings
  }

  private func checkpointRecording() async {
    guard case .recording = state,
      let audioPipeline,
      let repository,
      var manifest,
      let paths
    else { return }

    manifest.durationFrames = await audioPipeline.currentWrittenFrames()
    do {
      try await repository.save(manifest, paths: paths)
      self.manifest = manifest
      switch try DiskSpacePolicy.status(for: paths.directory) {
      case .critical:
        storageNotice = "Recording stopped because less than 1 GB of disk space remains."
        await interruptRecording(CoordinatorError.diskSpaceCritical, stopCapture: true)
      case .warning(let availableBytes):
        storageNotice =
          "Low disk space: \(Self.formatByteCount(availableBytes)) available."
      case .sufficient:
        storageNotice = nil
      }
    } catch {
      Self.logger.error(
        "Recording checkpoint failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func captureStopped(_ error: Error) {
    guard case .recording = state else { return }
    Self.logger.error("Capture stream stopped: \(error.localizedDescription, privacy: .public)")
    Task { await interruptRecording(error, stopCapture: false) }
  }

  private func interruptRecording(_ error: Error, stopCapture: Bool) async {
    guard let audioPipeline, let repository, var manifest, let paths else {
      state = .failed(error.localizedDescription)
      return
    }
    recordingMonitorTask?.cancel()
    recordingMonitorTask = nil
    if stopCapture, let captureEngine { try? await captureEngine.stop() }
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
    recordingMonitorTask?.cancel()
    recordingMonitorTask = nil
    captureEngine = nil
    audioPipeline = nil
    modelLoadTask = nil
    meter = AudioMeterSnapshot(system: 0, microphone: 0)
    signalWarnings = []
    lastSystemSignalAt = nil
    lastMicrophoneSignalAt = nil
  }

  private static func isRetryable(_ status: SessionStatus) -> Bool {
    switch status {
    case .captured, .finalizing, .interrupted, .failed:
      true
    case .recording, .completed:
      false
    }
  }

  private static func formatByteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

private enum CoordinatorError: Error, LocalizedError, Sendable {
  case screenPermissionDenied
  case microphonePermissionDenied
  case modelUnavailable
  case diskSpaceCritical
  case recordingUnavailable
  case systemSleep
  case systemShutdown

  var errorDescription: String? {
    switch self {
    case .screenPermissionDenied:
      "Screen Recording permission is required to capture system audio."
    case .microphonePermissionDenied:
      "Microphone permission is required to record your side of the meeting."
    case .modelUnavailable:
      "The verified local transcription model is unavailable."
    case .diskSpaceCritical:
      "At least 1 GB of free disk space is required to record."
    case .recordingUnavailable:
      "The recovered recording does not contain usable audio."
    case .systemSleep:
      "The Mac went to sleep."
    case .systemShutdown:
      "The Mac is logging out or shutting down."
    }
  }
}
