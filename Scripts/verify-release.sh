#!/usr/bin/env bash
set -euo pipefail

app="${1:?Usage: verify-release.sh APP_PATH}"
[[ -d "$app" ]]

executable="$app/Contents/MacOS/Hae"
framework="$app/Contents/Frameworks/whisper.framework"
framework_binary="$framework/Versions/A/whisper"
resources="$app/Contents/Resources"
entitlements="$(mktemp)"
trap 'rm -f "$entitlements"' EXIT

[[ "$(lipo -archs "$executable")" == "arm64" ]]
[[ "$(lipo -archs "$framework_binary")" == "arm64" ]]
[[ "$(plutil -extract LSUIElement raw "$app/Contents/Info.plist")" == "true" ]]
[[ "$(plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist")" == "15.0" ]]
[[ -f "$resources/LICENSE.txt" ]]
[[ -f "$resources/ThirdPartyNotices.md" ]]
[[ -f "$resources/Assets.car" ]]
grep -Fq 'Apache License' "$resources/ThirdPartyNotices.md"
grep -Fq 'National Library of Norway' "$resources/ThirdPartyNotices.md"
grep -Fq 'Copyright (c) 2020-present Silero Team' "$resources/ThirdPartyNotices.md"

codesign -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$entitlements")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$entitlements")" == "true" ]]
if grep -Eq 'com\.apple\.security\.network\.(client|server)' "$entitlements"; then
    printf 'Release application contains a network entitlement.\n' >&2
    exit 1
fi

unexpected_frameworks="$(find "$app/Contents/Frameworks" -mindepth 1 -maxdepth 1 \
    -type d ! -name 'whisper.framework' -print)"
[[ -z "$unexpected_frameworks" ]]

if otool -L "$executable" | grep -Eqi 'Sentry|Firebase|Crashlytics|Analytics'; then
    printf 'Release executable links a forbidden telemetry framework.\n' >&2
    exit 1
fi

codesign --verify --deep --strict "$app"
printf 'Validated release application %s\n' "$app"
