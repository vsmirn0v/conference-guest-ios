#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$tests_dir/../.." && pwd)"
framework_dir="${1:-$repo_dir/.build/native-webrtc-15003/release-r3/LiveKitWebRTC.xcframework/macos-arm64}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-system-audio-tests.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
    -F "$framework_dir" -framework LiveKitWebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
    "$repo_dir/MeetingEngine/Sources/MeetingEngine/Audio/GuestAudioProfile.swift" "$repo_dir/MeetingEngine/Sources/MeetingEngine/Audio/GuestAudioOwnerLease.swift" "$repo_dir/MeetingEngine/Sources/MeetingEngine/Providers/Guest/GuestSyntheticAudio.swift" \
    "$repo_dir/MeetingEngine/Sources/MeetingEngine/Providers/Guest/GuestSystemAudio.swift" "$repo_dir/MeetingEngine/Sources/MeetingEngine/Providers/Guest/NativeScreenEncoderQuality.swift" \
    "$repo_dir/MeetingEngine/Sources/MeetingEngine/Providers/Guest/GuestStartupAudio.swift" \
    "$repo_dir/ConferenceCore/Sources/ConferenceCore/ProbeLog.swift" \
    "$tests_dir/GuestSystemAudioTests.swift" \
    -o "$build_dir/system-audio-tests"
"$build_dir/system-audio-tests"
