#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
framework_root="${1:?Pass the existing LiveKitWebRTC.xcframework path}"
output_dir="${2:-$experiment_dir/../../.build/native-guest}"
framework_dir="$(python3 "$experiment_dir/../xcframework-slice.py" "$framework_root" macos "" arm64)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$output_dir"
xcrun --sdk macosx swiftc -swift-version 5 -D DEBUG -parse-as-library -O \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macos13.0 \
  -F "$framework_dir" -framework LiveKitWebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
  "$experiment_dir/../../Shared/GuestAudioProfile.swift" "$experiment_dir/../../Shared/GuestAudioOwnerLease.swift" "$experiment_dir"/*.swift "$experiment_dir/../../RockNRoll/NativeVideoPixelBuffer.swift" \
  -o "$output_dir/NativeGuestProbe"
