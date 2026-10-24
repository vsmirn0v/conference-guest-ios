#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$tests_dir/../.." && pwd)"
framework_dir="${1:-$repo_dir/.build/native-webrtc-15003/release-r3/LiveKitWebRTC.xcframework/macos-arm64}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-meeting-features.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
sources=()
for source in "$repo_dir"/Experiments/NativeGuest/*.swift; do
    if [[ "$(basename -- "$source")" != Main.swift ]]; then sources+=("$source"); fi
done
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -swift-version 5 -D DEBUG -parse-as-library -g -Onone -target arm64-apple-macos13.0 \
    -F "$framework_dir" -framework LiveKitWebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
    "$repo_dir/Shared/GuestAudioProfile.swift" "$repo_dir/Shared/GuestAudioOwnerLease.swift" "${sources[@]}" "$repo_dir/RockNRoll/NativeVideoPixelBuffer.swift" "$tests_dir/MeetingFeaturesTests.swift" -o "$build_dir/meeting-tests"
if "$build_dir/meeting-tests" >"$build_dir/results.log" 2>&1; then tail -n 1 "$build_dir/results.log"
else cat "$build_dir/results.log"; exit 1; fi
