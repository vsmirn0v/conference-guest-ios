#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
framework_root="${1:?Pass the existing LiveKitWebRTC.xcframework path}"
output_dir="${2:-/tmp/rock-codec-factory-loopback}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
framework_dir="$framework_root/macos-arm64_x86_64"
mkdir -p "$output_dir"
xcrun --sdk macosx swiftc -swift-version 5 -D DEBUG -parse-as-library -O \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macos12.0 \
  -F "$framework_dir" -framework LiveKitWebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
  "$experiment_dir/../../RockNRoll/NativeRTC/VP9VideoFormat.swift" \
  "$experiment_dir/../../RockNRoll/NativeRTC/VideoToolboxVP9Session.swift" \
  "$experiment_dir/../../RockNRoll/NativeRTC/VP9HardwareDecoder.swift" \
  "$experiment_dir/../../RockNRoll/NativeRTC/NativeVideoDecoderFactory.swift" \
  "$experiment_dir/../../RockNRoll/NativeRTC/NativeVP9Hybrid.swift" \
  "$experiment_dir/../../RockNRoll/NativeRTC/DecoderFactoryOverride.swift" \
  "$experiment_dir/../TelemostNative/Bootstrap.swift" \
  "$experiment_dir/../TelemostNative/MediaPeer.swift" \
  "$experiment_dir/../TelemostNative/SyntheticAudio.swift" "$experiment_dir/Loopback.swift" \
  -o "$output_dir/loopback"
"$output_dir/loopback"
