import AVFoundation
import Foundation

public struct CapturedAudioBuffer: @unchecked Sendable {
  public let source: AudioSource
  public let presentationTimeSeconds: Double
  public let pcmBuffer: AVAudioPCMBuffer

  public init(
    source: AudioSource,
    presentationTimeSeconds: Double,
    pcmBuffer: AVAudioPCMBuffer
  ) {
    self.source = source
    self.presentationTimeSeconds = presentationTimeSeconds
    self.pcmBuffer = pcmBuffer
  }
}
