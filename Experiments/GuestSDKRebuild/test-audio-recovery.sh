#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="$(cd "${1:?Pass the patched native source}" && pwd)"
"$experiment_dir/verify-source.sh" "$source_dir"
output_dir="$(mktemp -d /tmp/rock-audio-recovery.XXXXXX)"
trap 'rm -rf "$output_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
for name in audio-recovery-tests conference-audio-ownership-tests; do
  xcrun clang++ -std=c++20 -Wall -Wextra -Werror -pthread -I "$source_dir" \
    -fsanitize=address,undefined "$experiment_dir/tests/$name.cc" \
    -o "$output_dir/$name"
  "$output_dir/$name"
done
