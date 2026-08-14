#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-test}"
scratch="$root/.cache/swiftpm"
module_cache="$root/.cache/clang"
local_home="$root/.cache/home"
mkdir -p "$scratch" "$module_cache" "$local_home"

export CLANG_MODULE_CACHE_PATH="$module_cache"
export CFFIXED_USER_HOME="$local_home"
export HOME="$local_home"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"

sdk="$(xcrun --show-sdk-path)"
sdk_interface="$sdk/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
compiler_version="$(swiftc --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' | head -n 1)"
sdk_version="$(sed -n 's|// swift-compiler-version: Apple Swift version \([0-9.]*\).*|\1|p' "$sdk_interface" | head -n 1)"

if [[ -n "$sdk_version" && "$compiler_version" != "$sdk_version" ]]; then
    wrapper="$root/.cache/swiftc-wrapper"
    cat > "$wrapper" <<EOF
#!/bin/sh
exec "$(xcrun --find swiftc)" -Xfrontend -interface-compiler-version -Xfrontend "$sdk_version" "\$@"
EOF
    chmod +x "$wrapper"
    export SWIFT_EXEC="$wrapper"
fi

common=(--disable-sandbox --scratch-path "$scratch")
if [[ "$mode" == "build" ]]; then
    swift build "${common[@]}" --target HaeApplication
    exit
fi
if [[ "$mode" != "test" ]]; then
    printf 'Unknown Swift task: %s\n' "$mode" >&2
    exit 1
fi

developer_root="$(xcode-select -p)"
developer_frameworks="$developer_root/Library/Developer/Frameworks"
if [[ ! -d "$developer_frameworks/Testing.framework" ]]; then
    swift test "${common[@]}"
    exit
fi

testing_plugin="$developer_root/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
testing_interop="$developer_root/Library/Developer/usr/lib"
swift test "${common[@]}" \
    -Xswiftc -F -Xswiftc "$developer_frameworks" \
    -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin" \
    -Xlinker "-F$developer_frameworks" \
    -Xlinker -rpath -Xlinker "$developer_frameworks" \
    -Xlinker -rpath -Xlinker "$testing_interop"
