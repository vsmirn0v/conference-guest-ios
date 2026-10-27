#!/usr/bin/env python3
"""Prepare the native Mac SDK and pinned LiveKit sources on a fresh checkout."""
import argparse
import json
import subprocess

from native_dependencies import ensure_framework, ensure_livekit_source


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--framework-only", action="store_true", help="Extract and verify the committed SDK without network access")
    options = parser.parse_args()
    try:
        result = {"framework_root": str(ensure_framework())}
        if not options.framework_only:
            result["livekit_source"] = str(ensure_livekit_source())
        print(json.dumps(result, indent=2))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Native dependency preparation failed: {error}\n")
