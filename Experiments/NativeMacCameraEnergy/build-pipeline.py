#!/usr/bin/env python3
"""Build shipped/candidate GuestCamera pipeline probes with the native app's identifier.
Never launch them, alter TCC, or install them; unregister them after use."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--identity", required=True, help="Existing Apple Development signing identity")
parser.add_argument("--framework-dir", type=Path, required=True, help="Directory containing LiveKitWebRTC.framework")
parser.add_argument("--shipped-ref", default="HEAD", help="Git revision of the shipped GuestCamera.swift")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
here = Path(__file__).parent
guest = repo / "Experiments/NativeGuest"
args.output.mkdir(parents=True, exist_ok=True)
shipped = args.output / "GuestCamera-shipped.swift"
shipped.write_bytes(subprocess.check_output(["git", "-C", str(repo), "show", f"{args.shipped_ref}:Experiments/NativeGuest/GuestCamera.swift"]))
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env, text=True).strip()
for name, camera, flags in [("Shipped", shipped, []), ("Candidate", guest / "GuestCamera.swift", ["-D", "CANDIDATE_CAMERA"])]:
    app = args.output / f"CameraPipeline{name}.app"
    macos = app / "Contents/MacOS"
    macos.mkdir(parents=True, exist_ok=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "CameraPipeline", "CFBundleIdentifier": "dev.vsmirn0v.conferenceguest.nativeguest",
        "CFBundleName": f"Rock Camera Pipeline {name}", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0", "LSMinimumSystemVersion": "15.0", "LSUIElement": True,
        "NSPrincipalClass": "NSApplication",
        "NSCameraUsageDescription": "Local camera energy measurement. Video only; no images, audio or network.",
    }))
    subprocess.run(["xcrun", "swiftc", "-sdk", sdk, "-target", "arm64-apple-macos15.0", "-O", "-swift-version", "5",
                    "-parse-as-library", *flags, "-F", str(args.framework_dir), "-framework", "LiveKitWebRTC",
                    "-Xlinker", "-rpath", "-Xlinker", str(args.framework_dir),
                    str(guest / "GuestCaptureAuthorization.swift"), str(camera), str(here / "PipelineMain.swift"),
                    "-o", str(macos / "CameraPipeline")], env=env, check=True)
    subprocess.run(["codesign", "--force", "--sign", args.identity, str(app)], check=True)
    print(app)
