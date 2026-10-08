#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
platform="${1:?Pass macos or simulator}"
framework_root="${2:?Pass the existing LiveKitWebRTC.xcframework path}"
output_dir="${3:-/tmp/rock-telemost-native}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
case "$platform" in
  macos) sdk=macosx; slice=macos-arm64_x86_64; target=arm64-apple-macos12.0 ;;
  simulator) sdk=iphonesimulator; slice=ios-arm64_x86_64-simulator; target=arm64-apple-ios16.0-simulator ;;
  *) echo 'Unknown platform' >&2; exit 2 ;;
esac
mkdir -p "$output_dir"
framework_dir="$framework_root/$slice"
xcrun --sdk "$sdk" swiftc -swift-version 5 -parse-as-library -O \
  -sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" -target "$target" \
  -F "$framework_dir" -framework LiveKitWebRTC -Xlinker -rpath -Xlinker "$framework_dir" \
  "$experiment_dir/Bootstrap.swift" "$experiment_dir/MediaPeer.swift" \
  "$experiment_dir/SyntheticAudio.swift" "$experiment_dir/Probe.swift" \
  -o "$output_dir/TelemostProbe-$platform"
if [[ "$platform" == macos ]]; then
  xcrun swiftc -swift-version 5 -parse-as-library \
    "$experiment_dir/Bootstrap.swift" "$experiment_dir/ProtocolTests.swift" \
    -o "$output_dir/ProtocolTests"
  "$output_dir/ProtocolTests"
fi
