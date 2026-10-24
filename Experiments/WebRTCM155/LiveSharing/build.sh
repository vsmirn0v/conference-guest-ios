#!/bin/bash
set -euo pipefail
experiment_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$experiment_dir/../../.." && pwd)"
framework_dir="$(cd -- "${1:?Pass native macOS framework parent directory}" && pwd)"
output="${2:?Pass distinct output binary path}"
sources=()
for source in "$repo_dir"/Experiments/NativeGuest/*.swift; do
  if [[ "$(basename -- "$source")" != Main.swift ]]; then sources+=("$source"); fi
done
mkdir -p "$(dirname -- "$output")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -swift-version 5 -D DEBUG -parse-as-library -O \
  -target arm64-apple-macos14.2 -F "$framework_dir" -framework LiveKitWebRTC \
  -Xlinker -rpath -Xlinker "$framework_dir" \
  "${sources[@]}" "$repo_dir/RockNRoll/NativeVideoPixelBuffer.swift" \
  "$repo_dir/RockNRoll/PresenterCompositor.swift" \
  "$repo_dir/RockNRoll/H264InputColorSignalling.swift" \
  "$repo_dir/RockNRoll/VendorIntegration/H264ColorSignalling.swift" \
  "$experiment_dir/PixelAcceptance.swift" "$experiment_dir/LiveSharing.swift" -o "$output"
