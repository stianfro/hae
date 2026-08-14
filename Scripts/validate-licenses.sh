#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
license="$root/LICENSE"
notices="$root/Hae/Resources/ThirdPartyNotices.md"
review="$root/docs/LICENSING.md"

grep -Fq 'MIT License' "$license"
grep -Fq 'Copyright (c) 2026 Stian Frøystein' "$license"
grep -Fq 'Copyright (c) 2023-2026 The ggml authors' "$notices"
grep -Fq 'Apache License' "$notices"
grep -Fq 'Version 2.0, January 2004' "$notices"
grep -Fq 'National Library of Norway' "$notices"
grep -Fq 'https://huggingface.co/NbAiLab/nb-whisper-large' "$notices"
grep -Fq 'Copyright (c) 2020-present Silero Team' "$notices"
grep -Fq 'No published license blocks distributing' "$review"
grep -Fq 'not legal advice' "$review"

printf 'Validated application and third-party license texts.\n'
