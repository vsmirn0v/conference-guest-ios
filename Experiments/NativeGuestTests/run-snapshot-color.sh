#!/bin/bash
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo 'usage: run-snapshot-color.sh FRAMEWORK_PARENT NEW_OUTPUT [PEER_SOURCE_NEGATIVE_CONTROL]' >&2
  exit 2
fi
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$tests_dir/../.." && pwd)"
framework_dir="$(cd -- "$1" && pwd)"
output="$2"
if [[ -e "$output" || -L "$output" ]]; then echo 'Output must be a new path' >&2; exit 2; fi
mkdir -p "$output"
output="$(cd -- "$output" && pwd)"
peer_source="${3:-$repo_dir/Experiments/NativeGuest/GuestPeer.swift}"
sources=()
for source in "$repo_dir"/Experiments/NativeGuest/*.swift; do
  name="$(basename -- "$source")"
  if [[ "$name" != Main.swift && "$name" != GuestPeer.swift ]]; then sources+=("$source"); fi
done
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -swift-version 5 -D DEBUG -parse-as-library -O -target arm64-apple-macos13.0 \
  -F "$framework_dir" -framework LiveKitWebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
  "$repo_dir/Shared/GuestAudioProfile.swift" "$repo_dir/Shared/GuestAudioOwnerLease.swift" "${sources[@]}" "$peer_source" "$repo_dir/RockNRoll/NativeVideoPixelBuffer.swift" \
  "$tests_dir/SnapshotColorTests.swift" -o "$output/snapshot-color-tests" >"$output/compile.log" 2>&1
"$output/snapshot-color-tests" "$output" >"$output/result.log" 2>&1
cat "$output/result.log"
