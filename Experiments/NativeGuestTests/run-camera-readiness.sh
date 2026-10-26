#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$tests_dir/../.." && pwd)"
framework_dir="${1:-$repo_dir/.build/webrtc-m156-desktop-audio/native-framework-r4/LiveKitWebRTC.xcframework/macos-arm64}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-camera-readiness-tests.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -D DEBUG -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
    -F "$framework_dir" -framework LiveKitWebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
    "$repo_dir/Experiments/NativeGuest/GuestCamera.swift" "$tests_dir/CameraReadinessTests.swift" \
    -o "$build_dir/camera-readiness-tests"
"$build_dir/camera-readiness-tests"
