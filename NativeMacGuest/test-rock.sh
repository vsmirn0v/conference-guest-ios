#!/bin/bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(dirname -- "$source_dir")"
framework_root="${NATIVE_GUEST_FRAMEWORK_ROOT:-$repo_dir/.build/webrtc-m156-desktop-audio/native-framework-r4}"
dependency_root="${NATIVE_GUEST_LIVEKIT_DEPENDENCIES:-}"
livekit_dir="${NATIVE_GUEST_LIVEKIT_BUILD_DIR:-}"
sdk_source="${NATIVE_GUEST_LIVEKIT_SOURCE:-$repo_dir/.build/native-mac-guest-m156/HostDerivedData/SourcePackages/checkouts/client-sdk-swift}"
usage() {
    echo "Usage: $0 [--framework-root DIR] [--dependency-dir DIR] [--sdk-build-dir DIR] [--sdk-source DIR]"
}
while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --framework-root|--dependency-dir|--sdk-build-dir|--sdk-source)
            if (($# < 2)); then usage >&2; exit 64; fi
            case "$1" in
                --framework-root) framework_root="$2" ;;
                --dependency-dir) dependency_root="$2" ;;
                --sdk-build-dir) livekit_dir="$2" ;;
                --sdk-source) sdk_source="$2" ;;
            esac
            shift 2 ;;
        *) usage >&2; exit 64 ;;
    esac
done
framework_sha="$(python3 - "$framework_root" <<'PYFRAMEWORK'
import hashlib, pathlib, plistlib, sys
framework = pathlib.Path(sys.argv[1]).resolve() / 'LiveKitWebRTC.xcframework'
info = plistlib.loads((framework / 'Info.plist').read_bytes())
slices = [value for value in info['AvailableLibraries'] if value['SupportedPlatform'] == 'macos' and 'arm64' in value['SupportedArchitectures']]
if len(slices) != 1: raise SystemExit('Expected exactly one native arm64 macOS framework slice')
binary = framework / slices[0]['LibraryIdentifier'] / slices[0]['LibraryPath'] / 'LiveKitWebRTC'
digest = hashlib.sha256()
with binary.open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
print(digest.hexdigest())
PYFRAMEWORK
)"
# The binary identity isolates both source/package state and compiler outputs.
# Selecting an older artifact never repoints the baseline SDK or its framework.
unit_root="$repo_dir/.build/native-rock-unit/$framework_sha"
dependency_root="${dependency_root:-$unit_root/Dependencies}"
livekit_dir="${livekit_dir:-$unit_root/LiveKitDerived}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-guest-rock.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
python3 "$source_dir/prepare-livekit.py" --source "$sdk_source" \
    --framework "$framework_root/LiveKitWebRTC.xcframework" --destination "$dependency_root"
livekit_source="$dependency_root/client-sdk-swift"
core_dir="${NATIVE_GUEST_CORE_BUILD_DIR:-$repo_dir/.build/native-guest/library-core}"
swift build --package-path "$livekit_source" --scratch-path "$livekit_dir" --product LiveKit
swift build --package-path "$repo_dir/ConferenceCore" --scratch-path "$core_dir" --product ConferenceCore
products="$(swift build --package-path "$livekit_source" --scratch-path "$livekit_dir" --show-bin-path)"
core_products="$(swift build --package-path "$repo_dir/ConferenceCore" --scratch-path "$core_dir" --show-bin-path)"
python3 - "$dependency_root/native-livekit.json" "$products/LiveKitWebRTC.framework/LiveKitWebRTC" <<'PYVERIFY'
import hashlib, json, pathlib, sys
marker = json.loads(pathlib.Path(sys.argv[1]).read_text())
digest = hashlib.sha256()
with pathlib.Path(sys.argv[2]).open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
actual = digest.hexdigest()
if actual != marker['framework_sha256']: raise SystemExit('Built SDK selected a different WebRTC binary')
print('Rock unit framework SHA256: ' + actual)
PYVERIFY
module_maps="$livekit_dir/out/Intermediates.noindex/GeneratedModuleMaps"
swiftc -swift-version 5 -parse-as-library -I "$products" -I "$core_products" \
    -L "$products" -L "$core_products" -lLiveKit -lConferenceCore \
    -Xcc "-fmodule-map-file=$module_maps/CLiveKitProto.modulemap" \
    -Xcc "-fmodule-map-file=$module_maps/LKObjCHelpers.modulemap" \
    -F "$products" -framework LiveKitWebRTC -framework RustLiveKitUniFFI \
    -Xlinker -rpath -Xlinker "$products" \
    "$products/CLiveKitProto.o" "$products/LKObjCHelpers.o" "$products/LiveKitNanopb.o" "$products/LiveKitUniFFI.o" \
    "$source_dir/Engines/NativeDesktopExternalEngine.swift" "$source_dir/Engines/NativeDesktopRockEngine.swift" \
    "$source_dir/Engines/NativeDesktopRockPolicies.swift" "$repo_dir/RockNRoll/VideoSubscriptionCoordinator.swift" \
    "$repo_dir/RockNRoll/JamService.swift" "$repo_dir/RockNRoll/ChatStore.swift" \
    "$repo_dir/RockNRoll/ReactionHistoryStore.swift" "$repo_dir/RockNRoll/NativeVideoPixelBuffer.swift" \
    "$repo_dir/Shared/Localization.swift" "$repo_dir/Shared/GuestAudioProfile.swift" "$repo_dir/Shared/GuestAudioOwnerLease.swift" \
    "$source_dir/Tests/NativeDesktopRockEngineTests.swift" \
    -o "$build_dir/native-rock-tests"
cp -R "$core_products/ConferenceCore_ConferenceCore.bundle" "$build_dir/"
cp -R "$products/LiveKit_LiveKit.bundle" "$build_dir/"
"$build_dir/native-rock-tests"
