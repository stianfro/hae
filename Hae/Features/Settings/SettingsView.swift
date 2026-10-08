import AppKit
import SwiftUI

#if canImport(HaeCore)
  import HaeCore
#endif

struct SettingsView: View {
  static let windowID = "hae-settings"

  @ObservedObject var coordinator: AppCoordinator

  var body: some View {
    TabView {
      generalSettings
        .tabItem { Label("General", systemImage: "gearshape") }
      audioSettings
        .tabItem { Label("Audio", systemImage: "waveform") }
      TranscriptionSettingsView(
        preferences: coordinator.transcriptionPreferences,
        isBusy: coordinator.isBusy || coordinator.isRestoringSessions
          || coordinator.isModelOperationRunning || coordinator.isFilePanelOpen,
        modelNotice: coordinator.modelNotice,
        importModels: coordinator.importModels,
        verifyModels: coordinator.verifyInstalledModels
      )
      .tabItem { Label("Transcription", systemImage: "text.bubble") }
      storageSettings
        .tabItem { Label("Storage", systemImage: "externaldrive") }
      DiagnosticsSettingsView(controller: coordinator.diagnostics)
        .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
    }
    .padding(16)
    .frame(width: 620, height: 630)
    .onAppear { coordinator.refreshMicrophones() }
    .task { await coordinator.refreshDisplays() }
  }

  private var generalSettings: some View {
    Form {
      Section("Startup") {
        Toggle(
          "Launch Hæ? at login",
          isOn: Binding(
            get: { coordinator.launchAtLoginEnabled },
            set: { coordinator.setLaunchAtLogin($0) }
          )
        )
        .disabled(coordinator.isBusy)
      }
      Section("Recording and transcription") {
        Toggle(
          "Show a notification when transcription finishes",
          isOn: Binding(
            get: { coordinator.completionNotificationsEnabled },
            set: { coordinator.setCompletionNotifications($0) }
          )
        )
        Toggle(
          "Prevent idle sleep while working",
          isOn: Binding(
            get: { coordinator.preventIdleSleepEnabled },
            set: { coordinator.setPreventIdleSleep($0) }
          )
        )
        .disabled(coordinator.isBusy)
      }
      Section("Permissions") {
        Text("Recording uses microphone and system audio access. Manage these in System Settings.")
          .foregroundStyle(.secondary)
        Button("Open Privacy settings") { coordinator.openPrivacySettings() }
      }
    }
    .formStyle(.grouped)
  }

  private var audioSettings: some View {
    Form {
      if coordinator.isBusy {
        Section {
          Label("Audio settings can be changed after this session finishes.", systemImage: "lock")
            .foregroundStyle(.secondary)
        }
      }
      Section("Sources") {
        Picker(
          "Microphone",
          selection: Binding(
            get: { coordinator.selectedMicrophoneID },
            set: { coordinator.selectMicrophone(id: $0) }
          )
        ) {
          Text("System default").tag(nil as String?)
          ForEach(coordinator.availableMicrophones) { microphone in
            Text(microphone.name).tag(Optional(microphone.id))
          }
        }
        .disabled(coordinator.isBusy)

        Picker(
          "Capture display",
          selection: Binding(
            get: { coordinator.selectedDisplayID },
            set: { coordinator.selectDisplay(id: $0) }
          )
        ) {
          Text("Main display (automatic)").tag(nil as CGDirectDisplayID?)
          ForEach(coordinator.availableDisplays) { display in
            Text("\(display.name) (\(display.width) × \(display.height))")
              .tag(Optional(display.id))
          }
        }
        .disabled(coordinator.isBusy || coordinator.availableDisplays.isEmpty)
        Text("The selected display provides system audio. No screen video is saved.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Refresh audio sources") {
          coordinator.refreshMicrophones()
          Task { await coordinator.refreshDisplays() }
        }
        .disabled(coordinator.isBusy)
      }
      Section("Levels") {
        GainControl(
          label: "System audio gain",
          value: Binding(
            get: { coordinator.systemAudioGain },
            set: { coordinator.setSystemAudioGain($0) }
          )
        )
        GainControl(
          label: "Microphone gain",
          value: Binding(
            get: { coordinator.microphoneGain },
            set: { coordinator.setMicrophoneGain($0) }
          )
        )
      }
      .disabled(coordinator.isBusy)
    }
    .formStyle(.grouped)
  }

  private var storageSettings: some View {
    Form {
      Section("Recorded audio") {
        Picker(
          "Keep audio",
          selection: Binding(
            get: { coordinator.audioRetentionPolicy },
            set: { coordinator.setAudioRetentionPolicy($0) }
          )
        ) {
          Text("Delete after transcription").tag(AudioRetentionPolicy.immediately)
          Text("For 7 days").tag(AudioRetentionPolicy.sevenDays)
          Text("For 30 days").tag(AudioRetentionPolicy.thirtyDays)
          Text("Indefinitely").tag(AudioRetentionPolicy.forever)
        }
        Toggle(
          "Preserve separate microphone and system tracks",
          isOn: Binding(
            get: { coordinator.preserveSeparateTracksEnabled },
            set: { coordinator.setPreserveSeparateTracks($0) }
          )
        )
        Text(
          "Transcripts are kept when retained audio is deleted. Failed recordings keep their audio for retry."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .disabled(coordinator.isBusy)
      Section("Files") {
        Button("Open sessions folder") { coordinator.openSessionsFolder() }
        Button("Open current session folder") { coordinator.openSessionDirectory() }
          .disabled(coordinator.sessionDirectory == nil)
        if let notice = coordinator.storageNotice {
          Label(notice, systemImage: "externaldrive.badge.exclamationmark")
            .foregroundStyle(.orange)
        }
      }
      if let notice = coordinator.sessionActionNotice {
        Section {
          Text(notice)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct TranscriptionSettingsView: View {
  @ObservedObject var preferences: TranscriptionPreferences
  let isBusy: Bool
  let modelNotice: String?
  let importModels: () -> Void
  let verifyModels: () -> Void

  @State private var provider: TranscriptionProvider
  @State private var configuration: HostedTranscriptionConfiguration
  @State private var apiKey = ""
  @State private var removeAPIKey = false
  @State private var notice: String?
  @State private var saveFailed = false

  init(
    preferences: TranscriptionPreferences,
    isBusy: Bool,
    modelNotice: String?,
    importModels: @escaping () -> Void,
    verifyModels: @escaping () -> Void
  ) {
    self.preferences = preferences
    self.isBusy = isBusy
    self.modelNotice = modelNotice
    self.importModels = importModels
    self.verifyModels = verifyModels
    _provider = State(initialValue: preferences.provider)
    _configuration = State(initialValue: preferences.configuration)
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Transcribe recordings") {
          Picker("Transcription", selection: $provider) {
            Text("On this Mac").tag(TranscriptionProvider.local)
            Text("Hosted server").tag(TranscriptionProvider.hosted)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .accessibilityLabel("Transcription location")
          if provider == .local {
            Label(
              "Audio stays on this Mac. Transcription uses your installed Whisper models.",
              systemImage: "lock.shield"
            )
            .foregroundStyle(.secondary)
          } else {
            Label {
              Text(
                "After recording, a copy of the mixed audio is sent to your server. Use a server you trust and get permission from everyone recorded."
              )
            } icon: {
              Image(systemName: "arrow.up.right.circle")
                .foregroundStyle(.orange)
            }
          }
          Text(
            "Changes apply to new recordings. Retrying a session uses its original transcription destination. There is no automatic fallback."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        if provider == .hosted {
          hostedConfiguration
        } else {
          Section("Local models") {
            HStack {
              Button("Import models", action: importModels)
              Button("Verify models", action: verifyModels)
            }
            if let modelNotice {
              Text(modelNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .formStyle(.grouped)
      .disabled(isBusy)

      Divider()
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          if isBusy {
            Text("Wait for the current operation to finish before changing transcription.")
              .foregroundStyle(.secondary)
          } else if let notice {
            Text(notice)
              .foregroundStyle(saveFailed ? Color.red : Color.secondary)
          } else {
            Text(hasChanges ? "Unsaved changes" : "Settings saved")
              .foregroundStyle(.secondary)
          }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Button("Revert", action: revert)
          .disabled(isBusy || !hasChanges)
        Button("Save changes", action: save)
          .buttonStyle(.borderedProminent)
          .disabled(isBusy || !hasChanges)
      }
      .padding(16)
    }
    .onChange(of: configuration.baseURL) {
      apiKey = ""
      removeAPIKey = false
      notice = nil
    }
    .onChange(of: configuration) { notice = nil }
    .onChange(of: provider) { notice = nil }
    .onChange(of: apiKey) { notice = nil }
    .onChange(of: removeAPIKey) { notice = nil }
  }

  private var hostedConfiguration: some View {
    Group {
      Section("OpenAI-compatible audio API") {
        TextField(
          "Base URL", text: $configuration.baseURL, prompt: Text("https://inference.example.com/v1")
        )
        .autocorrectionDisabled()
        TextField("Model ID", text: $configuration.model, prompt: Text("whisper-1"))
          .autocorrectionDisabled()
        TextField("Language (optional)", text: $configuration.language, prompt: Text("no, en, …"))
          .autocorrectionDisabled()
        Picker("Response", selection: $configuration.responseFormat) {
          Text("JSON (compatible)").tag(HostedTranscriptionResponseFormat.json)
          Text("Verbose JSON (timestamps)").tag(HostedTranscriptionResponseFormat.verboseJSON)
        }
        Text(
          "Requires /audio/transcriptions and an audio transcription model such as Whisper. Chat and embedding models cannot transcribe audio here."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("Authentication") {
        SecureField("API key", text: $apiKey, prompt: Text("Leave blank to keep the saved key"))
          .disabled(removeAPIKey)
        Toggle("Remove this server's saved API key", isOn: $removeAPIKey)
        Text(
          "Keys stay in your Mac's Keychain and are tied to this server's URL. Most providers require a key. No key is needed for servers that allow unauthenticated access."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var hasChanges: Bool {
    provider != preferences.provider || configuration != preferences.configuration
      || (provider == .hosted && (!apiKey.isEmpty || removeAPIKey))
  }

  private func save() {
    guard !isBusy else { return }
    do {
      let key: String? =
        provider == .hosted ? (removeAPIKey ? "" : (apiKey.isEmpty ? nil : apiKey)) : nil
      try preferences.save(provider: provider, configuration: configuration, apiKey: key)
      configuration = preferences.configuration
      apiKey = ""
      removeAPIKey = false
      saveFailed = false
      notice =
        "Settings saved. New recordings use \(provider == .local ? "on-device" : "hosted") transcription."
    } catch {
      saveFailed = true
      notice = error.localizedDescription
    }
  }

  private func revert() {
    provider = preferences.provider
    configuration = preferences.configuration
    apiKey = ""
    removeAPIKey = false
    notice = nil
    saveFailed = false
  }
}

private struct GainControl: View {
  let label: String
  @Binding var value: Float

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(label)
        Spacer()
        Text("\(value, specifier: "%.1f")×")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(value: $value, in: 0...1.5, step: 0.1)
        .accessibilityLabel(label)
        .accessibilityValue("\(value, specifier: "%.1f") times")
    }
  }
}

private struct DiagnosticsSettingsView: View {
  @ObservedObject var controller: DiagnosticsController
  @State private var showClearConfirmation = false

  var body: some View {
    Form {
      Section("Debug logging") {
        Toggle(
          "Record debug diagnostics",
          isOn: Binding(
            get: { controller.isEnabled },
            set: { controller.setEnabled($0) }
          )
        )
        .disabled(controller.isWorking)
        Text(
          "Off by default. Turn this on before reproducing a problem, then export the log to help investigate it."
        )
        .foregroundStyle(.secondary)
        Label {
          Text(
            "Logs contain only timing, status and error codes, chunk metadata, and whether an API key was present. They never contain API keys, audio, transcripts, URLs, model names, or raw server responses."
          )
        } icon: {
          Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        Text(
          "Logs stay on this Mac and are limited in size. Turning logging off stops new entries; it does not remove existing entries. Nothing is uploaded automatically."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("Log files") {
        HStack {
          Button("Export debug log…", action: controller.exportLog)
          Button("Clear debug log…", role: .destructive) { showClearConfirmation = true }
          if controller.isWorking {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Updating debug log")
          }
        }
        .disabled(controller.isWorking)
        if let notice = controller.notice {
          Text(notice)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog("Clear the debug log?", isPresented: $showClearConfirmation) {
      Button("Clear debug log", role: .destructive, action: controller.clearLog)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This deletes saved diagnostic entries on this Mac. It does not delete recordings, transcripts, or copies you already exported."
      )
    }
  }
}
