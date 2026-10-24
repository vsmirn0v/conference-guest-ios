#!/bin/bash
set -euo pipefail
framework="${1:?Pass the macOS WebRTC.framework or LiveKitWebRTC.framework path}"
output="${2:?Pass a separate probe output directory}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
module="$(basename "$framework" .framework)"
framework_dir="$(cd "$(dirname "$framework")" && pwd)"
case "$module" in
  WebRTC) livekit=0 ;;
  LiveKitWebRTC) livekit=1 ;;
  *) exit 2 ;;
esac
mkdir -p "$output"
output="$(cd "$output" && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$output/ModuleCache" \
  -mmacosx-version-min=13.0 -DPROBE_LIVEKIT="$livekit" \
  -F "$framework_dir" -framework "$module" \
  -framework Foundation -framework AppKit -framework Metal -framework MetalKit \
  -framework QuartzCore -framework CoreVideo \
  -Xlinker -rpath -Xlinker "$framework_dir" \
  "$script_dir/MetalViewProbe.m" -o "$output/MetalViewProbe" \
  > "$output/compile.log" 2>&1
shasum -a 256 "$framework_dir/$module.framework/$module" > "$output/framework.sha256"
"$output/MetalViewProbe" > "$output/result.json" 2> "$output/runtime.log"
cat "$output/result.json"
