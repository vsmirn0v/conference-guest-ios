#!/usr/bin/env python3
"""Find one compatible framework directory from XCFramework metadata."""
import plistlib
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
platform, variant, architecture = sys.argv[2:5]
with (root / "Info.plist").open("rb") as stream:
    libraries = plistlib.load(stream)["AvailableLibraries"]
matches = [item for item in libraries
           if item["SupportedPlatform"] == platform
           and item.get("SupportedPlatformVariant", "") == variant
           and architecture in item["SupportedArchitectures"]]
if len(matches) != 1:
    sys.exit(f"Expected one {platform}/{variant}/{architecture} slice; found {len(matches)}")
library = matches[0]
framework = root / library["LibraryIdentifier"] / library["LibraryPath"]
if not framework.is_dir():
    sys.exit(f"Missing framework: {framework}")
print(framework.parent)
