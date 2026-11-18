#!/bin/bash
set -euo pipefail
tests_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$tests_dir/../.." && pwd)"
source_dir="$repo_dir/MeetingEngine/Sources/MeetingEngine/Providers/Guest"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-guest-session-tests.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
swiftc -swift-version 5 -DDEBUG -parse-as-library \
    "$source_dir/GuestBootstrap.swift" \
    "$source_dir/GuestTransport.swift" \
    "$repo_dir/ConferenceCore/Sources/ConferenceCore/ProbeLog.swift" \
    "$source_dir/GuestSession.swift" \
    "$tests_dir/SessionTests.swift" \
    -o "$build_dir/session-tests"
"$build_dir/session-tests"
