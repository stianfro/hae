# Model policy

The default model is `NbAiLab/nb-whisper-large` file
`ggml-model-q5_0.bin`.

| Item | Value |
| --- | --- |
| Model SHA-256 | `feb5951ae694a62cfeb81fb501f6cfa8cc50d96bcddb1e4e8215f7006bac23a2` |
| VAD file | `ggml-silero-v6.2.0.bin` |
| VAD SHA-256 | `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987` |
| Language | `no` |
| Task | transcribe |

Only models represented by `WhisperModelDescriptor` and passing SHA-256
validation may be loaded. The app has no model downloader. Setup scripts use
the official Nasjonalbiblioteket and ggml-org repository URLs and fail closed
on mismatch.

whisper.cpp is pinned as a Git submodule to v1.9.2 commit
`306c88f4d1286aec1bf96e544632897886af5501`. The build wrapper verifies the
commit, invokes the official XCFramework script, confirms an arm64 macOS slice,
and checks that the pinned script enables Metal.
