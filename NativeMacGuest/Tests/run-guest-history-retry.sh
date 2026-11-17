#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/guest-history-retry.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
swiftc -swift-version 5 -parse-as-library \
    "$tests_dir/../Engines/GuestHistoryRetry.swift" "$tests_dir/GuestHistoryRetryTests.swift" \
    -o "$build_dir/history-retry-tests"
"$build_dir/history-retry-tests"
