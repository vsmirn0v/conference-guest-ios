#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
base_source="$(cd "${1:?Pass the existing qualified prefixed WebRTC source}" && pwd)"
scratch_dir="${2:?Pass a NEW scratch directory}"
[[ ! -e "$scratch_dir" ]] || { echo "Refusing to alter an existing workspace" >&2; exit 1; }
"$experiment_dir/../WebRTCHybrid/verify-source.sh" "$base_source"
mkdir -p "$scratch_dir"
# APFS copy-on-write retains dependency/toolchain state without modifying it.
cp -cR "$base_source" "$scratch_dir/src"
git -C "$scratch_dir/src" apply --reverse "$base_source/../apple_prefix.patch"
for patch in "$experiment_dir"/patches/0*.patch; do
    git -C "$scratch_dir/src" apply --check --whitespace=error-all "$patch"
    git -C "$scratch_dir/src" apply "$patch"
done
"$experiment_dir/verify-source.sh" "$scratch_dir/src"
