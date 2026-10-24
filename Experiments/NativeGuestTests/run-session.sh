#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir="$(dirname -- "$tests_dir")/NativeGuest"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-guest-session-tests.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
swiftc -swift-version 5 -DDEBUG -parse-as-library \
    "$source_dir/GuestBootstrap.swift" \
    "$source_dir/GuestTransport.swift" \
    "$source_dir/ProbeLog.swift" \
    "$source_dir/GuestSession.swift" \
    "$tests_dir/SessionTests.swift" \
    -o "$build_dir/session-tests"
"$build_dir/session-tests"
