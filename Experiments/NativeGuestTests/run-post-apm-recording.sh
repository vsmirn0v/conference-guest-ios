#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$tests_dir/../.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-post-apm-tests.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -D DEBUG -swift-version 5 -warnings-as-errors -parse-as-library -target arm64-apple-macos13.0 \
    "$repo_dir/Experiments/NativeGuest/GuestPostAPMTestRecording.swift" "$tests_dir/PostAPMRecordingTests.swift" \
    -o "$build_dir/post-apm-recording-tests"
"$build_dir/post-apm-recording-tests"
