import AVFoundation
import Foundation

public struct MicrophoneDevice: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public enum MicrophoneDeviceRepository {
  public static func availableDevices() -> [MicrophoneDevice] {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external],
      mediaType: .audio,
      position: .unspecified
    )
    return discovery.devices
      .map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public static func selectedDevice(savedID: String?) -> MicrophoneDevice? {
    let devices = availableDevices()
    if let savedID, let saved = devices.first(where: { $0.id == savedID }) {
      return saved
    }
    guard let defaultDevice = AVCaptureDevice.default(for: .audio) else {
      return devices.first
    }
    return MicrophoneDevice(id: defaultDevice.uniqueID, name: defaultDevice.localizedName)
  }
}
