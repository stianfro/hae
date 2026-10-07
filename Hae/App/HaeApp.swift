import AppKit
import SwiftUI

@main
struct HaeApp: App {
  @StateObject private var coordinator = AppCoordinator()

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(coordinator: coordinator)
    } label: {
      MenuBarIcon(isRecording: coordinator.state == .recording)
    }
    .menuBarExtraStyle(.window)

    Window("Hæ? Settings", id: SettingsView.windowID) {
      SettingsView(coordinator: coordinator)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
    .commands { SettingsCommands() }
  }
}

private struct SettingsCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") {
        NSApplication.shared.activate()
        openWindow(id: SettingsView.windowID)
      }
      .keyboardShortcut(",", modifiers: .command)
    }
  }
}

private struct MenuBarIcon: View {
  let isRecording: Bool

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Image(systemName: "waveform")
        .frame(width: 18, height: 14)

      if isRecording {
        Circle()
          .fill(.red)
          .frame(width: 7, height: 7)
      }
    }
    .frame(width: 22, height: 16)
    .accessibilityLabel(isRecording ? "Hæ?, recording" : "Hæ?")
  }
}
