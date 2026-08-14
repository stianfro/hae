import Foundation

public struct WhisperParameters: Equatable, Sendable {
  public let language: String
  public let beamSize: Int32
  public let vadThreshold: Float
  public let minimumSpeechMilliseconds: Int32
  public let minimumSilenceMilliseconds: Int32
  public let speechPaddingMilliseconds: Int32
  public let maximumSpeechSeconds: Float
  public let sampleOverlapSeconds: Float

  public static let final = WhisperParameters(
    language: "no",
    beamSize: 5,
    vadThreshold: 0.5,
    minimumSpeechMilliseconds: 250,
    minimumSilenceMilliseconds: 300,
    speechPaddingMilliseconds: 200,
    maximumSpeechSeconds: 28,
    sampleOverlapSeconds: 0.1
  )
}
