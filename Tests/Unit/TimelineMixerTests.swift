import Testing

@testable import HaeCore

@Test
func timelineOrdersOutOfOrderBuffers() {
  var timeline = AudioTimeline()
  timeline.insert(TimedAudioBuffer(source: .system, startFrame: 2, samples: [3, 4]))
  timeline.insert(TimedAudioBuffer(source: .system, startFrame: 0, samples: [1, 2]))
  #expect(timeline.read(startFrame: 0, count: 4) == [1, 2, 3, 4])
}

@Test
func timelineInsertsSilenceForMissingInput() {
  var timeline = AudioTimeline()
  timeline.insert(TimedAudioBuffer(source: .system, startFrame: 2, samples: [1, 1]))
  #expect(timeline.read(startFrame: 0, count: 5) == [0, 0, 1, 1, 0])
}

@Test
func mixerWaitsForBothSourcesAndAppliesGain() throws {
  var mixer = TimelineMixer(
    configuration: MixerConfiguration(
      systemGain: 1,
      microphoneGain: 0.5,
      outputChunkFrames: 4
    )
  )
  #expect(
    mixer.ingest(TimedAudioBuffer(source: .system, startFrame: 0, samples: [0.2, 0.2])).isEmpty
  )
  let chunks = mixer.ingest(
    TimedAudioBuffer(source: .microphone, startFrame: 0, samples: [0.4, 0.4])
  )
  let chunk = try #require(chunks.first)
  #expect(abs(chunk[0] - 0.4) < 0.0001)
  #expect(abs(chunk[1] - 0.4) < 0.0001)
}

@Test
func mixerSoftLimitsClipping() throws {
  var mixer = TimelineMixer(configuration: MixerConfiguration(outputChunkFrames: 2))
  _ = mixer.ingest(TimedAudioBuffer(source: .system, startFrame: 0, samples: [1, -1]))
  let chunk = try #require(
    mixer.ingest(
      TimedAudioBuffer(source: .microphone, startFrame: 0, samples: [1, -1])
    ).first
  )
  #expect(chunk[0] <= 1)
  #expect(chunk[1] >= -1)
}

@Test
func mixerFlushesOneSourceWithSilenceForTheOther() throws {
  var mixer = TimelineMixer(configuration: MixerConfiguration(outputChunkFrames: 4))
  _ = mixer.ingest(TimedAudioBuffer(source: .system, startFrame: 0, samples: [0.2, 0.3]))
  let chunk = try #require(mixer.flush().first)
  #expect(abs(chunk[0] - 0.2) < 0.0001)
  #expect(abs(chunk[1] - 0.3) < 0.0001)
}
