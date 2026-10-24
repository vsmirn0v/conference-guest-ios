#!/bin/bash
set -euo pipefail

tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir="$(dirname -- "$tests_dir")/NativeGuest"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-guest-tests.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT

swiftc -swift-version 5 \
    "$source_dir/GuestBootstrap.swift" \
    "$source_dir/GuestTransport.swift" \
    "$tests_dir/BootstrapTests.swift" \
    -o "$build_dir/bootstrap-tests"
"$build_dir/bootstrap-tests"
