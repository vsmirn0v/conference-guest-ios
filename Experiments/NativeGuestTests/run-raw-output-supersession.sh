#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/raw-output-supersession.XXXXXX")"
trap 'rm -rf -- "$build"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun --sdk macosx swiftc -swift-version 5 -D DEBUG -warnings-as-errors -parse-as-library \
    "$root/NativeMacGuest/StartupRawOutputSupersession.swift" "$root/Experiments/NativeGuestTests/RawOutputSupersessionTests.swift" \
    -o "$build/tests"
"$build/tests" "$@"
