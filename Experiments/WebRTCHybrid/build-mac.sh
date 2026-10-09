#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="${1:?Pass the dependency-synced, pinned WebRTC source directory}"
output_dir="${2:-out/rock-hybrid-mac}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
"$experiment_dir/verify-source.sh" "$source_dir"
cd "$source_dir"
# Apply patches separately after reviewing local changes. This command only
# builds: it never resets source, downloads dependencies or changes branches.
buildtools/mac/gn gen "$output_dir" --args='target_os="mac" target_cpu="arm64" is_debug=false symbol_level=0 enable_dsyms=false is_component_build=false rtc_include_tests=true rtc_build_examples=false rtc_enable_symbol_export=true rtc_enable_protobuf=false rtc_libvpx_build_vp9=true rtc_use_h264=false enable_libaom=true rtc_include_dav1d_in_internal_decoder_factory=true enable_stripping=true treat_warnings_as_errors=true use_rtti=true mac_deployment_target="10.15" use_remoteexec=false'
third_party/ninja/ninja -C "$output_dir" -j"${ROCK_BUILD_JOBS:-4}" vp9_hybrid_unittests mac_framework_bundle
python3 "$experiment_dir/make-native-fixture.py" "$experiment_dir/../../RockNRollTests/Fixtures/vp9-svc.json" "$output_dir/vp9-svc.bin"
WEBRTC_VP9_SVC_FIXTURE="$output_dir/vp9-svc.bin" "$output_dir/vp9_hybrid_unittests"
