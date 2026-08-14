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

model_hash="$(shasum -a 256 "$app/Contents/Resources/Models/ggml-model-q5_0.bin" | awk '{print $1}')"
vad_hash="$(shasum -a 256 "$app/Contents/Resources/Models/ggml-silero-v6.2.0.bin" | awk '{print $1}')"
[[ "$model_hash" == "feb5951ae694a62cfeb81fb501f6cfa8cc50d96bcddb1e4e8215f7006bac23a2" ]]
[[ "$vad_hash" == "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987" ]]

identity="${HAE_CODESIGN_IDENTITY:--}"
signing_options=()
if [[ "$identity" != "-" ]]; then
    signing_options=(--options runtime)
fi
framework="$app/Contents/Frameworks/whisper.framework"
codesign --force "${signing_options[@]}" --sign "$identity" "$framework"
codesign --force "${signing_options[@]}" --entitlements "$root/Hae/Hae.entitlements" \
    --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

signed_entitlements="$output/signed-entitlements.plist"
codesign -d --entitlements :- "$app" > "$signed_entitlements" 2>/dev/null
plutil -lint "$signed_entitlements"
if grep -Eq 'com\.apple\.security\.network\.(client|server)' "$signed_entitlements"; then
    printf 'Release application contains a network entitlement.\n' >&2
    exit 1
fi
printf 'Packaged %s\n' "$app"
