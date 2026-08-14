import SwiftUI

@main
struct HaeApp: App {
  @StateObject private var coordinator = AppCoordinator()

  var body: some Scene {
    MenuBarExtra("Hæ?", systemImage: "waveform") {
      MenuBarView(coordinator: coordinator)
    }
    .menuBarExtraStyle(.window)
  }
}
