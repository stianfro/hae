#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
found=0
while IFS= read -r -d '' path; do
    yq eval '.' "$path" >/dev/null
    printf 'Validated %s\n' "${path#"$root/"}"
    found=1
done < <(find "$root" -path "$root/.cache" -prune -o -path "$root/Vendor" -prune -o \
    -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

if [[ "$found" -eq 0 ]]; then
    printf 'No YAML files found.\n'
fi
