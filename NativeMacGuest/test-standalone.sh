#!/bin/bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(dirname -- "$source_dir")"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-guest-entry.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
framework_dir="${NATIVE_GUEST_TEST_FRAMEWORK:-$repo_dir/.build/native-guest/duplex-framework-r1/LiveKitWebRTC.xcframework/macos-arm64}"
sources=()
for file in "$repo_dir"/Experiments/NativeGuest/*.swift "$source_dir"/*.swift; do
    case "$file" in */Main.swift|*/App.swift) continue ;; esac
    sources+=("$file")
done
swiftc -swift-version 5 -DDEBUG -parse-as-library \
    -F "$framework_dir" -framework LiveKitWebRTC \
    -framework AppKit -framework AVFoundation -framework MetalKit -framework CoreVideo \
    "${sources[@]}" "$repo_dir/Shared/NativeGuestCompanionProtocol.swift" \
    "$repo_dir/RockNRoll/NativeVideoPixelBuffer.swift" \
    "$source_dir/Tests/StandaloneEntryTests.swift" \
    -o "$build_dir/standalone-entry-tests"
DYLD_FRAMEWORK_PATH="$framework_dir" "$build_dir/standalone-entry-tests"
