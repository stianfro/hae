#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
models="$root/LocalModels"
output="$root/.cache/release"

"$root/Scripts/verify-models.sh"
[[ -d "$root/Frameworks/whisper.xcframework" ]] || "$root/Scripts/build-whisper-xcframework.sh"
if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

rm -rf "$output"
mkdir -p "$output"
xcodebuild -project "$root/Hae.xcodeproj" -scheme Hae -configuration Release \
    -derivedDataPath "$output/DerivedData" CODE_SIGNING_ALLOWED=NO build

app="$output/DerivedData/Build/Products/Release/Hae.app"
mkdir -p "$app/Contents/Resources/Models"
ditto "$models/ggml-model-q5_0.bin" "$app/Contents/Resources/Models/ggml-model-q5_0.bin"
ditto "$models/ggml-silero-v6.2.0.bin" "$app/Contents/Resources/Models/ggml-silero-v6.2.0.bin"

identity="${HAE_CODESIGN_IDENTITY:--}"
codesign --force --deep --options runtime --entitlements "$root/Hae/Hae.entitlements" \
    --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
printf 'Packaged %s\n' "$app"
