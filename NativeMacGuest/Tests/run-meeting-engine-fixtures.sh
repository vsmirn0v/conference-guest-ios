#!/bin/bash
set -euo pipefail
suite="$1"
shift
source_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
repo_dir="$(dirname -- "$source_dir")"
framework_root="${NATIVE_GUEST_FRAMEWORK_ROOT:-$(python3 - "$repo_dir/Dependencies/native-macos/sdk.lock.json" "$repo_dir" <<'PYLOCK'
import json, pathlib, sys
print(pathlib.Path(sys.argv[2]) / json.loads(pathlib.Path(sys.argv[1]).read_text())['destination'])
PYLOCK
)}"
dependency_root="${NATIVE_GUEST_LIVEKIT_DEPENDENCIES:-}"
livekit_dir="${NATIVE_GUEST_LIVEKIT_BUILD_DIR:-}"
sdk_source="${NATIVE_GUEST_LIVEKIT_SOURCE:-}"
usage() {
    echo "Usage: bash NativeMacGuest/test-rock.sh [--framework-root DIR] [--dependency-dir DIR] [--sdk-build-dir DIR] [--sdk-source DIR]"
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
import hashlib, json, pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
framework = root / 'LiveKitWebRTC.xcframework'
info = plistlib.loads((framework / 'Info.plist').read_bytes())
slices = [value for value in info['AvailableLibraries'] if value['SupportedPlatform'] == 'macos' and 'arm64' in value['SupportedArchitectures']]
if len(slices) != 1: raise SystemExit('Expected exactly one native arm64 macOS framework slice')
binary = framework / slices[0]['LibraryIdentifier'] / slices[0]['LibraryPath'] / 'LiveKitWebRTC'
digest = hashlib.sha256()
with binary.open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
actual = digest.hexdigest()
evidence = json.loads((root / 'build-evidence.json').read_text())
if actual != evidence['frameworkBinarySHA256']: raise SystemExit('Framework binary differs from build evidence')
print(actual)
PYFRAMEWORK
)"
# The binary identity isolates both source/package state and compiler outputs.
# Selecting an older artifact never repoints the baseline SDK or its framework.
unit_root="$repo_dir/.build/native-rock-unit/$framework_sha"
dependency_root="${dependency_root:-$unit_root/Dependencies}"
livekit_dir="${livekit_dir:-$unit_root/LiveKitDerived}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/native-meeting-fixtures.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
prepare_args=(--framework "$framework_root/LiveKitWebRTC.xcframework" --destination "$dependency_root")
if [[ -n "$sdk_source" ]]; then prepare_args+=(--source "$sdk_source"); fi
python3 "$source_dir/prepare-livekit.py" "${prepare_args[@]}"
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
print('Meeting fixture framework SHA256: ' + actual)
PYVERIFY
module_maps="$livekit_dir/out/Intermediates.noindex/GeneratedModuleMaps"
sources=()
for file in "$repo_dir"/Experiments/NativeGuest/*.swift; do
    case "$file" in */Main.swift|*/GuestCompanionPeer.swift) continue ;; esac
    sources+=("$file")
done
sources+=(
    "$source_dir/Engines/MeetingAudioSource.swift"
    "$source_dir/Engines/NativeDesktopExternalEngine.swift"
    "$source_dir/Engines/SharedAudioEngine.swift"
    "$source_dir/Engines/SharedAudioEngine+LiveKit.swift"
    "$repo_dir/Shared/GuestAudioOwnerLease.swift"
    "$repo_dir/Shared/GuestAudioProfile.swift"
    "$repo_dir/Shared/Localization.swift"
    "$repo_dir/RockNRoll/NativeVideoPixelBuffer.swift"
)
extra_objects=()
compiler_flags=()
case "$suite" in
    rock)
        # The private lease fixture exercises the explicitly selected compatibility path.
        compiler_flags+=(-D NATIVE_LEGACY_AUDIO)
        sources+=(
            "$source_dir/Engines/NativeDesktopRockPolicies.swift"
            "$source_dir/MeetingEngine/Core/MeetingSessionContracts.swift"
            "$source_dir/MeetingEngine/Core/MeetingProviderAdapter.swift"
            "$source_dir/MeetingEngine/Features/MeetingFeatureServices.swift"
            "$source_dir/MeetingEngine/Media/MeetingMediaHandles.swift"
            "$source_dir/MeetingEngine/Providers/Rock/RockAudioBridge.swift"
            "$source_dir/MeetingEngine/Providers/Rock/RockMediaBridges.swift"
            "$source_dir/MeetingEngine/Providers/Rock/RockAdapter.swift"
            "$source_dir/MeetingLibrary/MeetingWorkspaceEvent.swift"
            "$repo_dir/RockNRoll/VideoSubscriptionCoordinator.swift"
            "$repo_dir/RockNRoll/JamService.swift"
            "$repo_dir/RockNRoll/ChatStore.swift"
            "$repo_dir/RockNRoll/ReactionHistoryStore.swift"
            "$source_dir/Tests/NativeDesktopRockEngineTests.swift"
        )
        ;;
    external)
        sources+=(
            "$source_dir/Engines/NativeDesktopRTCPeer.swift"
            "$source_dir/Engines/SharedGuestMeetingAudio.swift"
            "$source_dir/MeetingEngine/Core/MeetingSessionContracts.swift"
            "$source_dir/MeetingEngine/Core/MeetingProviderAdapter.swift"
            "$source_dir/MeetingEngine/Core/MeetingSession.swift"
            "$source_dir/MeetingEngine/Features/MeetingFeatureServices.swift"
            "$source_dir/MeetingEngine/Media/MeetingMediaHandles.swift"
            "$source_dir/MeetingEngine/Media/NativePeerOperations.swift"
            "$source_dir/MeetingEngine/Providers/Telemost/TelemostAdapter.swift"
            "$source_dir/MeetingEngine/Providers/TrueConf/TrueConfAdapter.swift"
            "$source_dir/MeetingLibrary/MeetingWorkspaceEvent.swift"
            "$repo_dir/RockNRoll/ChatStore.swift"
            "$repo_dir/RockNRoll/ReactionHistoryStore.swift"
            "$repo_dir/RockNRoll/Telemost/TelemostBootstrap.swift"
            "$repo_dir/RockNRoll/Telemost/TelemostTransport.swift"
            "$repo_dir/RockNRoll/Telemost/TelemostChat.swift"
            "$repo_dir/RockNRoll/Telemost/TelemostChatWire.swift"
            "$repo_dir/RockNRoll/TrueConf/TrueConfBootstrap.swift"
            "$repo_dir/RockNRoll/TrueConf/TrueConfTransport.swift"
            "$repo_dir/RockNRoll/TrueConf/TrueConfRoster.swift"
            "$repo_dir/RockNRoll/VendorIntegration/AdditionalRootTrust.swift"
            "$source_dir/Tests/ExternalEngineProtocolTests.swift"
        )
        ;;
    presenter)
        bridge_obj="$build_dir/MacScreenCaptureBridge.o"
        xcrun clang -fobjc-arc -target arm64-apple-macos13.0 -c "$repo_dir/RockNRoll/MacScreenCaptureBridge.m" -o "$bridge_obj"
        extra_objects+=("$bridge_obj")
        compiler_flags+=(-D DEBUG -import-objc-header "$repo_dir/RockNRoll/MacScreenCaptureBridge.h" -framework CoreMedia)
        sources+=(
            "$source_dir/Engines/NativeDesktopRTCPeer.swift"
            "$repo_dir/RockNRoll/PresenterCompositor.swift"
            "$repo_dir/RockNRoll/PresenterCanvasEdit.swift"
            "$repo_dir/RockNRoll/H264InputColorSignalling.swift"
            "$repo_dir/RockNRoll/VendorIntegration/H264ColorSignalling.swift"
            "$source_dir/DesktopShareCapture.swift"
            "$source_dir/DesktopPresenterSession.swift"
            "$source_dir/DesktopPresenterRelay.swift"
            "$source_dir/DesktopPresenterEditor.swift"
            "$source_dir/NativeDesktopCameraLease.swift"
            "$repo_dir/RockNRoll/CameraReactionObserver.swift"
            "$source_dir/Tests/NativeDesktopPresenterTests.swift"
        )
        ;;
    share-capture)
        bridge_obj="$build_dir/MacScreenCaptureBridge.o"
        xcrun clang -fobjc-arc -target arm64-apple-macos13.0 -c "$repo_dir/RockNRoll/MacScreenCaptureBridge.m" -o "$bridge_obj"
        extra_objects+=("$bridge_obj")
        compiler_flags+=(-D DEBUG -import-objc-header "$repo_dir/RockNRoll/MacScreenCaptureBridge.h" -framework CoreMedia)
        sources+=(
            "$source_dir/Engines/NativeDesktopRTCPeer.swift"
            "$repo_dir/RockNRoll/PresenterCompositor.swift"
            "$repo_dir/RockNRoll/H264InputColorSignalling.swift"
            "$repo_dir/RockNRoll/VendorIntegration/H264ColorSignalling.swift"
            "$source_dir/DesktopShareCapture.swift"
            "$source_dir/Tests/NativeDesktopShareCaptureTests.swift"
        )
        ;;
    *) echo "Unknown meeting fixture: $suite" >&2; exit 64 ;;
esac
ffi_framework="RustLiveKitFFI"
if [[ ! -d "$products/RustLiveKitFFI.framework" && -d "$products/RustLiveKitUniFFI.framework" ]]; then
    ffi_framework="RustLiveKitUniFFI"
fi
ffi_object="$products/LiveKitFFI.o"
if [[ ! -f "$ffi_object" && -f "$products/LiveKitUniFFI.o" ]]; then
    ffi_object="$products/LiveKitUniFFI.o"
fi
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
    ${compiler_flags[@]+"${compiler_flags[@]}"} -I "$products" -I "$core_products" \
    -L "$products" -L "$core_products" -lLiveKit -lConferenceCore \
    -Xcc "-fmodule-map-file=$module_maps/CLiveKitProto.modulemap" \
    -Xcc "-fmodule-map-file=$module_maps/LKObjCHelpers.modulemap" \
    -F "$products" -framework LiveKitWebRTC -framework "$ffi_framework" \
    -Xlinker -rpath -Xlinker "$products" \
    "$products/CLiveKitProto.o" "$products/LKObjCHelpers.o" "$products/LiveKitNanopb.o" "$ffi_object" \
    ${extra_objects[@]+"${extra_objects[@]}"} \
    "${sources[@]}" -o "$build_dir/meeting-fixtures"
cp -R "$core_products/ConferenceCore_ConferenceCore.bundle" "$build_dir/"
cp -R "$products/LiveKit_LiveKit.bundle" "$build_dir/"
"$build_dir/meeting-fixtures"
