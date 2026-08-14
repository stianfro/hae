import AppKit
import SwiftUI

#if canImport(HaeCore)
  import HaeCore
#endif

struct MenuBarView: View {
  @ObservedObject var coordinator: AppCoordinator
  @State private var showQuitConfirmation = false
  @State private var historyExpanded = true
  @State private var settingsExpanded = false
  @State private var renameTarget: SessionListItem?
  @State private var renameTitle = ""
  @State private var deleteTarget: SessionListItem?
  @State private var deleteAudioTarget: SessionListItem?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Image(systemName: "waveform")
          .font(.title2)
        VStack(alignment: .leading, spacing: 2) {
          Text("Hæ?")
            .font(.headline)
          Text(coordinator.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }

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
      .pickerStyle(.menu)
      .disabled(coordinator.isBusy)

      AudioMeterView(label: "System audio", value: coordinator.meter.system)
      AudioMeterView(label: coordinator.activeMicrophoneName, value: coordinator.meter.microphone)

      if case .finalizing(let progress) = coordinator.state {
        ProgressView(value: progress)
      }

      if let modelNotice = coordinator.modelNotice {
        Label(modelNotice, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let storageNotice = coordinator.storageNotice {
        Label(storageNotice, systemImage: "externaldrive.badge.exclamationmark")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      ForEach(coordinator.signalWarnings, id: \.self) { warning in
        Label(warning, systemImage: "waveform.slash")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      Button(action: coordinator.toggleRecording) {
        Label(buttonTitle, systemImage: buttonIcon)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(buttonDisabled)

      if coordinator.canRetryTranscription {
        Button(action: coordinator.retryTranscription) {
          Label("Retry transcription", systemImage: "arrow.clockwise")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }

      if coordinator.hasCompletedTranscript {
        VStack(alignment: .leading, spacing: 8) {
          Text("Completed transcript")
            .font(.caption.weight(.semibold))

          HStack {
            Button(action: coordinator.copyTranscriptToClipboard) {
              Label("Copy transcript", systemImage: "doc.on.doc")
                .frame(maxWidth: .infinity)
            }
            Button(action: coordinator.openTranscriptText) {
              Label("Open .txt", systemImage: "doc.text")
                .frame(maxWidth: .infinity)
            }
          }
          .buttonStyle(.bordered)

          if let notice = coordinator.transcriptActionNotice {
            Text(notice)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      if !coordinator.sessionHistory.isEmpty {
        Divider()
        DisclosureGroup(isExpanded: $historyExpanded) {
          ScrollView {
            LazyVStack(spacing: 8) {
              ForEach(coordinator.sessionHistory) { session in
                SessionHistoryRow(
                  session: session,
                  isBusy: coordinator.isBusy,
                  open: { coordinator.openTranscript(sessionID: session.id) },
                  retry: { coordinator.retryTranscription(sessionID: session.id) },
                  export: { coordinator.exportSession(sessionID: session.id) },
                  reveal: { coordinator.revealSession(sessionID: session.id) },
                  rename: {
                    renameTarget = session
                    renameTitle = session.title
                  },
                  deleteAudio: { deleteAudioTarget = session },
                  delete: { deleteTarget = session }
                )
              }
            }
          }
          .frame(maxHeight: 190)
          .padding(.top, 8)
        } label: {
          Label("History", systemImage: "clock.arrow.circlepath")
            .font(.subheadline.weight(.semibold))
        }
      }

      DisclosureGroup(isExpanded: $settingsExpanded) {
        VStack(alignment: .leading, spacing: 10) {
          Toggle(
            "Launch at login",
            isOn: Binding(
              get: { coordinator.launchAtLoginEnabled },
              set: { coordinator.setLaunchAtLogin($0) }
            )
          )
          .disabled(coordinator.isBusy)

          Toggle(
            "Show completion notification",
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

          Toggle(
            "Preserve separate source tracks",
            isOn: Binding(
              get: { coordinator.preserveSeparateTracksEnabled },
              set: { coordinator.setPreserveSeparateTracks($0) }
            )
          )
          .disabled(coordinator.isBusy)

          Picker(
            "Audio retention",
            selection: Binding(
              get: { coordinator.audioRetentionPolicy },
              set: { coordinator.setAudioRetentionPolicy($0) }
            )
          ) {
            Text("Delete after transcription").tag(AudioRetentionPolicy.immediately)
            Text("Keep for 7 days").tag(AudioRetentionPolicy.sevenDays)
            Text("Keep for 30 days").tag(AudioRetentionPolicy.thirtyDays)
            Text("Keep indefinitely").tag(AudioRetentionPolicy.forever)
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

          GainControl(
            label: "System audio gain",
            value: Binding(
              get: { coordinator.systemAudioGain },
              set: { coordinator.setSystemAudioGain($0) }
            )
          )
          .disabled(coordinator.isBusy)

          GainControl(
            label: "Microphone gain",
            value: Binding(
              get: { coordinator.microphoneGain },
              set: { coordinator.setMicrophoneGain($0) }
            )
          )
          .disabled(coordinator.isBusy)

          HStack {
            Button("Sessions folder") { coordinator.openSessionsFolder() }
            Button("Import models") { coordinator.importModels() }
              .disabled(coordinator.isBusy)
          }

          HStack {
            Button("Current session") { coordinator.openSessionDirectory() }
              .disabled(coordinator.sessionDirectory == nil)
            Button("Privacy settings") { coordinator.openPrivacySettings() }
          }

          Button("Verify transcription models") { coordinator.verifyInstalledModels() }
            .disabled(coordinator.isBusy)
        }
        .font(.caption)
        .padding(.top, 8)
      } label: {
        Label("Settings", systemImage: "gearshape")
          .font(.subheadline.weight(.semibold))
      }

      if let notice = coordinator.sessionActionNotice {
        Text(notice)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()
        Button("Quit") {
          if coordinator.isBusy {
            showQuitConfirmation = true
          } else {
            NSApplication.shared.terminate(nil)
          }
        }
      }
      .font(.caption)
    }
    .padding(16)
    .frame(width: 380)
    .onAppear { coordinator.refreshMicrophones() }
    .task { await coordinator.refreshDisplays() }
    .alert("Quit Hæ?", isPresented: $showQuitConfirmation) {
      Button("Keep running", role: .cancel) {}
      Button("Quit", role: .destructive) { NSApplication.shared.terminate(nil) }
    } message: {
      Text("Quitting now interrupts active work. The durable recording will remain recoverable.")
    }
    .alert("Rename session", isPresented: renameAlertPresented) {
      TextField("Session title", text: $renameTitle)
      Button("Cancel", role: .cancel) { renameTarget = nil }
      Button("Rename") {
        if let renameTarget {
          coordinator.renameSession(sessionID: renameTarget.id, title: renameTitle)
        }
        renameTarget = nil
      }
    }
    .alert("Delete session?", isPresented: deleteAlertPresented) {
      Button("Cancel", role: .cancel) { deleteTarget = nil }
      Button("Delete", role: .destructive) {
        if let deleteTarget { coordinator.deleteSession(sessionID: deleteTarget.id) }
        deleteTarget = nil
      }
    } message: {
      Text("This removes the transcript, manifest, and any retained audio.")
    }
    .alert("Delete retained audio?", isPresented: deleteAudioAlertPresented) {
      Button("Cancel", role: .cancel) { deleteAudioTarget = nil }
      Button("Delete audio", role: .destructive) {
        if let deleteAudioTarget {
          coordinator.deleteSessionAudio(sessionID: deleteAudioTarget.id)
        }
        deleteAudioTarget = nil
      }
    } message: {
      Text("The transcript and its exports will be kept.")
    }
  }

  private var buttonTitle: String {
    switch coordinator.state {
    case .recording:
      "Stop recording"
    case .preparing:
      "Preparing"
    case .finalizing:
      "Transcribing"
    default:
      "Start recording"
    }
  }

  private var buttonIcon: String {
    coordinator.state == .recording ? "stop.fill" : "record.circle"
  }

  private var buttonDisabled: Bool {
    switch coordinator.state {
    case .preparing, .finalizing:
      true
    default:
      false
    }
  }

  private var renameAlertPresented: Binding<Bool> {
    Binding(
      get: { renameTarget != nil },
      set: { if !$0 { renameTarget = nil } }
    )
  }

  private var deleteAlertPresented: Binding<Bool> {
    Binding(
      get: { deleteTarget != nil },
      set: { if !$0 { deleteTarget = nil } }
    )
  }

  private var deleteAudioAlertPresented: Binding<Bool> {
    Binding(
      get: { deleteAudioTarget != nil },
      set: { if !$0 { deleteAudioTarget = nil } }
    )
  }
}

private struct SessionHistoryRow: View {
  let session: SessionListItem
  let isBusy: Bool
  let open: () -> Void
  let retry: () -> Void
  let export: () -> Void
  let reveal: () -> Void
  let rename: () -> Void
  let deleteAudio: () -> Void
  let delete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: open) {
        VStack(alignment: .leading, spacing: 2) {
          Text(session.title)
            .font(.caption.weight(.medium))
            .lineLimit(1)
          HStack(spacing: 5) {
            Text(session.createdAt, style: .date)
            Text(session.createdAt, style: .time)
            Text("·")
            Text(session.durationText)
            Text("·")
            Text(session.statusText)
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!session.hasTranscript)

      Menu {
        Button("Open transcript", action: open)
          .disabled(!session.hasTranscript)
        if session.canRetryTranscription {
          Button("Retry transcription", action: retry)
            .disabled(isBusy)
        }
        Button("Export transcript files", action: export)
          .disabled(!session.hasTranscript || isBusy)
        Button("Reveal files", action: reveal)
        Button("Rename", action: rename)
          .disabled(isBusy)
        if session.hasAudio {
          Button("Delete retained audio", action: deleteAudio)
            .disabled(isBusy)
        }
        Divider()
        Button("Delete session", role: .destructive, action: delete)
          .disabled(isBusy)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(8)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct AudioMeterView: View {
  let label: String
  let value: Float

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label)
          .lineLimit(1)
        Spacer()
        Text(value > 0.03 ? "Active" : "Silent")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      ProgressView(value: Double(value))
        .tint(value > 0.85 ? .orange : .accentColor)
    }
    .font(.caption)
  }
}

private struct GainControl: View {
  let label: String
  @Binding var value: Float

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(label)
        Spacer()
        Text("\(value, specifier: "%.1f")×")
          .foregroundStyle(.secondary)
      }
      Slider(value: $value, in: 0...1.5, step: 0.1)
    }
  }
}
