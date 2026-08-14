# Hæ?

Hæ? is a native macOS menu-bar recorder and local meeting transcription app.
It captures system audio and microphone audio from one ScreenCaptureKit stream,
mixes both sources on their presentation timeline, writes crash-tolerant 16 kHz
mono PCM, then transcribes the durable file in-process with whisper.cpp.

The current implementation is the Phase 0 spike. It intentionally has no live
transcription, cloud service, network entitlement, virtual audio driver, Python
runtime, or background server.

## Requirements

- Apple Silicon Mac
- macOS 15 or later
- Full Xcode with the macOS 15 SDK or later
- Nix, or the tools listed in `flake.nix`
- A signing team for permission-stable development builds

## Setup

```bash
nix develop
just bootstrap
just fetch-models
just build-whisper
open Hae.xcodeproj
```

`just fetch-models` downloads about 1.08 GB from the official model
repositories and rejects any file whose SHA-256 does not match the pinned
manifest. `LocalModels/` and the built XCFramework are ignored by Git.

For Debug runs, choose **Import models** in the menu and select `LocalModels`.
The app verifies both hashes and copies the files once into its sandboxed
application support directory. Release packaging puts verified models inside
the app bundle.

## Development tasks

```bash
just format
just lint
just test
just build
just smoke-model
just ci
```

All development tasks are exposed through the `justfile`. SwiftPM builds the
core and menu-bar source for quick local verification. The Xcode project builds
the signed `.app` and links the generated whisper XCFramework.

`just smoke-model` builds a temporary CPU-only whisper.cpp runner under
`.cache/`, checks the pinned model and VAD with the upstream audio fixture, then
compiles and runs the production Swift bridge against the same files. This can
run with Command Line Tools, but it does not replace the Metal or Teams checks.

## Phase 0 manual proof

The first spike is not accepted until it passes the 60-second Teams procedure
in [docs/TESTING.md](docs/TESTING.md). This requires an interactive, signed app
run with the pinned model files and cannot be replaced by unit tests.

## Local files

Sessions are stored under the application support directory selected by
`FileManager`, inside `Hae/Sessions/<UUID>/`. Each session keeps an atomic JSON
manifest, raw mixed PCM, and final JSON, Markdown, text, and SRT transcript
files. Failed transcription does not remove the PCM recording.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/PRIVACY.md](docs/PRIVACY.md) for design and privacy details.
