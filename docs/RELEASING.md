# Releasing Hæ?

Hæ? is distributed as a self-contained Apple Silicon application. Homebrew is
an installation option only. The installed application does not depend on
Homebrew or any other package manager.

## One-time Apple setup

Public builds need an Apple Developer Program membership and a `Developer ID
Application` certificate installed in the login keychain. Confirm the identity:

```bash
security find-identity -v -p codesigning
```

Create a keychain profile for `notarytool`. The command asks for the app-specific
password without placing it in shell history:

```bash
xcrun notarytool store-credentials hae-notary \
  --apple-id you@example.com \
  --team-id TEAMID
```

## Build and notarize

The repository version is read from the app bundle. For a public build, set the
Developer ID identity and notary profile, then run the `just` task:

```bash
export HAE_CODESIGN_IDENTITY='Developer ID Application: Name (TEAMID)'
export HAE_NOTARY_PROFILE='hae-notary'
just notarize-release
just generate-cask
```

This process:

1. Verifies both model hashes.
2. Builds the arm64 Release application.
3. Copies the verified models and application license into the bundle.
4. Signs the embedded framework and application with the hardened runtime.
5. Rejects network client or server entitlements.
6. Creates a ZIP archive and submits it to Apple notarization.
7. Staples and validates the ticket.
8. Recreates the ZIP and writes its SHA-256 checksum.
9. Generates a Homebrew Cask with the exact version and checksum.

Artifacts are written to `.cache/release/`:

```text
Hae-<version>-arm64.zip
Hae-<version>-arm64.zip.sha256
hae.rb
```

`just package-release` performs the same build with ad hoc signing when no
identity is provided. That output is for local testing, not public distribution.

## Publish with GitHub CLI

The release should remain a draft until the manual checks in
`docs/TESTING.md` pass. Create it with the GitHub CLI:

```bash
version=0.1.0
gh release create "v$version" \
  ".cache/release/Hae-$version-arm64.zip" \
  ".cache/release/Hae-$version-arm64.zip.sha256" \
  --draft \
  --title "Hæ? $version" \
  --notes-file docs/RELEASE_NOTES_0.1.0.md
```

Copy `.cache/release/hae.rb` to `Casks/hae.rb` in the Homebrew tap, validate it
with `brew audit --cask --strict hae`, and publish the tap change. Users can then
install with:

```bash
brew tap stianfro/tap
brew install --cask hae
```

## Release gates

Do not publish the draft until all of these are recorded:

- Both local microphone and system audio appear in a 60-second capture.
- Capture still works with the meeting or playback window minimized.
- Recovery and retry pass after terminating recording and finalization.
- The network-disabled workflow completes.
- `just ci`, `just smoke-model`, and `just notarize-release` pass.
- `spctl`, `codesign`, `stapler`, and the generated Cask all validate.
- The repository and release tag contain the root MIT license and bundled
  third-party notices.
