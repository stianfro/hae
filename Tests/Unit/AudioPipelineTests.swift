import AVFoundation
import Foundation
import Testing

@testable import HaeCore

@Test
func pcm16ConversionHandlesNegativeAndPartialSamples() {
  let data = Data([0x00, 0x80, 0x00, 0x00, 0xff, 0x7f, 0xff])
  let samples = PCMFileReader.decodePCM16LE(data)
  #expect(samples.count == 3)
  #expect(abs(samples[0] - -1) < 0.0001)
  #expect(abs(samples[1]) < 0.0001)
  #expect(abs(samples[2] - 1) < 0.0001)
}

@Test
func converterResamplesAndDownmixes() throws {
  let format = try #require(
    AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 48_000,
      channels: 2,
      interleaved: false
    )
  )
  let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
  input.frameLength = 4_800
  for channel in 0..<2 {
    let pointer = try #require(input.floatChannelData?[channel])
    for index in 0..<4_800 { pointer[index] = channel == 0 ? 0.25 : 0.75 }
  }

  let converter = try PCMConverter()
  var output = try converter.convert(input)
  output.append(contentsOf: try converter.finish())
  #expect(output.count == 1_600)
  #expect(abs(output[output.count / 2] - 0.5) < 0.03)
}

@Test
func levelMeter() {
  #expect(AudioLevelMeter.normalizedLevel(samples: [0, 0]) == 0)
  #expect(AudioLevelMeter.normalizedLevel(samples: [0.5, -0.5]) > 0.8)
}
