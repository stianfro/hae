import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct CaptureMetadata: Equatable, Sendable {
  public let displayID: CGDirectDisplayID
  public let microphoneDeviceID: String?
}

public enum CaptureEngineError: Error, LocalizedError, Sendable {
  case noDisplay
  case streamStopped(String)

  public var errorDescription: String? {
    switch self {
    case .noDisplay:
      "No display is available for system-audio capture."
    case .streamStopped(let message):
      "ScreenCaptureKit stopped the recording: \(message)"
    }
  }
}

public final class CaptureEngine: NSObject, SCStreamDelegate, @unchecked Sendable {
  private let systemQueue = DispatchQueue(label: "no.froystein.hae.capture.system")
  private let microphoneQueue = DispatchQueue(label: "no.froystein.hae.capture.microphone")
  private let output: CaptureStreamOutput
  private let stoppedHandler: @Sendable (Error) -> Void
  private var stream: SCStream?

  public init(
    audioHandler: @escaping @Sendable (CapturedAudioBuffer) -> Void,
    stoppedHandler: @escaping @Sendable (Error) -> Void
  ) {
    output = CaptureStreamOutput(handler: audioHandler)
    self.stoppedHandler = stoppedHandler
    super.init()
  }

  public func start(microphoneDeviceID: String?) async throws -> CaptureMetadata {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: false
    )
    let mainDisplayID = CGMainDisplayID()
    guard
      let display = content.displays.first(where: { $0.displayID == mainDisplayID })
        ?? content.displays.first
    else { throw CaptureEngineError.noDisplay }

    let currentApplication = content.applications.first {
      $0.processID == ProcessInfo.processInfo.processIdentifier
    }
    let filter = SCContentFilter(
      display: display,
      excludingApplications: currentApplication.map { [$0] } ?? [],
      exceptingWindows: []
    )
    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.captureMicrophone = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = 48_000
    configuration.channelCount = 2
    configuration.microphoneCaptureDeviceID = microphoneDeviceID
    configuration.streamName = "Hae-\(UUID().uuidString)"

    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: systemQueue)
    try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: microphoneQueue)
    self.stream = stream
    try await stream.startCapture()
    return CaptureMetadata(
      displayID: display.displayID,
      microphoneDeviceID: microphoneDeviceID
    )
  }

  public func stop() async throws {
    guard let stream else { return }
    try await stream.stopCapture()
    self.stream = nil
  }

  public func stream(_ stream: SCStream, didStopWithError error: any Error) {
    self.stream = nil
    stoppedHandler(CaptureEngineError.streamStopped(error.localizedDescription))
  }
}
