# Hæ?

Hæ? is a native macOS menu-bar recorder with on-device or hosted meeting
transcription.
It captures system audio and microphone audio from one ScreenCaptureKit stream,
mixes both sources on their presentation timeline, writes crash-tolerant 16 kHz
mono PCM, then transcribes the durable file with whisper.cpp on your Mac or a
hosted audio API you choose.

The application records and transcribes automatically, keeps local session
history, recovers interrupted recordings, retries failed transcription, and
exports JSON, Markdown, text, and SRT. On-device transcription is the default;
hosted transcription is opt-in. There is no telemetry, virtual audio driver,
Python runtime, or background server. Live draft transcription remains deferred.
Settings open in a separate window, leaving the menu focused on recording and
recent sessions.

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

For on-device Debug runs, open **Settings > Transcription > Import models** and
select `LocalModels`.
The app verifies both hashes and copies the files once into its sandboxed
application support directory. Release packaging puts verified models inside
the app bundle. Hosted transcription does not require importing local models.

## Hosted transcription

Open **Settings** from the menu bar, or press **Command+,** while Hæ? is active.
In **Transcription**, choose **Hosted server**, enter your HTTPS API base URL
(for example `https://inference.example.com/v1`) and the exact speech-to-text
model ID from your provider, then save. API keys are optional for servers that
do not require authentication; saved keys live in macOS Keychain, scoped to the
endpoint, not in preferences or session files.

The server must implement OpenAI-compatible `POST /audio/transcriptions` with
multipart WAV uploads. Whisper-family speech-to-text models are suitable.
Embedding models and text-only chat models are not substitutes. A working
`/chat/completions` endpoint alone does not establish audio API compatibility.

- **JSON** is the compatibility default. Text-only responses receive one coarse
  timestamp interval per upload chunk, not sentence-level subtitle timings.
- **Verbose JSON** uses the server's segment timestamps when available.
- Leave language blank for detection, or enter a two-letter language code.
- After recording stops, mixed audio is uploaded in chunks of up to five minutes
  (about 9.6 MB each). This bounds upload memory, but words at chunk boundaries
  may be split. The durable local recording stays available if a request fails.
- HTTPS is required. Redirects are rejected, and server error bodies are not
  shown or logged. There is no automatic switch between local and hosted modes.
- New settings apply to new recordings. Retries use the original session's
  destination and model, with the currently saved key for that endpoint.
  Existing sessions remain on-device, even after hosted mode is enabled.

Only enable hosted mode for a server you trust and with permission to send the
recording. Local retention settings do not control copies held by your provider.
Provider-specific compatibility must be checked with its audio API docs or a
short recording you have permission to upload.

## Troubleshooting

The tray shows full, selectable error details with a **Copy error details**
button. Past failures are available from a history item's **Show error details**
menu action. Hosted errors include the HTTP status or a safe network error code.

For more detail, open **Settings > Diagnostics**, enable **Debug logging**, then
retry the failed transcription. Choose **Export debug log** to save a local
JSON Lines file you can inspect before sharing. Nothing is uploaded automatically.

Debug logging is off by default. It records timestamps, random operation IDs,
chunk sizes and durations, request timing, response status, network error codes,
and whether an API key was attached. It never records the key itself, headers,
URLs, model names, audio, transcripts, session titles, or raw server responses.
The local log keeps at most 1,000 events and 1 MiB under `Hae/Diagnostics` in the
application support directory. It persists across restarts until cleared or
replaced by newer events. Disable logging when finished; **Clear debug log**
removes retained diagnostics without touching recordings or settings.

For HTTP 401 or 403, check that the full API key was entered in Hæ and saved for
the current endpoint. The shortened key prefix shown by some providers is not a
usable credential. Editing the endpoint clears an unsaved key, so enter the URL
before the key. Updating the saved key also applies when retrying the same session.

## Development tasks

```bash
just format
just lint
just test
just build
just build-app
just smoke-model
just ci
```

All development tasks are exposed through the `justfile`. SwiftPM builds the
core and menu-bar source for quick local verification. The Xcode project builds
the signed `.app` and links the generated whisper XCFramework. `just build-app`
checks the native Xcode target without signing, using local `.cache/` build data.
Use `just test-filter <pattern>` for focused tests.

`just smoke-model` builds a temporary CPU-only whisper.cpp runner under
`.cache/`, checks the pinned model and VAD with the upstream audio fixture, then
compiles and runs the production Swift bridge against the same files. This can
run with Command Line Tools, but it does not replace the Metal or Teams checks.

## Phase 0 manual proof

The first spike is not accepted until it passes the 60-second Teams procedure
in [docs/TESTING.md](docs/TESTING.md). This requires an interactive, signed app
run with the pinned model files and cannot be replaced by unit tests.

The target Mac has passed a two-source Norwegian playback and microphone test.
The 60-second Teams and minimized-window repetitions remain release gates.

## Local files

Sessions are stored under the application support directory selected by
`FileManager`, inside `Hae/Sessions/<UUID>/`. Each session keeps an atomic JSON
manifest, raw mixed PCM, and final JSON, Markdown, text, and SRT transcript
files. Failed transcription does not remove the PCM recording. Audio retention
defaults to seven days and can be changed in Settings. Transcripts are kept
until the session is deleted.

## Distribution

Local ad hoc packages can be produced with `just package-release`. Public
distribution requires Developer ID signing and Apple notarization. The release
tasks create the ZIP, checksum, and a generated Homebrew Cask without adding a
Homebrew runtime dependency.

The current 0.1.0 package is an ad hoc signed personal beta. Install it with:

```bash
brew tap stianfro/tap
brew install --cask hae
```

macOS may block the first launch because Apple has not notarized this build.
If **Open Anyway** does not work, remove the quarantine attribute from this app
only:

```bash
/usr/bin/xattr -dr com.apple.quarantine /Applications/Hae.app
```

This does not disable Gatekeeper globally. Managed Macs may not permit this
exception.

See [docs/RELEASING.md](docs/RELEASING.md) for certificate setup, notarization,
GitHub Release commands, Cask generation, and release gates.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[docs/PRIVACY.md](docs/PRIVACY.md), and
[docs/LICENSING.md](docs/LICENSING.md) for design, privacy, and distribution
license details.

Hæ? is licensed under the MIT License. Bundled dependency and model license
texts are included in `Hae/Resources/ThirdPartyNotices.md` and in release apps.
