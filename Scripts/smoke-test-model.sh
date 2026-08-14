#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor="$root/Vendor/whisper.cpp"
cache="$root/.cache/model-smoke"
build="$cache/build"
model="$root/LocalModels/ggml-model-q5_0.bin"
vad_model="$root/LocalModels/ggml-silero-v6.2.0.bin"
expected_commit="306c88f4d1286aec1bf96e544632897886af5501"

"$root/Scripts/verify-models.sh"

if [[ "$(git -C "$vendor" rev-parse HEAD)" != "$expected_commit" ]]; then
    printf 'whisper.cpp is not pinned to v1.9.2 commit %s\n' "$expected_commit" >&2
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    printf 'cmake is required for the local model smoke test.\n' >&2
    exit 1
fi

generator=()
if command -v ninja >/dev/null 2>&1; then
    generator=(-G Ninja)
fi

mkdir -p "$cache"
cmake -S "$vendor" -B "$build" "${generator[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DGGML_METAL=OFF \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=Apple \
    -DGGML_NATIVE=OFF
cmake --build "$build" --target whisper-cli --parallel

fixture_wav="$vendor/samples/jfk.wav"
output_prefix="$cache/transcript"
module_directory="$cache/whisper-module"
swift_runner="$cache/WhisperBridgeSmoke.swift"
swift_smoke="$cache/whisper-bridge-smoke"
swift_module_cache="$cache/swift-module-cache"
rm -f "$output_prefix.txt"

"$build/bin/whisper-cli" \
    --model "$model" \
    --file "$fixture_wav" \
    --language en \
    --beam-size 5 \
    --no-gpu \
    --vad \
    --vad-model "$vad_model" \
    --vad-threshold 0.5 \
    --vad-min-speech-duration-ms 250 \
    --vad-min-silence-duration-ms 300 \
    --vad-max-speech-duration-s 28 \
    --vad-speech-pad-ms 200 \
    --vad-samples-overlap 0.1 \
    --output-txt \
    --output-file "$output_prefix"

if [[ ! -s "$output_prefix.txt" ]]; then
    printf 'The pinned model produced no transcript for the upstream fixture.\n' >&2
    exit 1
fi
if ! grep -Eiq 'country|americans|ask not' "$output_prefix.txt"; then
    printf 'The transcript did not contain an expected fixture key phrase.\n' >&2
    cat "$output_prefix.txt" >&2
    exit 1
fi

printf 'Pinned model and VAD smoke test passed. Transcript:\n'
cat "$output_prefix.txt"

mkdir -p "$module_directory" "$swift_module_cache"
cat > "$module_directory/module.modulemap" <<EOF
module whisper [system] {
    header "$vendor/include/whisper.h"
    export *
    link "whisper"
}
EOF

cat > "$swift_runner" <<'EOF'
import Foundation

enum WhisperBridgeSmokeError: Error {
  case invalidArguments
  case invalidWaveFile
  case emptyTranscript
}

@main
struct WhisperBridgeSmoke {
  static func main() async throws {
    guard CommandLine.arguments.count == 4 else {
      throw WhisperBridgeSmokeError.invalidArguments
    }
    let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let vadURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[3])
    let samples = try decodeWaveFile(at: fixtureURL)

    let engine = WhisperEngine()
    try await engine.loadModel(at: modelURL, vadModelURL: vadURL)
    let segments = try await engine.transcribe(samples: samples)
    guard !segments.isEmpty else { throw WhisperBridgeSmokeError.emptyTranscript }
    print(segments.map(\.text).joined(separator: "\n"))
  }

  private static func decodeWaveFile(at url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count >= 12,
      String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
      String(decoding: data[8..<12], as: UTF8.self) == "WAVE"
    else { throw WhisperBridgeSmokeError.invalidWaveFile }

    var offset = 12
    while offset + 8 <= data.count {
      let name = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
      let size = Int(littleEndianUInt32(data, at: offset + 4))
      let payloadStart = offset + 8
      let payloadEnd = payloadStart + size
      guard payloadEnd <= data.count else { throw WhisperBridgeSmokeError.invalidWaveFile }
      if name == "data" {
        return PCMFileReader.decodePCM16LE(data[payloadStart..<payloadEnd])
      }
      offset = payloadEnd + (size % 2)
    }
    throw WhisperBridgeSmokeError.invalidWaveFile
  }

  private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }
}
EOF

sdk="$(xcrun --show-sdk-path)"
sdk_interface="$(find "$sdk/usr/lib/swift/Swift.swiftmodule" \
    -name '*-apple-macos.swiftinterface' -print -quit)"
compiler_version="$(swiftc --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' | head -n 1)"
sdk_version=""
if [[ -n "$sdk_interface" ]]; then
    sdk_version="$(sed -n 's|// swift-compiler-version: Apple Swift version \([0-9.]*\).*|\1|p' "$sdk_interface" | head -n 1)"
fi
swift_compiler=("$(xcrun --find swiftc)")
if [[ -n "$sdk_version" && "$compiler_version" != "$sdk_version" ]]; then
    swift_compiler+=(-Xfrontend -interface-compiler-version -Xfrontend "$sdk_version")
fi

"${swift_compiler[@]}" \
    -parse-as-library \
    -swift-version 6 \
    -target arm64-apple-macos15.0 \
    -sdk "$sdk" \
    -module-cache-path "$swift_module_cache" \
    -I "$module_directory" \
    -Xcc -I"$vendor/ggml/include" \
    -L "$build/bin" \
    -lwhisper \
    -Xlinker -rpath \
    -Xlinker "$build/bin" \
    "$root/Hae/Core/Storage/Transcript.swift" \
    "$root/Hae/Core/Transcription/PCMFileReader.swift" \
    "$root/Hae/Core/Transcription/TranscriptDeduplicator.swift" \
    "$root/Hae/Core/Transcription/WhisperEngine.swift" \
    "$root/Hae/Core/Transcription/WhisperParameters.swift" \
    "$swift_runner" \
    -o "$swift_smoke"

"$swift_smoke" "$model" "$vad_model" "$fixture_wav"
printf 'Production Swift whisper.cpp bridge smoke test passed.\n'
