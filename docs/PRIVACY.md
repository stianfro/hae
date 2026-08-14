# Privacy

Hæ? processes audio and transcripts on the Mac. The application has no runtime
network code and no network client or server entitlement.

## Release rules

- No analytics, crash upload, cloud SDK, remote logger, authentication, or model
  download code is linked into the application.
- Model download and checksum validation happen only through local setup and
  packaging scripts.
- Logs contain state transitions, frame counts, inference timing, and errors.
  They never contain transcript text, audio samples, model tokens, meeting
  titles, or names inferred from speech.
- Audio is stored as append-only raw PCM before transcription starts.
- A transcription failure preserves the recording and manifest.

## Entitlements

The app sandbox includes audio input and user-selected file access. It does not
include `com.apple.security.network.client` or
`com.apple.security.network.server`. `Scripts/package-release.sh` signs the
packaged app with `Hae/Hae.entitlements` after verified models are copied into
the bundle. Packaging rechecks the bundled model hashes and rejects signed
entitlements containing network client or server access.

Deleting application files is not secure erasure on APFS or SSD media. FileVault
should be enabled when recordings need protection at rest.
