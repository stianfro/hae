import CoreGraphics
import Foundation

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

enum CaptureDisplayRepositoryError: Error, LocalizedError, Equatable {
  case displayListFailed(CGError)

  var errorDescription: String? {
    switch self {
    case .displayListFailed(let error):
      "Core Graphics could not list active displays (error \(error.rawValue))."
    }
  }
}

public enum CaptureDisplayRepository {
  public static func availableDisplays() async throws -> [CaptureDisplayDevice] {
    // Display metadata does not need Screen Recording access. Request capture access only
    // when the user starts recording, not while opening the menu or Settings.
    try availableDisplays(
      mainID: CGMainDisplayID(),
      displayList: CGGetActiveDisplayList,
      displaySize: { (CGDisplayPixelsWide($0), CGDisplayPixelsHigh($0)) }
    )
  }

  static func availableDisplays(
    mainID: CGDirectDisplayID,
    displayList: (
      UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?
    ) -> CGError,
    displaySize: (CGDirectDisplayID) -> (width: Int, height: Int)
  ) throws -> [CaptureDisplayDevice] {
    var count: UInt32 = 0
    let countError = displayList(0, nil, &count)
    guard countError == .success else {
      throw CaptureDisplayRepositoryError.displayListFailed(countError)
    }
    guard count > 0 else { return [] }

    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    let listError = ids.withUnsafeMutableBufferPointer { buffer in
      displayList(UInt32(buffer.count), buffer.baseAddress, &count)
    }
    guard listError == .success else {
      throw CaptureDisplayRepositoryError.displayListFailed(listError)
    }

    return Set(ids.prefix(Int(count)))
      .sorted { left, right in
        if left == right { return false }
        if left == mainID { return true }
        if right == mainID { return false }
        return left < right
      }
      .map { id in
        let size = displaySize(id)
        return CaptureDisplayDevice(
          id: id,
          name: id == mainID ? "Main display" : "Display \(id)",
          width: size.width,
          height: size.height
        )
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
