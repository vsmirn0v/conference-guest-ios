#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir="$(dirname -- "$tests_dir")/NativeGuest"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-guest-async-tests.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
swiftc -swift-version 5 -parse-as-library \
    "$source_dir/GuestTransport.swift" "$source_dir/GuestAsync.swift" "$tests_dir/AsyncTests.swift" \
    -o "$build_dir/async-tests"
"$build_dir/async-tests"
