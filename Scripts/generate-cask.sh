#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$root/.cache/release"
template="$root/Packaging/Casks/hae.rb.in"

archive="$(find "$output" -maxdepth 1 -type f -name 'Hae-*-arm64.zip' -print | sort | tail -n 1)"
[[ -n "$archive" ]] || {
    printf 'No release archive found. Run just package-release first.\n' >&2
    exit 1
}

version="$(basename "$archive")"
version="${version#Hae-}"
version="${version%-arm64.zip}"
checksum="$(shasum -a 256 "$archive" | awk '{print $1}')"
destination="$output/hae.rb"

sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$checksum/g" \
    "$template" > "$destination"
ruby -c "$destination"
printf 'Generated %s\n' "$destination"
