#!/bin/bash
# Builds and runs the VoxCPM2 port's parity checks against tensors dumped from the Python runtime.
#   run-voxcpm2.sh <bundle> <reference dir> cpu
#   run-voxcpm2.sh <bundle> <reference dir> engine [<sentences.json> <output dir>]
set -euo pipefail
test_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$test_dir/../.." && pwd)"
# A stable path: Core AI keys its compiled Neural Engine cache partly on the client, so a new
# path per run would recompile the model (tens of minutes) every time.
build_dir="$repo_dir/.build/voxcpm2-tests"
mkdir -p "$build_dir"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos13.0 \
    -Xlinker -weak_framework -Xlinker CoreAI \
    "$repo_dir"/NativeMacGuest/Attention/VoxCPM2/*.swift "$test_dir/VoxCPM2ParityTests.swift" -o "$build_dir/voxcpm2-tests"
"$build_dir/voxcpm2-tests" "$@"
