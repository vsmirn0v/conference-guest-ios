#!/usr/bin/env python3
"""Build a local-only, signed native camera probe; never launch it or alter TCC."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--identity", required=True, help="Existing Apple Development signing identity")
parser.add_argument("--mode", choices=["background", "reaction"], default="background")
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
root = repo / ".build/native-mac-camera108"
app = root / "NativeCameraProbe.app"
macos = app / "Contents/MacOS"
macos.mkdir(parents=True, exist_ok=True)
info = {
    "CFBundleExecutable": "NativeCameraProbe",
    "CFBundleIdentifier": "dev.vsmirn0v.conferenceguest",
    "CFBundleName": "Rock Native Camera Probe",
    "CFBundleDisplayName": "Rock Native Camera Probe",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "1.0",
    "CFBundleSupportedPlatforms": ["MacOSX"],
    "LSMinimumSystemVersion": "15.0",
    "NSPrincipalClass": "NSApplication",
    "RockCameraProbeMode": args.mode,
    "NSCameraUsageDescription": "Local system-background orientation test. Saves four images on this Mac and stops within fifteen seconds. No audio or network.",
}
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
entitlements = root / "camera.entitlements"
entitlements.write_bytes(plistlib.dumps({"com.apple.security.device.camera": True}))
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()
subprocess.run(["xcrun", "swiftc", "-sdk", sdk, "-target", "arm64-apple-macos15.0", "-O",
                str(Path(__file__).with_name("main.swift")), "-o", str(macos / "NativeCameraProbe")], env=env, check=True)
subprocess.run(["codesign", "--force", "--options", "runtime", "--sign", args.identity,
                "--entitlements", str(entitlements), str(app)], check=True)
subprocess.run(["codesign", "--verify", "--strict", "--deep", str(app)], check=True)
print(app)
