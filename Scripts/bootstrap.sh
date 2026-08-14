#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_commit="306c88f4d1286aec1bf96e544632897886af5501"

for tool in gh git cmake pkg-config just yq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Required tool is missing: %s\n' "$tool" >&2
        exit 1
    fi
done

if [[ ! -e "$root/Vendor/whisper.cpp/.git" ]]; then
    mkdir -p "$root/Vendor"
    gh repo clone ggml-org/whisper.cpp "$root/Vendor/whisper.cpp" -- \
        --branch v1.9.2 --single-branch
fi

git -C "$root" submodule init
git -C "$root" submodule absorbgitdirs Vendor/whisper.cpp

actual_commit="$(git -C "$root/Vendor/whisper.cpp" rev-parse HEAD)"
if [[ "$actual_commit" != "$expected_commit" ]]; then
    printf 'whisper.cpp is at %s, expected %s\n' "$actual_commit" "$expected_commit" >&2
    exit 1
fi

printf 'Bootstrap checks passed.\n'
