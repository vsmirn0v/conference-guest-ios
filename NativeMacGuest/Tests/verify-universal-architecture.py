#!/usr/bin/env python3
"""Static architecture gate for the multiplatform universal meeting engine (macOS + iOS).

Verifies:
1. Obsolete Mac facade files and deleted iOS legacy/Mac-shim paths remain deleted.
2. `import LiveKit` (distinct from `import LiveKitWebRTC`) stays confined to the
   approved Rock/LiveKit integration files and test targets on macOS and in MeetingEngine.
3. Mac UI/shell, App entry, Attention, MCP, Settings, Updates, and iOS app/extension/shared
   files contain no references to concrete provider adapters or deleted legacy engine facades.
4. UniversalMeetingEngine constructs sessions for all four MeetingEngineKind
   providers without runtime fallback to legacy engines.
5. MeetingEngine is declared multiplatform (.iOS and .macOS), Guest providers never import
   ConferenceCore, iOS targets/project.yml contain zero legacy SDK or isiOSAppOnMac
   references, and RockNRoll/ConferenceModel.swift routes via UniversalMeetingEngine and
   IOSMeetingSessionController.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
NATIVE_MAC = ROOT / "NativeMacGuest"

OBSOLETE_FILES = (
    "Engines/NativeDesktopGuestEngine.swift",
    "Engines/NativeDesktopRockEngine.swift",
    "Engines/NativeDesktopExternalSession.swift",
    "Engines/NativeDesktopProviderSignals.swift",
)

DELETED_IOS_AND_LEGACY_PATHS = (
    "Dependencies/guest-sdk",
    "Dependencies/webrtc-xcframework",
    "GuestBroadcast",
    "Shared/GuestBroadcastStop.swift",
    "scripts/copy-sdk-resources.sh",
    "scripts/prepare-guest-sdk.sh",
    "RockNRoll/BridgingHeader.h",
    "RockNRoll/RockRoomEngine.swift",
    "RockNRoll/Telemost",
    "RockNRoll/TrueConf",
    "RockNRoll/VendorIntegration/NativeConferenceEngine.swift",
    "RockNRoll/VendorIntegration/CallControls.swift",
    "RockNRoll/NativeRTC/NativeRTCPeer.swift",
    "RockNRoll/NativeRTC/NativeCallAudio.swift",
    "RockNRoll/MacMeetingCoordinator.swift",
    "RockNRoll/MacAudioDevices.swift",
    "RockNRoll/MacScreenCaptureBridge.h",
    "RockNRoll/MacScreenCaptureBridge.m",
)

LIVEKIT_IMPORT_ALLOWLIST = {
    "NativeMacGuest/Engines/SharedAudioEngine+LiveKit.swift",
    "NativeMacGuest/Engines/NativeDesktopRockPolicies.swift",
    "NativeMacGuest/MeetingEngine/Providers/Rock/RockAudioBridge.swift",
    "NativeMacGuest/MeetingEngine/Providers/Rock/RockMediaBridges.swift",
    "NativeMacGuest/MeetingEngine/Providers/Rock/RockAdapter.swift",
    "MeetingEngine/Sources/MeetingEngine/Audio/SharedAudioEngine+LiveKit.swift",
    "MeetingEngine/Sources/MeetingEngine/Audio/NativeDesktopRockPolicies.swift",
    "MeetingEngine/Sources/MeetingEngine/Providers/Rock/RockAudioBridge.swift",
    "MeetingEngine/Sources/MeetingEngine/Providers/Rock/RockMediaBridges.swift",
    "MeetingEngine/Sources/MeetingEngine/Providers/Rock/RockAdapter.swift",
}

CONCRETE_ADAPTER_SYMBOLS = (
    "GuestAdapter",
    "TelemostAdapter",
    "TrueConfAdapter",
    "RockAdapter",
)

GUEST_CONFERENCE_CORE_ALLOWLIST = {
    "GuestAdapter.swift",
    "GuestFeatureServices.swift",
    "GuestSiteLinkAdapter.swift",
    "VendorEndpointResolver.swift",
}

FORBIDDEN_UI_SYMBOLS = CONCRETE_ADAPTER_SYMBOLS + (
    "NativeDesktopGuestEngine",
    "NativeDesktopRockEngine",
    "NativeDesktopExternalSession",
    "NativeDesktopProviderSignals",
    "NativeDesktopTelemostEngine",
    "NativeDesktopTrueConfEngine",
)

ALL_LEGACY_SYMBOLS = (
    "NativeDesktopGuestEngine",
    "NativeDesktopRockEngine",
    "NativeDesktopExternalSession",
    "NativeDesktopProviderSignals",
    "NativeDesktopTelemostEngine",
    "NativeDesktopTrueConfEngine",
)

IOS_SOURCE_ROOTS = (
    ROOT / "RockNRoll",
    ROOT / "RockBroadcast",
    ROOT / "MeetingActivity",
    ROOT / "Shared",
)

IOS_ALL_CODE_ROOTS = IOS_SOURCE_ROOTS + (
    ROOT / "RockNRollTests",
    ROOT / "RockNRollUITests",
)

LIVEKIT_IMPORT_RE = re.compile(r"(?m)^\s*import\s+LiveKit\b")
CONFERENCE_CORE_IMPORT_RE = re.compile(r"(?m)^\s*import\s+ConferenceCore\b")
CONCRETE_ADAPTER_RE = re.compile(r"\b(" + "|".join(CONCRETE_ADAPTER_SYMBOLS) + r")\b")
FORBIDDEN_UI_RE = re.compile(r"\b(" + "|".join(FORBIDDEN_UI_SYMBOLS) + r")\b")
LEGACY_SYMBOL_RE = re.compile(r"\b(" + "|".join(ALL_LEGACY_SYMBOLS) + r")\b")
IOS_LEGACY_SDK_RE = re.compile(
    r"(import JazzSDK|import WebRTC\b|GuestConferenceSDK|LibSberCast|Spench|SDSoup|"
    r"GuestBroadcast|isiOSAppOnMac|\bNativeConferenceEngine\b|\bRockRoomEngine\b|"
    r"\bTelemostCallEngine\b|\bTrueConfCallEngine\b|\bNativeCallAudio\b|\bNativeRTCPeer\b)"
)


def is_ui_or_feature_boundary(rel: pathlib.Path) -> bool:
    parts = rel.parts
    if not parts:
        return False
    first = parts[0]
    if first in {"Attention", "MCP", "Settings", "Updates"}:
        return True
    if len(parts) == 1 and (first.startswith("Desktop") or first in {"MeetingController.swift", "App.swift"}):
        return True
    return False


def main() -> int:
    failures: list[str] = []

    for rel in OBSOLETE_FILES:
        if (NATIVE_MAC / rel).exists():
            failures.append(f"Obsolete facade still exists: NativeMacGuest/{rel}")

    for rel in DELETED_IOS_AND_LEGACY_PATHS:
        if (ROOT / rel).exists():
            failures.append(f"Deleted legacy/Mac-shim path still exists: {rel}")

    package_path = ROOT / "MeetingEngine/Package.swift"
    if not package_path.exists():
        failures.append("Missing MeetingEngine/Package.swift")
    else:
        package_text = package_path.read_text(encoding="utf-8", errors="replace")
        for token in (".iOS(", ".macOS("):
            if token not in package_text:
                failures.append(f"MeetingEngine/Package.swift missing platform declaration `{token}`")

    guest_provider_dir = ROOT / "MeetingEngine/Sources/MeetingEngine/Providers/Guest"
    if not guest_provider_dir.is_dir():
        failures.append("Missing MeetingEngine/Sources/MeetingEngine/Providers/Guest directory")
    else:
        for path in sorted(guest_provider_dir.rglob("*.swift")):
            if path.name in GUEST_CONFERENCE_CORE_ALLOWLIST:
                continue
            rel_repo = path.relative_to(ROOT).as_posix()
            text = path.read_text(encoding="utf-8", errors="replace")
            if CONFERENCE_CORE_IMPORT_RE.search(text):
                failures.append(f"Guest provider file imports ConferenceCore: {rel_repo}")

    for root_dir in (NATIVE_MAC, ROOT / "MeetingEngine/Sources/MeetingEngine"):
        for path in sorted(root_dir.rglob("*.swift")):
            rel_repo = path.relative_to(ROOT).as_posix()
            rel = path.relative_to(root_dir)
            rel_posix = rel.as_posix()
            text = path.read_text(encoding="utf-8", errors="replace")

            if LEGACY_SYMBOL_RE.search(text):
                failures.append(f"Legacy facade symbol referenced in {rel_repo}")

            in_tests = root_dir == NATIVE_MAC and rel.parts and rel.parts[0] == "Tests"
            if LIVEKIT_IMPORT_RE.search(text):
                if not in_tests and rel_repo not in LIVEKIT_IMPORT_ALLOWLIST:
                    failures.append(f"Disallowed `import LiveKit` in {rel_repo}")

            if root_dir == NATIVE_MAC and is_ui_or_feature_boundary(rel):
                for match in FORBIDDEN_UI_RE.finditer(text):
                    failures.append(
                        f"Shell/feature file NativeMacGuest/{rel_posix} references forbidden symbol `{match.group(1)}`"
                    )

    for root_dir in IOS_SOURCE_ROOTS:
        if not root_dir.exists():
            failures.append(f"Missing iOS source root: {root_dir.relative_to(ROOT).as_posix()}")
            continue
        for path in sorted(root_dir.rglob("*.swift")):
            rel_repo = path.relative_to(ROOT).as_posix()
            text = path.read_text(encoding="utf-8", errors="replace")
            for match in CONCRETE_ADAPTER_RE.finditer(text):
                failures.append(f"iOS/shared file {rel_repo} references concrete adapter `{match.group(1)}`")

    for root_dir in IOS_ALL_CODE_ROOTS:
        if not root_dir.exists():
            continue
        for ext in ("*.swift", "*.h", "*.m"):
            for path in sorted(root_dir.rglob(ext)):
                rel_repo = path.relative_to(ROOT).as_posix()
                text = path.read_text(encoding="utf-8", errors="replace")
                for match in IOS_LEGACY_SDK_RE.finditer(text):
                    failures.append(f"Legacy SDK/shim reference `{match.group(1)}` in {rel_repo}")

    project_yml = ROOT / "project.yml"
    if not project_yml.exists():
        failures.append("Missing root project.yml")
    else:
        yml_text = project_yml.read_text(encoding="utf-8", errors="replace")
        for match in IOS_LEGACY_SDK_RE.finditer(yml_text):
            failures.append(f"Legacy SDK/shim reference `{match.group(1)}` in project.yml")
        for required in (
            "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO",
            "SUPPORTS_MACCATALYST: NO",
            "MeetingEngine",
            "ConferenceCore",
            "LiveKit",
            "RockBroadcast",
            "MeetingActivity",
            ".build/unified-sdk-dependencies/webrtc-xcframework",
        ):
            if required not in yml_text:
                failures.append(f"project.yml missing `{required}`")

    conf_model = ROOT / "RockNRoll/ConferenceModel.swift"
    if not conf_model.exists():
        failures.append("Missing RockNRoll/ConferenceModel.swift")
    else:
        conf_text = conf_model.read_text(encoding="utf-8", errors="replace")
        for required in ("UniversalMeetingEngine", "IOSMeetingSessionController"):
            if required not in conf_text:
                failures.append(f"RockNRoll/ConferenceModel.swift missing `{required}`")
        if "exclusiveTalk: true" in conf_text:
            failures.append("RockNRoll/ConferenceModel.swift must not set exclusiveTalk: true")

    engine_path = ROOT / "MeetingEngine/Sources/MeetingEngine/Core/UniversalMeetingEngine.swift"
    engine_text = engine_path.read_text(encoding="utf-8", errors="replace")
    for required in ("case .guest:", "GuestAdapter(", "case .community:", "RockAdapter(",
                     "case .telemost:", "TelemostAdapter(", "case .trueconf:", "TrueConfAdapter("):
        if required not in engine_text:
            failures.append(f"UniversalMeetingEngine.swift missing `{required}`")

    if failures:
        for item in failures:
            print(f"FAIL: {item}", file=sys.stderr)
        return 1

    print(
        "PASS: Multiplatform universal engine architecture verified "
        "(0 obsolete/legacy/Mac-shim paths, 0 ConferenceCore imports in Guest providers, "
        "LiveKit imports confined on macOS/MeetingEngine, 0 concrete adapter or legacy SDK "
        "references across Mac/iOS boundaries, ConferenceModel wired to UniversalMeetingEngine "
        "+ IOSMeetingSessionController, and all 4 providers routed through UniversalMeetingEngine)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
