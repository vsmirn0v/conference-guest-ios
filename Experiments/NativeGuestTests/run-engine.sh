#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$tests_dir/../.." && pwd)"
framework_dir="${1:-$repo_dir/.build/native-webrtc-15003/release-r3/LiveKitWebRTC.xcframework/macos-arm64}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-guest-engine-tests.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
sources=()
for source in "$repo_dir"/MeetingEngine/Sources/MeetingEngine/Providers/Guest/*.swift; do
    case "$(basename -- "$source")" in
        GuestAdapter.swift|GuestFeatureServices.swift|VendorEndpointResolver.swift|AdditionalRootTrust.swift|GuestSiteLinkAdapter.swift) continue ;;
    esac
    sources+=("$source")
done
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -swift-version 5 -D DEBUG -parse-as-library -O -target arm64-apple-macos13.0 \
    -F "$framework_dir" -framework LiveKitWebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
    "$repo_dir/ConferenceCore/Sources/ConferenceCore/ProbeLog.swift" \
    "$repo_dir/MeetingEngine/Sources/MeetingEngine/Audio/GuestAudioProfile.swift" \
    "$repo_dir/MeetingEngine/Sources/MeetingEngine/Audio/GuestAudioOwnerLease.swift" \
    "$repo_dir/MeetingEngine/Sources/MeetingEngine/Audio/SyntheticVoiceReplyPlayer.swift" \
    "${sources[@]}" "$repo_dir/MeetingEngine/Sources/MeetingEngine/Media/NativeVideoPixelBuffer.swift" \
    "$tests_dir/EngineTests.swift" -o "$build_dir/engine-tests"
if "$build_dir/engine-tests" >"$build_dir/results.log" 2>&1; then
    tail -n 1 "$build_dir/results.log"
else
    cat "$build_dir/results.log"
    exit 1
fi
