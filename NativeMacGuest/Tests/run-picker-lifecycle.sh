#!/bin/bash
set -euo pipefail
test_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$test_dir/../.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-picker-lifecycle.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx clang -fobjc-arc -fblocks -DDEBUG=1 -target arm64-apple-macos13.0 \
    -I "$repo_dir/RockNRoll" -framework Foundation -framework AppKit -framework CoreMedia -framework CoreGraphics -framework CoreVideo \
    "$repo_dir/RockNRoll/MacScreenCaptureBridge.m" "$test_dir/PickerLifecycleTests.m" -o "$build_dir/picker-tests"
"$build_dir/picker-tests"
