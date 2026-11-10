#!/usr/bin/env bash
set -euo pipefail

RENEWAL_TEST_ROOT=$(cd "$(dirname "$0")/.." && pwd)
RENEWAL_TEST_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/guest-stopped-renewal.XXXXXX")
trap 'rm -rf "$RENEWAL_TEST_SCRATCH"' EXIT

python3 - "$RENEWAL_TEST_ROOT" "$RENEWAL_TEST_SCRATCH" <<'PY'
import hashlib
import os
from pathlib import Path
import sys

root, scratch = map(Path, sys.argv[1:])
source = (root/'NativeGuest/GuestSystemAudio.swift').read_text()
fixture = (root/'NativeGuestTests/StoppedInputRenewalTests.swift').read_text()
headset_path = Path(os.environ.get('RENEWAL_TEST_HEADSET_SOURCE', root.parent/'NativeMacGuest/DesktopHeadsetMute.swift'))
headset_source = headset_path.read_text()
headset = headset_source[headset_source.index('@MainActor final class NativeDesktopHeadsetMute'):]
def scope(text, marker):
    start = text.index(marker); opening = text.index('{', start); depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{': depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0: return text[start:index+1]
    raise AssertionError(marker)
live = scope(headset, 'static func live()')
headset = headset.replace(live, 'static func live() -> Self { fatalError("Memory tests must inject Platform") }', 1)
assert 'LKRTC' not in headset and 'AVAudioApplication.' not in headset
begin = '// BEGIN VPIO RENEWAL COORDINATOR\n'
end = '// END VPIO RENEWAL COORDINATOR'
assert source.count(begin) == source.count(end) == 1, 'production coordinator markers must be unique'
body = source.split(begin, 1)[1].split(end, 1)[0]
assert 'final class GuestStoppedInputRenewal' in body
combined = 'import Foundation\nimport Darwin\n\n' + body + '\n' + headset + '\n' + fixture
(scratch/'StoppedInputRenewalTests.swift').write_text(combined)
print('Production coordinator SHA256:', hashlib.sha256(body.encode()).hexdigest())
print('Test fixture SHA256:', hashlib.sha256(fixture.encode()).hexdigest())
print('Headset source SHA256:', hashlib.sha256(headset_source.encode()).hexdigest())
print('Compiled source SHA256:', hashlib.sha256(combined.encode()).hexdigest())
PY

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$RENEWAL_TEST_SCRATCH/module-cache" \
    "$RENEWAL_TEST_SCRATCH/StoppedInputRenewalTests.swift" \
    -o "$RENEWAL_TEST_SCRATCH/stopped-input-renewal-tests"
"$RENEWAL_TEST_SCRATCH/stopped-input-renewal-tests"
