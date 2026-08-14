import AppKit
import SwiftUI

#if canImport(HaeCore)
  import HaeCore
#endif

struct MenuBarView: View {
  @ObservedObject var coordinator: AppCoordinator
  @State private var showQuitConfirmation = false

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

      Button(action: coordinator.toggleRecording) {
        Label(buttonTitle, systemImage: buttonIcon)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(buttonDisabled)

      HStack {
        Button("Open session") { coordinator.openSessionDirectory() }
          .disabled(coordinator.sessionDirectory == nil)
        Button("Import models") { coordinator.importModels() }
          .disabled(coordinator.isBusy)
      }
      .font(.caption)

      HStack {
        Button("Privacy settings") { coordinator.openPrivacySettings() }
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
    .frame(width: 360)
    .alert("Quit Hæ??", isPresented: $showQuitConfirmation) {
      Button("Keep running", role: .cancel) {}
      Button("Quit", role: .destructive) { NSApplication.shared.terminate(nil) }
    } message: {
      Text("Quitting now interrupts active work. The durable recording will remain recoverable.")
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
