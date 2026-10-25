#!/bin/bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-update-safety.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
swiftc -swift-version 5 -parse-as-library -D NATIVE_UPDATE_SAFETY_STANDALONE \
    "$source_dir/Updates/UpdateSafety.swift" "$source_dir/Tests/Parity/UpdateSafetyTests.swift" \
    -o "$build_dir/update-safety-tests"
"$build_dir/update-safety-tests"
