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
    return preferredDevice(savedID: savedID, devices: devices, defaultDevice: defaultDevice())
  }

  public static func defaultDevice() -> MicrophoneDevice? {
    AVCaptureDevice.default(for: .audio).map {
      MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName)
    }
  }

  public static func preferredDevice(
    savedID: String?,
    devices: [MicrophoneDevice],
    defaultDevice: MicrophoneDevice?
  ) -> MicrophoneDevice? {
    if let savedID, let saved = devices.first(where: { $0.id == savedID }) {
      return saved
    }
    return defaultDevice ?? devices.first
  }
}
