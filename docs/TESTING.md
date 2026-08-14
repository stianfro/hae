# Testing

## Automated checks

Run all source checks through `just`:

```bash
just ci
```

The unit suite covers model hashing, PCM conversion, sample-rate conversion,
mono downmix, audio levels, out-of-order timeline input, missing-source silence,
mixer gain and limiting, manifest transitions, atomic replacement, partial PCM
recovery, overlap deduplication, and SRT timestamps.

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
6. Speak locally and ask the remote participant to speak. Confirm both meters
   leave the silent state.
7. Keep the call active for at least 60 seconds, then press **Stop recording**.
8. Wait for automatic final transcription. Do not invoke a separate command.
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

## Failure checks

- Rename one local model and confirm recording still starts, stops, and keeps
  usable PCM while transcription reports a model error.
- Replace a model with a small file and confirm checksum validation rejects it.
- Quit during recording and confirm the raw PCM file remains readable up to its
  complete 16-bit frame boundary.
- Disable network access and repeat the complete workflow.
