# Licensing review

This review covers the files included in the Hæ? release application. It is a
technical license inventory, not legal advice.

## Result

No published license blocks distributing the application through a GitHub
Release or a Homebrew Cask. A Cask is an installer definition and does not
change the licenses of the application, runtime, or model.

The release must keep the notices listed below. `just lint` validates that the
required license text and attributions remain present, and `just
verify-release` checks that they are bundled in the application.

## Application

Hæ? source code is distributed under the root MIT License. Release archives
include that license as `Hae.app/Contents/Resources/LICENSE.txt`.

## whisper.cpp

The application embeds whisper.cpp v1.9.2 at commit
`306c88f4d1286aec1bf96e544632897886af5501`. Upstream publishes that version
under the MIT License. The complete upstream copyright and permission notice is
included in `Hae/Resources/ThirdPartyNotices.md` and in the application bundle.

Source: https://github.com/ggml-org/whisper.cpp/blob/v1.9.2/LICENSE

## NB-Whisper Large Q5 model

The application bundles `ggml-model-q5_0.bin` from
`NbAiLab/nb-whisper-large`. The model repository marks the model as Apache-2.0,
provides the exact GGML Q5 file, and identifies the National Library of Norway
as the model owner. The complete Apache License 2.0 text, model identity, owner,
and source are included in the third-party notices.

The model card notes that Norwegian attribution rules may apply where relevant
and encourages attribution of generated subtitles. The bundled notice credits
NB-Whisper Large and the National Library of Norway. Product documentation and
release notes must not imply endorsement by the National Library of Norway.

Source: https://huggingface.co/NbAiLab/nb-whisper-large

## Silero VAD model

The application bundles `ggml-silero-v6.2.0.bin` from
`ggml-org/whisper-vad`, originating from `snakers4/silero-vad`. The model
repository and upstream project publish it under the MIT License. The complete
upstream copyright and permission notice is included in the third-party
notices.

Sources:

- https://huggingface.co/ggml-org/whisper-vad
- https://github.com/snakers4/silero-vad/blob/master/LICENSE

## Apple frameworks and Homebrew

The binary links only the embedded whisper framework and macOS system
frameworks. The release does not redistribute Xcode, macOS frameworks, or
Homebrew. Homebrew downloads the same signed release ZIP published on GitHub.

## Release checklist

- Keep the root MIT License in the repository and release bundle.
- Keep `ThirdPartyNotices.md` in the release bundle.
- Keep the model names, owners, source repositories, and full license texts.
- Publish only model files that match the pinned SHA-256 hashes.
- Do not present Hæ? as endorsed by the model or runtime authors.
- Recheck licenses before changing the model, VAD file, or embedded runtime.
