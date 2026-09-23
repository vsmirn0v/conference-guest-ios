#!/bin/bash
set -euo pipefail

packages_root="${BUILD_DIR}/../../SourcePackages/checkouts/jazz-ios-sdk/Sources"
app_resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
app_frameworks="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

if [[ ! -d "$packages_root" ]]; then
  echo "Jazz SDK package checkout is missing at $packages_root" >&2
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
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$spench_destination"
fi
