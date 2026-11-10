#!/bin/bash
set -euo pipefail
test_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$test_dir/../.." && pwd)"
source_file="${STARTUP_TRANSPORT_SOURCE:-$repo_dir/NativeMacGuest/StartupTransportReadiness.swift}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/startup-transport-tests.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
# Only Swift and Foundation are needed; no native media SDK or app build.
"${SWIFTC:-swiftc}" -swift-version 5 -D DEBUG -parse-as-library \
    -module-cache-path "$build_dir/module-cache" \
    "$source_file" "$test_dir/StartupTransportReadinessTests.swift" \
    -o "$build_dir/startup-transport-tests"
"$build_dir/startup-transport-tests" "$@"
