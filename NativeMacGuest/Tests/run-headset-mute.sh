#!/bin/bash
set -euo pipefail
test_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$test_dir/../.." && pwd)"
framework_dir="${NATIVE_HEADSET_FRAMEWORK:-$repo_dir/.build/webrtc-m156-desktop-audio/native-framework-r4/LiveKitWebRTC.xcframework/macos-arm64}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-desktop-headset.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -g -target arm64-apple-macos13.0 \
    -F "$framework_dir" -framework LiveKitWebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
    "$repo_dir/NativeMacGuest/DesktopHeadsetMute.swift" "$test_dir/DesktopHeadsetMuteTests.swift" -o "$build_dir/headset-tests"
"$build_dir/headset-tests" "$@"
