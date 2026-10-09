#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="${1:?Pass the patched source directory}"
source_dir="$(cd "$source_dir" && pwd)"
prefix_patch="${2:-$source_dir/../apple_prefix.patch}"
source_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_sha"])' "$experiment_dir/build-lock.json")"
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$source_sha" ]] || { echo "Source revision mismatch" >&2; exit 1; }
verification_dir="$(mktemp -d /tmp/rock-hybrid-verify.XXXXXX)"
trap 'rm -rf "$verification_dir"' EXIT
# A separate index proves the cumulative patch state without altering source,
# the user's index or any branches. Existing dependency checkouts stay intact.
export GIT_INDEX_FILE="$verification_dir/index"
git -C "$source_dir" read-tree HEAD
git -C "$source_dir" apply --cached "$prefix_patch"
for patch in "$experiment_dir"/patches/0*.patch; do git -C "$source_dir" apply --cached "$patch"; done
git -C "$source_dir" diff --exit-code
