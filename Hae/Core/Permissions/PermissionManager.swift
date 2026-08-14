import AVFoundation
import CoreGraphics
import Foundation

public enum PermissionState: String, Codable, Sendable {
  case unknown
  case requesting
  case granted
  case denied
  case restartRequired
}

public struct PermissionSnapshot: Equatable, Sendable {
  public let screenCapture: PermissionState
  public let microphone: PermissionState

  public var canRecordBothSources: Bool {
    screenCapture == .granted && microphone == .granted
  }
}

public actor PermissionManager {
  public init() {}

  public func current() -> PermissionSnapshot {
    PermissionSnapshot(
      screenCapture: CGPreflightScreenCaptureAccess() ? .granted : .unknown,
      microphone: microphoneState(AVAudioApplication.shared.recordPermission)
    )
  }

  public func requestRequiredPermissions() async -> PermissionSnapshot {
    var screenState: PermissionState = .granted
    if !CGPreflightScreenCaptureAccess() {
      screenState = CGRequestScreenCaptureAccess() ? .granted : .denied
    }

    var microphone = microphoneState(AVAudioApplication.shared.recordPermission)
    if microphone == .unknown {
      let granted = await withCheckedContinuation { continuation in
        AVAudioApplication.requestRecordPermission { allowed in
          continuation.resume(returning: allowed)
        }
      }
      microphone = granted ? .granted : .denied
    }
    return PermissionSnapshot(screenCapture: screenState, microphone: microphone)
  }

  private func microphoneState(
    _ permission: AVAudioApplication.recordPermission
  ) -> PermissionState {
    switch permission {
    case .granted:
      .granted
    case .denied:
      .denied
    default:
      .unknown
    }
  }
}
