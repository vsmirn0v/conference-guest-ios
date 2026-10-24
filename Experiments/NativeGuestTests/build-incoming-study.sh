#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$tests_dir/../.." && pwd)"
framework_dir="${1:?Pass native macOS framework slice}"
output="${2:?Pass output binary path}"
sources=()
for source in "$repo_dir"/Experiments/NativeGuest/*.swift; do
    if [[ "$(basename -- "$source")" != Main.swift ]]; then sources+=("$source"); fi
done
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -swift-version 5 -D DEBUG -parse-as-library -O -target arm64-apple-macos13.0 \
    -F "$framework_dir" -framework LiveKitWebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
    "$repo_dir/Shared/GuestAudioProfile.swift" "$repo_dir/Shared/GuestAudioOwnerLease.swift" "${sources[@]}" "$repo_dir/NativeMacGuest/VideoTile.swift" "$repo_dir/RockNRoll/NativeVideoPixelBuffer.swift" \
    "$tests_dir/IncomingVideoStudy.swift" -o "$output"
