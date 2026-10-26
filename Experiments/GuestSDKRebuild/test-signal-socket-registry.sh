#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$root/.build/guest-signal-registry-tests"
mkdir -p "$output"
env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcrun --sdk macosx clang -fobjc-arc -fmodules -framework Foundation \
  "$root/Experiments/GuestSDKRebuild/tests/signal-socket-registry-tests.m" -o "$output/tests"
"$output/tests"
