#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir="$(dirname -- "$tests_dir")/NativeGuest"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-guest-timeline-tests.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
swiftc -swift-version 5 -parse-as-library "$source_dir/GuestFrameTimeline.swift" \
    "$tests_dir/FrameTimelineTests.swift" -o "$build_dir/timeline-tests"
"$build_dir/timeline-tests"
