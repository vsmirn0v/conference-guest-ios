#!/usr/bin/env python3
"""Static architecture gate for the Native Mac universal meeting engine.

Verifies:
1. Obsolete provider facade files remain deleted.
2. `import LiveKit` (distinct from `import LiveKitWebRTC`) stays confined to the
   approved Rock/LiveKit integration files and test targets.
3. UI/shell, App entry, Attention, MCP, Settings, and Updates files contain no
   references to concrete provider adapters or deleted legacy engine facades.
4. UniversalMeetingEngine constructs sessions for all four MeetingEngineKind
   providers without runtime fallback to legacy engines.
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

LIVEKIT_IMPORT_ALLOWLIST = {
    "Engines/SharedAudioEngine+LiveKit.swift",
    "Engines/NativeDesktopRockPolicies.swift",
    "MeetingEngine/Providers/Rock/RockAudioBridge.swift",
    "MeetingEngine/Providers/Rock/RockMediaBridges.swift",
    "MeetingEngine/Providers/Rock/RockAdapter.swift",
}

FORBIDDEN_UI_SYMBOLS = (
    "GuestAdapter",
    "TelemostAdapter",
    "TrueConfAdapter",
    "RockAdapter",
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

LIVEKIT_IMPORT_RE = re.compile(r"(?m)^\s*import\s+LiveKit\b")
FORBIDDEN_UI_RE = re.compile(r"\b(" + "|".join(FORBIDDEN_UI_SYMBOLS) + r")\b")
LEGACY_SYMBOL_RE = re.compile(r"\b(" + "|".join(ALL_LEGACY_SYMBOLS) + r")\b")


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

    for path in sorted(NATIVE_MAC.rglob("*.swift")):
        rel = path.relative_to(NATIVE_MAC)
        rel_posix = rel.as_posix()
        text = path.read_text(encoding="utf-8", errors="replace")

        if LEGACY_SYMBOL_RE.search(text):
            failures.append(f"Legacy facade symbol referenced in NativeMacGuest/{rel_posix}")

        in_tests = rel.parts and rel.parts[0] == "Tests"
        if LIVEKIT_IMPORT_RE.search(text):
            if not in_tests and rel_posix not in LIVEKIT_IMPORT_ALLOWLIST:
                failures.append(f"Disallowed `import LiveKit` in NativeMacGuest/{rel_posix}")

        if is_ui_or_feature_boundary(rel):
            for match in FORBIDDEN_UI_RE.finditer(text):
                failures.append(
                    f"Shell/feature file NativeMacGuest/{rel_posix} references forbidden symbol `{match.group(1)}`"
                )

    engine_path = NATIVE_MAC / "MeetingEngine/Core/UniversalMeetingEngine.swift"
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
        "PASS: Universal engine architecture verified "
        "(0 obsolete facades, LiveKit imports confined to allowlist, "
        "0 concrete adapter/engine references in shell/feature boundaries, "
        "all 4 providers routed through UniversalMeetingEngine)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
