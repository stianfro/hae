import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct CaptureDisplayDevice: Identifiable, Equatable, Sendable {
  public let id: CGDirectDisplayID
  public let name: String
  public let width: Int
  public let height: Int

  public init(id: CGDirectDisplayID, name: String, width: Int, height: Int) {
    self.id = id
    self.name = name
    self.width = width
    self.height = height
  }
}

public enum CaptureDisplayRepository {
  public static func availableDisplays() async throws -> [CaptureDisplayDevice] {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: false
    )
    let mainID = CGMainDisplayID()
    return content.displays
      .map { display in
        CaptureDisplayDevice(
          id: display.displayID,
          name: display.displayID == mainID ? "Main display" : "Display \(display.displayID)",
          width: display.width,
          height: display.height
        )
      }
      .sorted { left, right in
        if left.id == mainID { return true }
        if right.id == mainID { return false }
        return left.id < right.id
      }
  }

  public static func preferredDisplay(
    from displays: [CaptureDisplayDevice],
    savedID: CGDirectDisplayID?,
    mainID: CGDirectDisplayID = CGMainDisplayID()
  ) -> CaptureDisplayDevice? {
    if let savedID, let saved = displays.first(where: { $0.id == savedID }) {
      return saved
    }
    return displays.first(where: { $0.id == mainID }) ?? displays.first
  }
}
