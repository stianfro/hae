#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
export CLANG_MODULE_CACHE_PATH="$root/.cache/xcode-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
xcodebuild -project "$root/Hae.xcodeproj" -scheme Hae -configuration Debug \
    -derivedDataPath "$root/.cache/xcode" \
    CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" CODE_SIGNING_ALLOWED=NO build
