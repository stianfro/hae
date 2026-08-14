#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
model_dir="${HAE_MODEL_DIRECTORY:-$root/LocalModels}"
model_sha="feb5951ae694a62cfeb81fb501f6cfa8cc50d96bcddb1e4e8215f7006bac23a2"
vad_sha="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

verify() {
    local expected="$1"
    local path="$2"
    if [[ ! -f "$path" ]]; then
        printf 'Missing model file: %s\n' "$path" >&2
        exit 1
    fi
    local actual
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        printf 'SHA-256 mismatch for %s\nExpected: %s\nActual:   %s\n' \
            "$path" "$expected" "$actual" >&2
        exit 1
    fi
    printf 'Verified %s\n' "$(basename "$path")"
}

verify "$model_sha" "$model_dir/ggml-model-q5_0.bin"
verify "$vad_sha" "$model_dir/ggml-silero-v6.2.0.bin"
