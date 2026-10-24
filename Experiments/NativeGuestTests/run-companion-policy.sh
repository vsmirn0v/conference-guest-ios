#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$tests_dir/../.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-guest-companion-policy.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
swiftc -swift-version 5 -parse-as-library \
    "$repo_dir/Shared/NativeGuestCompanionProtocol.swift" \
    "$repo_dir/NativeMacGuest/CompanionControlPolicy.swift" \
    "$tests_dir/CompanionControllerPolicyTests.swift" \
    -o "$build_dir/companion-policy-tests"
"$build_dir/companion-policy-tests"
