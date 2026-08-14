#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
model_dir="$root/LocalModels"
model_url="https://huggingface.co/NbAiLab/nb-whisper-large/resolve/main/ggml-model-q5_0.bin"
vad_url="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"

mkdir -p "$model_dir"

download() {
    local url="$1"
    local destination="$2"
    local temporary="${destination}.part"

    if [[ -f "$destination" ]]; then
        printf 'Already present: %s\n' "$(basename "$destination")"
        return
    fi
    curl --fail --location --retry 3 --output "$temporary" "$url"
    mv "$temporary" "$destination"
}

download "$model_url" "$model_dir/ggml-model-q5_0.bin"
download "$vad_url" "$model_dir/ggml-silero-v6.2.0.bin"
"$root/Scripts/verify-models.sh"
