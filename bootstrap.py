#!/usr/bin/env python3
"""Prepare unified macOS + iOS native WebRTC and patched LiveKit SDK dependencies."""
import argparse
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "NativeMacGuest"))

from native_dependencies import ensure_framework, ensure_livekit_source  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--framework-only",
        action="store_true",
        help="Extract and verify the committed 3-slice WebRTC XCFramework without network access",
    )
    parser.add_argument(
        "--destination",
        type=pathlib.Path,
        default=ROOT / ".build/unified-sdk-dependencies",
        help="Destination directory for patched LiveKit and WebRTC SPM wrapper packages",
    )
    options = parser.parse_args()
    try:
        framework_root = ensure_framework()
        result: dict[str, object] = {"framework_root": str(framework_root)}
        if not options.framework_only:
            livekit_source = ensure_livekit_source()
            result["livekit_source"] = str(livekit_source)
            prepared = subprocess.check_output(
                [
                    sys.executable,
                    str(ROOT / "NativeMacGuest/prepare-livekit.py"),
                    "--source",
                    str(livekit_source),
                    "--framework",
                    str(framework_root / "LiveKitWebRTC.xcframework"),
                    "--destination",
                    str(options.destination),
                ],
                cwd=ROOT,
                text=True,
            )
            result["prepared"] = json.loads(prepared)
        print(json.dumps(result, indent=2))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Unified dependency preparation failed: {error}\n")


if __name__ == "__main__":
    main()
