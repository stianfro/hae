import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

public final class CaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
  private let handler: @Sendable (CapturedAudioBuffer) -> Void

  public init(handler: @escaping @Sendable (CapturedAudioBuffer) -> Void) {
    self.handler = handler
  }

  public func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
    guard type == .audio || type == .microphone else { return }
    guard let description = sampleBuffer.formatDescription,
      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
      let format = AVAudioFormat(streamDescription: streamDescription)
    else { return }

    let frameCount = sampleBuffer.numSamples
    guard frameCount > 0,
      let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frameCount)
      )
    else { return }
    pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer,
      at: 0,
      frameCount: Int32(frameCount),
      into: pcmBuffer.mutableAudioBufferList
    )
    guard status == noErr else { return }

    let source: AudioSource = type == .audio ? .system : .microphone
    handler(
      CapturedAudioBuffer(
        source: source,
        presentationTimeSeconds: sampleBuffer.presentationTimeStamp.seconds,
        pcmBuffer: pcmBuffer
      )
    )
  }
}
