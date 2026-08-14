# Testing

## Automated checks

Run all source checks through `just`:

```bash
just ci
```

The unit suite covers model hashing, PCM conversion, sample-rate conversion,
mono downmix, audio levels, out-of-order timeline input, missing-source silence,
mixer gain and limiting, manifest transitions, atomic replacement, partial PCM
recovery, finalization recovery, disk thresholds, Whisper control-token
filtering, overlap deduplication, source-track alignment, display fallback,
retention calculation, session management, export, and SRT timestamps.

Run the offline runtime smoke test after fetching the models:

```bash
just smoke-model
```

This builds pinned whisper.cpp with its CPU and Accelerate backends in
`.cache/`. It checks model loading, Silero VAD, inference, and the production
Swift C bridge. It is useful when full Xcode is unavailable. It does not test
Metal or ScreenCaptureKit.

## Phase 0 Teams proof

Use an Apple Silicon Mac running macOS 15 or later.

1. Run `just verify-models` and `just build-whisper`.
2. Open `Hae.xcodeproj`, select the Hae scheme, and configure a stable signing
   identity and bundle identifier.
3. Start a Teams call with one remote participant.
4. Run Hæ?, choose the intended microphone from the **Microphone** picker, and
   press **Start recording**.
5. Grant Screen Recording and microphone permissions when asked. Restart the
   development build if macOS requires it.
6. Confirm a red dot appears on the Hæ? menu-bar icon. Speak locally and ask
   the remote participant to speak, then confirm both meters leave the silent
   state.
7. Keep the call active for at least 60 seconds, then press **Stop recording**.
8. Confirm the red dot disappears, then wait for automatic final transcription.
   Do not invoke a separate command.
9. Press **Copy transcript**, paste into a temporary text field, and confirm it
   matches `transcript.txt`.
10. Press **Open .txt** and confirm `transcript.txt` opens in the default editor.
11. Open the session directory and check `audio-mix.pcm16le`, `session.json`,
   `transcript.json`, `transcript.md`, `transcript.txt`, and `transcript.srt`.
   Confirm `microphoneDeviceID` matches the selected microphone, or is `null`
   when **System default** was selected.
12. Listen to a temporary playback conversion of the PCM and confirm both
    speakers are present and synchronized.
13. Confirm the transcript contains phrases spoken by both participants with
    monotonic timestamps.
14. Repeat once with the Teams window minimized. Record whether audio-only
    ScreenCaptureKit remains reliable without a `.screen` output.

Do not mark Phase 0 passed until this evidence is recorded for the target Mac.

### Capture evidence

On 2026-08-14, the target Mac captured a Norwegian YouTube video as system
audio while the user spoke into the selected microphone. The user confirmed
that speech from both sources appeared in the resulting transcript. This
confirms the two-source capture, mixing, and final transcription path. The
60-second Teams test and minimized-window repeat above remain release checks.

## Failure checks

- Rename one local model and confirm recording still starts, stops, and keeps
  usable PCM while transcription reports a model error.
- Replace a model with a small file and confirm checksum validation rejects it.
- Quit during recording and confirm the raw PCM file remains readable up to its
  complete 16-bit frame boundary.
- Relaunch after interrupting recording and confirm **Retry transcription** is
  available, completes without a separate recovery command, and recreates all
  four transcript exports.
- Quit during finalization, relaunch, retry, and confirm the resulting exports
  contain no `<|nocaptions|>` or other Whisper control tokens.
- Confirm recording is refused below 1 GB free and warns below 3 GB free using
  an isolated test volume. Do not fill the system volume to test this.
- Disable network access and repeat the complete workflow.

## History and retention checks

- Relaunch and confirm completed and interrupted sessions appear in newest-first
  order.
- Rename a completed session and confirm the manifest and Markdown heading both
  use the new title.
- Export a session and confirm JSON, Markdown, text, and SRT are copied.
- Delete retained audio and confirm transcript exports remain available.
- Delete a session and confirm its session directory is removed.
- Set retention to immediate, seven days, thirty days, and indefinitely, then
  confirm only completed audio past the selected threshold is removed.
- Enable separate source tracks and confirm both files match the mixed file's
  duration and timeline.
- Select each connected display and confirm system audio remains captured.
