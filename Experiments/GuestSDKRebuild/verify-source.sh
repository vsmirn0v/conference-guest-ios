#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="$(cd "${1:?Pass the rebuilt WebRTC source directory}" && pwd)"
source_sha=0385653a83f21acf3c916466d4088b29fe2f160b
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$source_sha" ]] || { echo "Source revision mismatch" >&2; exit 1; }
verification_dir="$(mktemp -d /tmp/rock-guest-verify.XXXXXX)"
trap 'rmdir "$verification_dir" 2>/dev/null || true' EXIT
export GIT_INDEX_FILE="$verification_dir/index"
git -C "$source_dir" read-tree HEAD
# The guest framework uses unprefixed public Objective-C names. The native
# fallback decoder changes still match the app's separately prefixed framework.
for patch in "$experiment_dir"/../WebRTCHybrid/patches/0*.patch "$experiment_dir"/patches/0*.patch; do
    git -C "$source_dir" apply --cached --whitespace=error-all "$patch"
done
git -C "$source_dir" diff --exit-code
python3 - "$verification_dir" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); (root/'index').unlink(missing_ok=True)
PY
