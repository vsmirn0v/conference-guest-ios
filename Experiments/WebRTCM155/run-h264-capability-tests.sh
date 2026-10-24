#!/bin/bash
set -euo pipefail
if [[ $# != 2 && $# != 4 ]]; then
  echo 'usage: run-h264-capability-tests.sh SOURCE NEW_OUTPUT [FRAMEWORK_BINARY guest|prefixed]' >&2
  exit 2
fi
source_root="$(cd "$1" && pwd)"
output="$2"
if [[ -e "$output" || -L "$output" ]]; then
  echo 'Output must be a new path' >&2
  exit 2
fi
mkdir -p "$output"
output="$(cd "$output" && pwd)"
experiment="$(cd "$(dirname "$0")" && pwd)"
xcrun --sdk macosx clang++ -std=c++20 -fobjc-arc -fblocks -mmacosx-version-min=13.0 \
  -DWEBRTC_MAC -DWEBRTC_POSIX -I"$source_root" -I"$source_root/third_party/abseil-cpp" \
  -framework Foundation -framework VideoToolbox -framework CoreMedia \
  "$experiment/H264CapabilityTests.mm" -o "$output/H264CapabilityTests" \
  >"$output/compile.log" 2>&1
if [[ $# == 4 ]]; then
  "$output/H264CapabilityTests" "$3" "$4" >"$output/result.log" 2>&1
else
  "$output/H264CapabilityTests" >"$output/result.log" 2>&1
fi
cat "$output/result.log"
