import Testing

@testable import HaeCore

@Test
func deduplicatesLongestTokenOverlap() {
  let result = TranscriptDeduplicator.removingOverlap(
    previousText: "Vi tar utrullingen på tirsdag.",
    newText: "på tirsdag. Deretter følger vi med."
  )
  #expect(result == "Deretter følger vi med.")
}

@Test
func deduplicationPreservesNonOverlappingText() {
  #expect(
    TranscriptDeduplicator.removingOverlap(previousText: "første", newText: "andre del")
      == "andre del"
  )
}

@Test
func srtTimestampFormatting() {
  #expect(TranscriptStore.srtTimestamp(milliseconds: 3_723_045) == "01:02:03,045")
  #expect(TranscriptStore.srtTimestamp(milliseconds: -1) == "00:00:00,000")
}
