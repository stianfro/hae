import AppKit
import Foundation
import OSLog
import ServiceManagement
import UserNotifications

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

struct SessionListItem: Identifiable, Equatable {
  let id: UUID
  let title: String
  let status: SessionStatus
  let createdAt: Date
  let durationFrames: Int64
  let hasTranscript: Bool
  let hasAudio: Bool

  var canRetryTranscription: Bool {
    hasAudio && status != .completed && status != .recording
  }

  var durationText: String {
    let totalSeconds = max(0, durationFrames / 16_000)
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds / 60) % 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
  }

  var statusText: String {
    switch status {
    case .recording:
      "Recording"
    case .captured:
      "Captured"
    case .finalizing:
      "Transcribing"
    case .completed:
      "Complete"
    case .interrupted:
      "Interrupted"
    case .failed:
      "Failed"
    }
  }
}

@MainActor
final class AppCoordinator: ObservableObject {
  @Published private(set) var state: ApplicationState = .idle
  @Published private(set) var meter = AudioMeterSnapshot(system: 0, microphone: 0)
  @Published private(set) var activeMicrophoneName = "System default"
  @Published private(set) var availableMicrophones: [MicrophoneDevice] = []
  @Published private(set) var selectedMicrophoneID: String?
  @Published private(set) var availableDisplays: [CaptureDisplayDevice] = []
  @Published private(set) var selectedDisplayID: CGDirectDisplayID?
  @Published private(set) var modelNotice: String?
  @Published private(set) var storageNotice: String?
  @Published private(set) var signalWarnings: [String] = []
  @Published private(set) var sessionDirectory: URL?
  @Published private(set) var transcriptActionNotice: String?
  @Published private(set) var sessionHistory: [SessionListItem] = []
  @Published private(set) var sessionActionNotice: String?
  @Published private(set) var audioRetentionPolicy: AudioRetentionPolicy = .sevenDays
  @Published private(set) var launchAtLoginEnabled = false
  @Published private(set) var completionNotificationsEnabled = true
  @Published private(set) var preventIdleSleepEnabled = true
  @Published private(set) var preserveSeparateTracksEnabled = false
  @Published private(set) var systemAudioGain: Float = 1
  @Published private(set) var microphoneGain: Float = 0.9

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
  private var storedSessions: [StoredSession] = []

  init() {
    let defaults = UserDefaults.standard
    if let saved = UserDefaults.standard.string(forKey: "audioRetentionPolicy"),
      let policy = AudioRetentionPolicy(rawValue: saved)
    {
      audioRetentionPolicy = policy
    }
    if let saved = UserDefaults.standard.string(forKey: "captureDisplayID"),
      let id = CGDirectDisplayID(saved)
    {
      selectedDisplayID = id
    }
    if defaults.object(forKey: "completionNotificationsEnabled") != nil {
      completionNotificationsEnabled = defaults.bool(forKey: "completionNotificationsEnabled")
    }
    if defaults.object(forKey: "preventIdleSleepEnabled") != nil {
      preventIdleSleepEnabled = defaults.bool(forKey: "preventIdleSleepEnabled")
    }
    preserveSeparateTracksEnabled = defaults.bool(forKey: "preserveSeparateTracksEnabled")
    if defaults.object(forKey: "systemAudioGain") != nil {
      systemAudioGain = Float(defaults.double(forKey: "systemAudioGain"))
    }
    if defaults.object(forKey: "microphoneGain") != nil {
      microphoneGain = Float(defaults.double(forKey: "microphoneGain"))
    }
    launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
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
      var sourceWriters: [AudioSource: DurablePCMWriter] = [:]
      if preserveSeparateTracksEnabled {
        sourceWriters[.system] = try DurablePCMWriter(url: paths.systemPCM)
        sourceWriters[.microphone] = try DurablePCMWriter(url: paths.microphonePCM)
      }
      let mixerConfiguration = MixerConfiguration(
        systemGain: systemAudioGain,
        microphoneGain: microphoneGain
      )
      let pipeline = AudioPipeline(
        writer: writer,
        sourceWriters: sourceWriters,
        mixerConfiguration: mixerConfiguration
      ) {
        [weak self] snapshot in
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

      let metadata = try await capture.start(
        displayID: selectedDisplayID,
        microphoneDeviceID: selectedMicrophoneID
      )
      var updatedManifest = manifest
      updatedManifest.captureDisplayID = metadata.displayID
      updatedManifest.microphoneDeviceID = metadata.microphoneDeviceID
      updatedManifest.separateTracks = preserveSeparateTracksEnabled
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

  func retryTranscription(sessionID: UUID) {
    guard !isBusy, let session = storedSession(id: sessionID), let repository else { return }
    guard Self.isRetryable(session.manifest.status) else { return }
    manifest = session.manifest
    paths = session.paths
    sessionDirectory = session.paths.directory
    state = .failed("Ready to retry transcription.")
    self.repository = repository
    retryTranscription()
  }

  func openSessionDirectory() {
    guard let sessionDirectory else { return }
    NSWorkspace.shared.activateFileViewerSelecting([sessionDirectory])
  }

  func openSessionsFolder() {
    do {
      let sessions = try SessionRepository.applicationSupportSessionsDirectory()
      NSWorkspace.shared.open(sessions)
    } catch {
      sessionActionNotice = "Could not open the sessions folder: \(error.localizedDescription)"
    }
  }

  func openTranscript(sessionID: UUID) {
    guard let session = storedSession(id: sessionID) else { return }
    guard FileManager.default.fileExists(atPath: session.paths.transcriptText.path) else {
      sessionActionNotice = "This session does not have a completed transcript."
      return
    }
    if NSWorkspace.shared.open(session.paths.transcriptText) {
      sessionActionNotice = "Opened \(session.manifest.title)."
    } else {
      sessionActionNotice = "No application could open this transcript."
    }
  }

  func revealSession(sessionID: UUID) {
    guard let session = storedSession(id: sessionID) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([session.paths.directory])
  }

  func exportSession(sessionID: UUID) {
    guard !isBusy, let repository, let session = storedSession(id: sessionID) else { return }
    guard FileManager.default.fileExists(atPath: session.paths.transcriptJSON.path) else {
      sessionActionNotice = "This session does not have transcript files to export."
      return
    }

    let panel = NSOpenPanel()
    panel.title = "Export transcript"
    panel.message = "Choose a folder for the transcript exports."
    panel.prompt = "Export"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    Task {
      let accessed = destination.startAccessingSecurityScopedResource()
      defer {
        if accessed { destination.stopAccessingSecurityScopedResource() }
      }
      do {
        let exported = try await repository.exportTranscripts(
          paths: session.paths,
          to: destination
        )
        sessionActionNotice = "Exported transcript files."
        NSWorkspace.shared.activateFileViewerSelecting([exported])
      } catch {
        sessionActionNotice = "Could not export the transcript: \(error.localizedDescription)"
      }
    }
  }

  func renameSession(sessionID: UUID, title: String) {
    guard !isBusy, let repository, let session = storedSession(id: sessionID) else { return }
    Task {
      do {
        let renamed = try await repository.renameSession(paths: session.paths, title: title)
        if FileManager.default.fileExists(atPath: session.paths.transcriptJSON.path) {
          let store = TranscriptStore()
          let transcript = try await store.load(paths: session.paths)
          try await store.write(transcript, paths: session.paths, title: renamed.title)
        }
        if manifest?.id == renamed.id { manifest = renamed }
        sessionActionNotice = "Renamed session."
        await refreshSessionHistory(using: repository)
      } catch {
        sessionActionNotice = "Could not rename the session: \(error.localizedDescription)"
      }
    }
  }

  func deleteSessionAudio(sessionID: UUID) {
    guard !isBusy, let repository, let session = storedSession(id: sessionID) else { return }
    Task {
      do {
        try await repository.deleteAudio(paths: session.paths)
        sessionActionNotice = "Deleted retained audio. The transcript was kept."
        await refreshSessionHistory(using: repository)
      } catch {
        sessionActionNotice = "Could not delete session audio: \(error.localizedDescription)"
      }
    }
  }

  func deleteSession(sessionID: UUID) {
    guard !isBusy, let repository, let session = storedSession(id: sessionID) else { return }
    Task {
      do {
        try await repository.deleteSession(paths: session.paths)
        if manifest?.id == sessionID {
          manifest = nil
          paths = nil
          sessionDirectory = nil
          state = .idle
        }
        sessionActionNotice = "Deleted session."
        await refreshSessionHistory(using: repository)
        restoreMostRecentDisplayedSession()
      } catch {
        sessionActionNotice = "Could not delete the session: \(error.localizedDescription)"
      }
    }
  }

  func setAudioRetentionPolicy(_ policy: AudioRetentionPolicy) {
    guard !isBusy else { return }
    audioRetentionPolicy = policy
    UserDefaults.standard.set(policy.rawValue, forKey: "audioRetentionPolicy")
    guard let repository else { return }
    Task {
      await refreshSessionHistory(using: repository, applyingRetention: true)
      sessionActionNotice = "Audio retention updated."
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    guard !isBusy else { return }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
      sessionActionNotice =
        launchAtLoginEnabled
        ? "Hæ? will start when you log in."
        : "Launch at login disabled."
    } catch {
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
      sessionActionNotice = "Could not update launch at login: \(error.localizedDescription)"
    }
  }

  func setCompletionNotifications(_ enabled: Bool) {
    completionNotificationsEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "completionNotificationsEnabled")
    guard enabled else { return }
    Task {
      do {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .sound]
        )
        if !granted {
          completionNotificationsEnabled = false
          UserDefaults.standard.set(false, forKey: "completionNotificationsEnabled")
          sessionActionNotice = "Completion notifications were not allowed."
        }
      } catch {
        completionNotificationsEnabled = false
        UserDefaults.standard.set(false, forKey: "completionNotificationsEnabled")
        sessionActionNotice = "Could not enable notifications: \(error.localizedDescription)"
      }
    }
  }

  func setPreventIdleSleep(_ enabled: Bool) {
    guard !isBusy else { return }
    preventIdleSleepEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "preventIdleSleepEnabled")
  }

  func setPreserveSeparateTracks(_ enabled: Bool) {
    guard !isBusy else { return }
    preserveSeparateTracksEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "preserveSeparateTracksEnabled")
  }

  func setSystemAudioGain(_ gain: Float) {
    guard !isBusy else { return }
    systemAudioGain = min(1.5, max(0, gain))
    UserDefaults.standard.set(Double(systemAudioGain), forKey: "systemAudioGain")
  }

  func setMicrophoneGain(_ gain: Float) {
    guard !isBusy else { return }
    microphoneGain = min(1.5, max(0, gain))
    UserDefaults.standard.set(Double(microphoneGain), forKey: "microphoneGain")
  }

  func verifyInstalledModels() {
    guard !isBusy else { return }
    modelNotice = "Verifying transcription models"
    Task {
      do {
        let modelManifest = try ModelManager.loadManifest(from: locateModelManifest())
        let manager = ModelManager(manifest: modelManifest)
        _ = try await manager.verifyDefaultModel(in: Self.locateModelDirectory())
        modelNotice = "Transcription models verified"
      } catch {
        modelNotice = "Model verification failed: \(error.localizedDescription)"
      }
    }
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

  func refreshDisplays(showErrors: Bool = false) async {
    do {
      let displays = try await CaptureDisplayRepository.availableDisplays()
      availableDisplays = displays
      if let selectedDisplayID, !displays.contains(where: { $0.id == selectedDisplayID }) {
        self.selectedDisplayID = nil
        UserDefaults.standard.removeObject(forKey: "captureDisplayID")
      }
    } catch {
      availableDisplays = []
      if showErrors {
        sessionActionNotice = "Could not list displays: \(error.localizedDescription)"
      }
    }
  }

  func selectDisplay(id: CGDirectDisplayID?) {
    guard !isBusy else { return }
    guard id == nil || availableDisplays.contains(where: { $0.id == id }) else {
      selectedDisplayID = nil
      UserDefaults.standard.removeObject(forKey: "captureDisplayID")
      return
    }
    selectedDisplayID = id
    if let id {
      UserDefaults.standard.set(String(id), forKey: "captureDisplayID")
    } else {
      UserDefaults.standard.removeObject(forKey: "captureDisplayID")
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
      var sessions = try await repository.recoverSessions()
      sessions = try await applyAudioRetention(to: sessions, using: repository)
      guard state == .idle, paths == nil else { return }

      self.repository = repository
      updateSessionHistory(sessions)

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
        manifest = recent.manifest
        paths = recent.paths
        sessionDirectory = recent.paths.directory
        state = .failed("Recording recovered. Transcription can be retried.")
        return
      }

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

  private func refreshSessionHistory(
    using repository: SessionRepository,
    applyingRetention: Bool = false
  ) async {
    do {
      var sessions = try await repository.recoverSessions()
      if applyingRetention {
        sessions = try await applyAudioRetention(to: sessions, using: repository)
      }
      updateSessionHistory(sessions)
    } catch {
      sessionActionNotice = "Could not refresh session history: \(error.localizedDescription)"
    }
  }

  private func applyAudioRetention(
    to sessions: [StoredSession],
    using repository: SessionRepository
  ) async throws -> [StoredSession] {
    for session in sessions
    where audioRetentionPolicy.shouldDeleteAudio(for: session.manifest)
      && FileManager.default.fileExists(atPath: session.paths.mixedPCM.path)
    {
      try await repository.deleteAudio(paths: session.paths)
    }
    return sessions
  }

  private func updateSessionHistory(_ sessions: [StoredSession]) {
    storedSessions = sessions
    sessionHistory = sessions.map { session in
      SessionListItem(
        id: session.manifest.id,
        title: session.manifest.title,
        status: session.manifest.status,
        createdAt: session.manifest.createdAt,
        durationFrames: session.manifest.durationFrames,
        hasTranscript: FileManager.default.fileExists(atPath: session.paths.transcriptText.path),
        hasAudio: FileManager.default.fileExists(atPath: session.paths.mixedPCM.path)
      )
    }
  }

  private func storedSession(id: UUID) -> StoredSession? {
    storedSessions.first { $0.manifest.id == id }
  }

  private func restoreMostRecentDisplayedSession() {
    guard manifest == nil else { return }
    guard
      let recent = storedSessions.first(where: { session in
        session.manifest.status == .completed
          && FileManager.default.fileExists(atPath: session.paths.transcriptText.path)
      })
    else { return }
    manifest = recent.manifest
    paths = recent.paths
    sessionDirectory = recent.paths.directory
    state = .completed
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
      await refreshSessionHistory(using: repository, applyingRetention: true)
      await sendCompletionNotification(title: completed.title)
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
    await refreshSessionHistory(using: repository)
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
    if let repository { await refreshSessionHistory(using: repository) }
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
    if let repository { await refreshSessionHistory(using: repository) }
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
    var options: ProcessInfo.ActivityOptions = [.userInitiated]
    if preventIdleSleepEnabled { options.insert(.idleSystemSleepDisabled) }
    activity = ProcessInfo.processInfo.beginActivity(
      options: options,
      reason: "Recording and transcribing a local meeting"
    )
    ProcessInfo.processInfo.disableSuddenTermination()
  }

  private func sendCompletionNotification(title: String) async {
    guard completionNotificationsEnabled else { return }
    let center = UNUserNotificationCenter.current()
    do {
      var authorizationStatus = await center.notificationSettings().authorizationStatus
      if authorizationStatus == .notDetermined {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        authorizationStatus = granted ? .authorized : .denied
      }
      guard authorizationStatus == .authorized else { return }
      let content = UNMutableNotificationContent()
      content.title = "Transcript ready"
      content.body = title
      content.sound = .default
      let request = UNNotificationRequest(
        identifier: "transcript-\(UUID().uuidString)",
        content: content,
        trigger: nil
      )
      try await center.add(request)
    } catch {
      Self.logger.error(
        "Completion notification failed: \(error.localizedDescription, privacy: .public)"
      )
    }
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
