#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor="$root/Vendor/whisper.cpp"
expected_commit="306c88f4d1286aec1bf96e544632897886af5501"
destination="$root/Frameworks/whisper.xcframework"

if [[ "$(git -C "$vendor" rev-parse HEAD)" != "$expected_commit" ]]; then
    printf 'whisper.cpp is not pinned to v1.9.2 commit %s\n' "$expected_commit" >&2
    exit 1
fi
if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    printf 'Full Xcode is required to build whisper.xcframework.\n' >&2
    exit 1
fi

(
    cd "$vendor"
    BUILD_STATIC_XCFRAMEWORK=OFF ./build-xcframework.sh
)

source_framework="$vendor/build-apple/whisper.xcframework"
[[ -d "$source_framework" ]] || { printf 'Upstream XCFramework build did not produce output.\n' >&2; exit 1; }
rm -rf "$destination"
ditto "$source_framework" "$destination"

mac_binary="$(find "$destination" -path '*macos*/whisper.framework/Versions/A/whisper' -type f -print -quit)"
[[ -n "$mac_binary" ]] || { printf 'No macOS whisper framework slice was found.\n' >&2; exit 1; }
if ! lipo -archs "$mac_binary" | tr ' ' '\n' | grep -qx arm64; then
    printf 'The macOS whisper framework does not contain arm64.\n' >&2
    exit 1
fi
if ! grep -q 'GGML_METAL=ON' "$vendor/build-xcframework.sh"; then
    printf 'The pinned upstream build no longer enables Metal.\n' >&2
    exit 1
fi

cat > "$root/Hae/Resources/WhisperBuild.json" <<EOF
{
  "version": "v1.9.2",
  "commit": "$expected_commit",
  "metal": true
}
EOF
printf 'Installed %s\n' "$destination"
