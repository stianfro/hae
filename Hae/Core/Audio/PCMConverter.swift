import AVFoundation
import Foundation

public enum PCMConverterError: Error, LocalizedError, Sendable {
  case invalidTargetFormat
  case converterCreationFailed
  case outputBufferCreationFailed
  case conversionFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidTargetFormat:
      "Could not create the 16 kHz mono audio format."
    case .converterCreationFailed:
      "Could not create an audio converter for the captured format."
    case .outputBufferCreationFailed:
      "Could not allocate a converted audio buffer."
    case .conversionFailed(let message):
      "Audio conversion failed: \(message)"
    }
  }
}

public final class PCMConverter: @unchecked Sendable {
  private final class InputProvider: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false

    init(buffer: AVAudioPCMBuffer) {
      self.buffer = buffer
    }
  }

  public static let targetSampleRate: Double = 16_000

  private var formatConverter: AVAudioConverter?
  private var convertedInputFormat: AVAudioFormat?
  private var sampleRateConverter: AVAudioConverter?
  private var resamplerInputFormat: AVAudioFormat?
  private var totalInputFrames: Int64 = 0
  private var totalOutputFrames: Int64 = 0
  private let targetFormat: AVAudioFormat

  public init() throws {
    guard
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.targetSampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      throw PCMConverterError.invalidTargetFormat
    }
    self.targetFormat = targetFormat
  }

  public func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
    let planar = try floatPlanarBuffer(from: input)
    guard
      let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: planar.format.sampleRate,
        channels: 1,
        interleaved: false
      ),
      let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: planar.frameLength)
    else {
      throw PCMConverterError.outputBufferCreationFailed
    }
    mono.frameLength = planar.frameLength
    guard let monoSamples = mono.floatChannelData?[0],
      let channels = planar.floatChannelData
    else { return [] }

    let channelCount = Int(planar.format.channelCount)
    let frameCount = Int(planar.frameLength)
    for frame in 0..<frameCount {
      var sum: Float = 0
      for channel in 0..<channelCount { sum += channels[channel][frame] }
      monoSamples[frame] = sum / Float(channelCount)
    }

    if monoFormat.sampleRate == Self.targetSampleRate {
      totalInputFrames += Int64(frameCount)
      totalOutputFrames += Int64(frameCount)
      return Array(UnsafeBufferPointer(start: monoSamples, count: frameCount))
    }

    if sampleRateConverter == nil || resamplerInputFormat != monoFormat {
      guard let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
        throw PCMConverterError.converterCreationFailed
      }
      converter.primeMethod = .none
      sampleRateConverter = converter
      resamplerInputFormat = monoFormat
      totalInputFrames = 0
      totalOutputFrames = 0
    }
    guard let sampleRateConverter else { throw PCMConverterError.converterCreationFailed }

    let ratio = Self.targetSampleRate / input.format.sampleRate
    let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 64)
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
      throw PCMConverterError.outputBufferCreationFailed
    }

    let inputProvider = InputProvider(buffer: mono)
    var conversionError: NSError?
    let status = sampleRateConverter.convert(to: output, error: &conversionError) {
      _, inputStatus in
      if inputProvider.supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      inputProvider.supplied = true
      inputStatus.pointee = .haveData
      return inputProvider.buffer
    }
    guard status != .error else {
      throw PCMConverterError.conversionFailed(
        conversionError?.localizedDescription ?? "unknown converter error"
      )
    }
    guard let channel = output.floatChannelData?[0] else { return [] }
    totalInputFrames += Int64(input.frameLength)
    totalOutputFrames += Int64(output.frameLength)
    return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
  }

  public func finish() throws -> [Float] {
    guard let sampleRateConverter, let resamplerInputFormat else { return [] }
    let expectedTotal = Int64(
      (Double(totalInputFrames) * Self.targetSampleRate / resamplerInputFormat.sampleRate)
        .rounded()
    )
    let required = Int(max(0, expectedTotal - totalOutputFrames))
    guard required > 0 else { return [] }

    var drained: [Float] = []
    for _ in 0..<8 where drained.count < required {
      let capacity = AVAudioFrameCount(required - drained.count + 64)
      guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
        throw PCMConverterError.outputBufferCreationFailed
      }
      var conversionError: NSError?
      let status = sampleRateConverter.convert(to: output, error: &conversionError) {
        _, inputStatus in
        inputStatus.pointee = .endOfStream
        return nil
      }
      if status == .error {
        throw PCMConverterError.conversionFailed(
          conversionError?.localizedDescription ?? "unknown converter drain error"
        )
      }
      if let channel = output.floatChannelData?[0], output.frameLength > 0 {
        drained.append(
          contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        )
      }
      if status == .endOfStream { break }
    }

    if drained.count < required {
      drained.append(contentsOf: repeatElement(Float.zero, count: required - drained.count))
    } else if drained.count > required {
      drained.removeLast(drained.count - required)
    }
    totalOutputFrames += Int64(drained.count)
    return drained
  }

  private func floatPlanarBuffer(from input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
    if input.format.commonFormat == .pcmFormatFloat32, !input.format.isInterleaved {
      return input
    }
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: input.format.sampleRate,
        channels: input.format.channelCount,
        interleaved: false
      )
    else { throw PCMConverterError.invalidTargetFormat }

    if formatConverter == nil || convertedInputFormat != input.format {
      guard let converter = AVAudioConverter(from: input.format, to: format) else {
        throw PCMConverterError.converterCreationFailed
      }
      formatConverter = converter
      convertedInputFormat = input.format
    }
    guard let formatConverter,
      let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: input.frameLength)
    else { throw PCMConverterError.outputBufferCreationFailed }

    let inputProvider = InputProvider(buffer: input)
    var conversionError: NSError?
    let status = formatConverter.convert(to: output, error: &conversionError) {
      _, inputStatus in
      if inputProvider.supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      inputProvider.supplied = true
      inputStatus.pointee = .haveData
      return inputProvider.buffer
    }
    guard status != .error else {
      throw PCMConverterError.conversionFailed(
        conversionError?.localizedDescription ?? "unknown format converter error"
      )
    }
    return output
  }
}
