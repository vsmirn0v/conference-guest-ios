#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
workspace_dir="${1:?Pass a NEW scratch workspace directory}"
[[ ! -e "$workspace_dir" ]] || { echo "Refusing to alter an existing workspace" >&2; exit 1; }
mkdir -p "$workspace_dir/depot_tools"
git clone --depth 1 --revision ba469aa2093ba950066258ca0a59a6fbd1295582 \
  https://github.com/webrtc-sdk/webrtc.git "$workspace_dir/src"
curl -fL https://chromium.googlesource.com/chromium/tools/depot_tools/+archive/refs/heads/main.tar.gz \
  -o "$workspace_dir/depot-tools.tar.gz"
tar -xzf "$workspace_dir/depot-tools.tar.gz" -C "$workspace_dir/depot_tools"
export PATH="$workspace_dir/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0 DEPOT_TOOLS_METRICS=0
cat > "$workspace_dir/.gclient" <<'GCLIENT'
solutions = [{'name': 'src', 'url': 'https://github.com/webrtc-sdk/webrtc.git', 'managed': False, 'custom_deps': {}, 'custom_vars': {}}]
target_os = ['mac', 'ios']
GCLIENT
cd "$workspace_dir"
gclient sync --nohooks --no-history --jobs=4
curl -fL https://raw.githubusercontent.com/webrtc-sdk/webrtc-build/66ed9c7b07b2ad6ad624df0317e408dca562f91b/build/patches/apple_prefix.patch \
  -o "$workspace_dir/apple_prefix.patch"
git -C src apply --check "$workspace_dir/apple_prefix.patch"
git -C src apply "$workspace_dir/apple_prefix.patch"
for patch in "$experiment_dir"/patches/0*.patch; do
  git -C src apply --check --whitespace=error-all "$patch"
  git -C src apply "$patch"
done
