#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="$(cd "${1:?Pass the isolated patched source}" && pwd)"
environment="${2:-device}"
case "$environment" in device|simulator) ;; *) echo "Expected device or simulator" >&2; exit 1 ;; esac
output_dir="${3:-out/rock-hybrid-ios-$environment}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
"$experiment_dir/verify-source.sh" "$source_dir"
cd "$source_dir"
# LLVM strip misaligns LINKEDIT under this Xcode; the unstripped Apple-linked
# framework is accepted by the application linker on device and simulator.
buildtools/mac/gn gen "$output_dir" --args="target_os=\"ios\" target_environment=\"$environment\" target_cpu=\"arm64\" is_debug=false symbol_level=0 enable_dsyms=false is_component_build=false rtc_include_tests=false rtc_build_examples=false rtc_enable_symbol_export=true rtc_enable_protobuf=false rtc_libvpx_build_vp9=true rtc_use_h264=false enable_libaom=true rtc_include_dav1d_in_internal_decoder_factory=true enable_stripping=false treat_warnings_as_errors=true use_rtti=true ios_enable_code_signing=false ios_deployment_target=\"13.0\" use_remoteexec=false use_lld=false"
third_party/ninja/ninja -C "$output_dir" -j"${ROCK_BUILD_JOBS:-4}" ios_framework_bundle
