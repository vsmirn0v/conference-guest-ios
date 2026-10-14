#!/bin/bash
set -euo pipefail

search_dir="${BUILD_DIR}"
packages_root="${CONFERENCE_SDK_SOURCE_DIR:-$PROJECT_DIR/Dependencies/guest-sdk/VendorSources}"
if [[ ! -d "$packages_root" ]]; then packages_root=""; fi
while [[ -z "$packages_root" && "$search_dir" != / ]]; do
  candidate="$search_dir/SourcePackages/checkouts/jazz-ios-sdk/Sources"
  if [[ -d "$candidate" ]]; then
    packages_root="$candidate"
    break
  fi
  search_dir="$(dirname "$search_dir")"
done
app_resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
app_frameworks="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

if [[ -z "$packages_root" ]]; then
  echo "SDK package checkout is missing above $BUILD_DIR" >&2
  exit 1
fi

mkdir -p "$app_resources"
for bundle in DevicesDesignSystemResources JazzResources SDUIResources; do
  source_path="$packages_root/$bundle.bundle"
  if [[ ! -d "$source_path" ]]; then
    echo "Missing Jazz resource bundle: $source_path" >&2
    exit 1
  fi
  ditto "$source_path" "$app_resources/$bundle.bundle"
done

# JazzSDK 25.3.1020 dynamically loads Spench, but the vendor's Package.swift
# does not include it in the JazzSDK product. Supply the matching binary slice.
case "${PLATFORM_NAME}" in
  iphonesimulator) spench_slice="ios-arm64_x86_64-simulator" ;;
  iphoneos) spench_slice="ios-arm64" ;;
  *) echo "Unsupported Jazz SDK platform: ${PLATFORM_NAME}" >&2; exit 1 ;;
esac
spench_source="$packages_root/Spench.xcframework/$spench_slice/Spench.framework"
spench_destination="$app_frameworks/Spench.framework"
if [[ ! -d "$spench_source" ]]; then
  echo "Missing Jazz dependency: $spench_source" >&2
  exit 1
fi
mkdir -p "$app_frameworks"
ditto "$spench_source" "$spench_destination"
# The vendor archive marks its signature and binary read-only. Re-signing the
# copied framework needs write access in the build product (not the checkout).
chmod -R u+w "$spench_destination"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$spench_destination"
fi

# Fail closed if package resolution or embedding selected the original binary.
native_framework="$app_frameworks/WebRTC.framework"
native_binary="$native_framework/WebRTC"
[[ -f "$native_framework/GuestWebRTC-provenance.json" && -s "$native_framework/GuestWebRTC-notices.txt" ]] || {
  echo "Rebuilt guest WebRTC provenance/notices are missing" >&2; exit 1;
}
nm -gU "$native_binary" | awk '$NF == "_RTCSetConferencePlayoutReserved" { found=1 } END { exit !found }' || {
  echo "Rebuilt guest conference output API is missing" >&2; exit 1;
}
nm -gU "$native_binary" | awk '$NF == "_RTCConfigureScreenShareEncoderQuality" { quality=1 } $NF == "_RTCSetScreenShareSenderResolution" { sender=1 } END { exit !(quality && sender) }' || {
  echo "Rebuilt guest screen-detail APIs are missing" >&2; exit 1;
}
