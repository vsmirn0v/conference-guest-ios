#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$tests_dir/../.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-acoustic-fd-tests.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -D DEBUG -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
    "$repo_dir/MeetingEngine/Sources/MeetingEngine/Providers/Guest/GuestAudioTestRecording.swift" "$repo_dir/MeetingEngine/Sources/MeetingEngine/Providers/Guest/GuestAudioTestFileBridge.swift" \
    "$tests_dir/AcousticFileBridgeTests.swift" -o "$build_dir/acoustic-file-bridge-tests"
"$build_dir/acoustic-file-bridge-tests"
