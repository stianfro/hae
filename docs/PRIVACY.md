# Privacy

Hæ? transcribes on the Mac by default. Hosted transcription is opt-in through
Settings. Local mode does not send audio, transcripts, or model data over the
network. The app has no analytics or automatic model downloads.

## Hosted transcription

Selecting Hosted server and saving settings authorizes future recordings to
send their mixed audio to the configured HTTPS audio transcription endpoint
after recording stops. Choose a trusted provider and obtain permission from
everyone recorded. Hosted providers have their own processing and retention
policies; deleting local audio does not delete a provider's copy.

API keys are stored in macOS Keychain, scoped to the normalized endpoint URL,
and are not synchronized through iCloud Keychain by the app. Preferences and
session manifests store only the URL, model ID, language, and response format.
Credentials are never placed in transcript exports or logs. When changing
servers, keys are not copied to the new destination. Remove a saved key in
Transcription settings while that server's URL is selected.

Uploads use an ephemeral URLSession without cookie, credential, or response
caches. HTTPS is required and every redirect is rejected. Network failures
retain the local recording. Error messages use fixed descriptions and HTTP
status codes rather than displaying arbitrary server response bodies.

A session keeps the destination chosen when recording started. Retrying it uses
that destination and its current Keychain credential, even if new recordings
now use another provider. Old manifests without hosted configuration stay
local. Hæ? never silently falls back from local to hosted transcription.

## Local data and logs

- Model download and checksum validation happen only through local setup and
  packaging scripts.
- Logs contain state transitions, frame counts, inference timing, and errors.
  They must not contain transcript text, audio samples, API keys, or meeting
  titles.
- Audio is stored as append-only raw PCM before transcription starts.
- A transcription failure preserves the recording and manifest.
- Completion notifications are local and contain the user-visible session
  title. They can be disabled in Settings.
- Transcript export requires a user-selected destination.
- Audio retention applies only to completed local sessions, including sessions
  transcribed by a hosted server. Failed recordings remain available for retry.

## Entitlements

The sandbox includes audio input, user-selected file access, and the outbound
`com.apple.security.network.client` entitlement needed for optional hosted
transcription. It has no network server entitlement. Packaging verifies these
entitlements, model hashes, and signatures. Public distribution also requires
Developer ID signing, hardened runtime, notarization, and stapling.

Deleting files is not secure erasure on APFS or SSD media. FileVault should be
enabled when recordings need protection at rest.
