import Combine
import Foundation
import HaeCore
import Testing

@testable import HaeApplication

@Suite
@MainActor
struct MenuStateTests {
  @Test(arguments: [SessionStatus.captured, .finalizing, .interrupted, .failed])
  func unfinishedSessionsRequireUsableAudioForRetry(status: SessionStatus) {
    #expect(item(status: status, hasAudio: true).canRetryTranscription)
    #expect(!item(status: status, hasAudio: false).canRetryTranscription)
  }

  @Test(arguments: [SessionStatus.recording, .completed])
  func recordingAndCompletedSessionsCannotRetry(status: SessionStatus) {
    #expect(!item(status: status, hasAudio: true).canRetryTranscription)
    #expect(!item(status: status, hasAudio: false).canRetryTranscription)
  }

  @Test
  func statusLabelsCoverEverySessionState() {
    let cases: [(SessionStatus, String)] = [
      (.recording, "Recording"),
      (.captured, "Captured"),
      (.finalizing, "Transcribing"),
      (.completed, "Complete"),
      (.interrupted, "Interrupted"),
      (.failed, "Failed"),
    ]
    for (status, expected) in cases {
      #expect(item(status: status).statusText == expected)
    }
  }

  @Test
  func durationLabelsClampNegativeValuesAndTruncatePartialSeconds() {
    let cases: [(Int64, String)] = [
      (-16_000, "0:00"),
      (0, "0:00"),
      (15_999, "0:00"),
      (16_000, "0:01"),
      (59 * 16_000 + 15_999, "0:59"),
      (60 * 16_000, "1:00"),
      (3_599 * 16_000, "59:59"),
      (3_600 * 16_000, "1:00:00"),
      (3_661 * 16_000, "1:01:01"),
      (25 * 3_600 * 16_000, "25:00:00"),
    ]
    for (frames, expected) in cases {
      #expect(item(durationFrames: frames).durationText == expected)
    }
  }

  @Test
  func historyKeepsOriginalHostedRoutingMetadata() {
    let original = HostedTranscriptionConfiguration(
      baseURL: "https://original.example.com/v1", model: "original-speech-model",
      language: "nb", responseFormat: .verboseJSON
    )
    var draft = original
    let session = item(status: .failed, hasAudio: true, hostedConfiguration: draft)
    draft.baseURL = "https://different.example.com/v1"
    draft.model = "different-speech-model"
    draft.language = "en"
    draft.responseFormat = .json

    #expect(session.hostedConfiguration == original)
    #expect(session.hostedConfiguration != draft)
    #expect(session.canRetryTranscription)
    #expect(item(status: .failed, hasAudio: true).hostedConfiguration == nil)
  }

  @Test
  func transcriptionDestinationDoesNotChangeRetryEligibility() {
    let hosted = HostedTranscriptionConfiguration(
      baseURL: "https://inference.example.com/v1", model: "speech-model"
    )
    for status in [
      SessionStatus.recording, .captured, .finalizing, .completed, .interrupted, .failed,
    ] {
      for hasAudio in [false, true] {
        let local = item(status: status, hasAudio: hasAudio)
        let remote = item(status: status, hasAudio: hasAudio, hostedConfiguration: hosted)
        #expect(local.canRetryTranscription == remote.canRetryTranscription)
      }
    }
  }

  @Test
  func meterPublishesToItsOwnObserversWithoutInvalidatingItsOwner() {
    let owner = MeterOwner()
    #expect(owner.audioMeter.snapshot == AudioMeterSnapshot(system: 0, microphone: 0))
    var ownerChanges = 0
    var snapshots: [AudioMeterSnapshot] = []
    let ownerSubscription = owner.objectWillChange.sink { ownerChanges += 1 }
    let meterSubscription = owner.audioMeter.$snapshot.dropFirst().sink { snapshots.append($0) }
    let first = AudioMeterSnapshot(system: 0.5, microphone: 0.25)
    let second = AudioMeterSnapshot(system: 0.2, microphone: 0.75)

    withExtendedLifetime([ownerSubscription, meterSubscription]) {
      owner.audioMeter.snapshot = first
      owner.audioMeter.snapshot = second
      #expect(snapshots == [first, second])
      #expect(owner.audioMeter.snapshot == second)
      #expect(ownerChanges == 0)

      owner.title = "Owner changed"
      #expect(ownerChanges == 1)
      #expect(snapshots == [first, second])
    }
  }

  private func item(
    status: SessionStatus = .completed,
    durationFrames: Int64 = 0,
    hasAudio: Bool = false,
    hostedConfiguration: HostedTranscriptionConfiguration? = nil
  ) -> SessionListItem {
    SessionListItem(
      id: UUID(), title: "Test session", status: status,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000), durationFrames: durationFrames,
      hasTranscript: status == .completed, hasAudio: hasAudio,
      hostedConfiguration: hostedConfiguration
    )
  }
}

@MainActor
private final class MeterOwner: ObservableObject {
  let audioMeter = AudioMeterModel()
  @Published var title = "Unchanged"
}
