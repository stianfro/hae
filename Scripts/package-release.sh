#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
models="$root/LocalModels"
output="$root/.cache/release"
identity="${HAE_CODESIGN_IDENTITY:--}"
notary_profile="${HAE_NOTARY_PROFILE:-}"
require_distribution="${HAE_REQUIRE_DISTRIBUTION:-0}"

if [[ "$require_distribution" == "1" ]]; then
    [[ "$identity" != "-" ]] || {
        printf 'HAE_CODESIGN_IDENTITY must name a Developer ID Application identity.\n' >&2
        exit 1
    }
    [[ -n "$notary_profile" ]] || {
        printf 'HAE_NOTARY_PROFILE must name a notarytool keychain profile.\n' >&2
        exit 1
    }
fi

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
ditto "$root/LICENSE" "$app/Contents/Resources/LICENSE.txt"

model_hash="$(shasum -a 256 "$app/Contents/Resources/Models/ggml-model-q5_0.bin" | awk '{print $1}')"
vad_hash="$(shasum -a 256 "$app/Contents/Resources/Models/ggml-silero-v6.2.0.bin" | awk '{print $1}')"
[[ "$model_hash" == "feb5951ae694a62cfeb81fb501f6cfa8cc50d96bcddb1e4e8215f7006bac23a2" ]]
[[ "$vad_hash" == "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987" ]]

signing_options=()
if [[ "$identity" != "-" ]]; then
    signing_options=(--options runtime --timestamp)
fi
framework="$app/Contents/Frameworks/whisper.framework"
framework_binary="$framework/Versions/A/whisper"
thin_framework="$output/whisper-arm64"
lipo -thin arm64 "$framework_binary" -output "$thin_framework"
mv "$thin_framework" "$framework_binary"
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
"$root/Scripts/verify-release.sh" "$app"

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
archive="$output/Hae-$version-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"

if [[ -n "$notary_profile" ]]; then
    [[ "$identity" != "-" ]] || {
        printf 'Notarization requires a Developer ID Application identity.\n' >&2
        exit 1
    }
    xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    codesign --verify --deep --strict "$app"
    spctl --assess --type execute --verbose=2 "$app"
    rm -f "$archive"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
fi

checksum="$(shasum -a 256 "$archive" | awk '{print $1}')"
archive_size="$(stat -f '%z' "$archive")"
[[ "$archive_size" -lt 2147483648 ]] || {
    printf 'Release archive exceeds the 2 GiB GitHub asset limit.\n' >&2
    exit 1
}
printf '%s  %s\n' "$checksum" "$(basename "$archive")" > "$archive.sha256"
printf 'Packaged %s\nArchive: %s\nSHA-256: %s\n' "$app" "$archive" "$checksum"
