#!/usr/bin/env python3
"""Build the local camera-energy probe with the native app's identifier so it
inherits the app's camera permission and per-app Video Effects (Background).
Never launch it, alter TCC, or install it; unregister it after use."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--identity", required=True, help="Existing Apple Development signing identity")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
app = args.output / "CameraEnergyProbe.app"
macos = app / "Contents/MacOS"
macos.mkdir(parents=True, exist_ok=True)
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleExecutable": "CameraEnergyProbe",
    "CFBundleIdentifier": "dev.vsmirn0v.conferenceguest.nativeguest",
    "CFBundleName": "Rock Camera Energy Probe",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "1.0",
    "LSMinimumSystemVersion": "15.0",
    "LSUIElement": True,
    "NSPrincipalClass": "NSApplication",
    "NSCameraUsageDescription": "Local camera energy measurement. Video only; no images, audio or network.",
}))
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()
subprocess.run(["xcrun", "swiftc", "-sdk", sdk, "-target", "arm64-apple-macos15.0", "-O",
                str(Path(__file__).with_name("main.swift")), "-o", str(macos / "CameraEnergyProbe")], env=env, check=True)
subprocess.run(["codesign", "--force", "--sign", args.identity, str(app)], check=True)
subprocess.run(["codesign", "--verify", "--strict", "--deep", str(app)], check=True)
print(app)
