#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
framework_root="${1:?Pass the existing LiveKitWebRTC.xcframework path}"
output_dir="${2:-/tmp/trueconf-discovery}"
framework_dir="$framework_root/macos-arm64_x86_64"
mkdir -p "$output_dir"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -O \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macos12.0 \
  -F "$framework_dir" -framework LiveKitWebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
  "$experiment_dir/ServerBootstrap.swift" "$experiment_dir/ServerProbe.swift" \
  "$experiment_dir/../TelemostNative/MediaPeer.swift" \
  "$experiment_dir/../TelemostNative/SyntheticAudio.swift" \
  -o "$output_dir/TrueConfServerProbe"
