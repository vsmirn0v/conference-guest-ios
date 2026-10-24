#!/usr/bin/env python3
"""Create a private app test project with the audited M150 guest candidate."""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

import importlib.util

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
module_spec = importlib.util.spec_from_file_location("maintenance_verify", HERE / "verify-source.py")
module = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(module)
verify = module.verify

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
parser.add_argument("vendor", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
source, vendor, output = (p.resolve() for p in (args.source, args.vendor, args.output))
provenance = verify(source, "guest")
revision = subprocess.check_output(["git", "-C", str(vendor), "rev-parse", "HEAD"], text=True).strip()
if revision != "6d5f92869690fa22bb489a9089aa554d733c6936":
    raise SystemExit("Unexpected vendor wrapper revision")
if subprocess.check_output(["git", "-C", str(vendor), "status", "--porcelain", "--untracked-files=all"], text=True).strip():
    raise SystemExit("Vendor checkout must be clean")
def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()
wrapper_hashes = {str(p.relative_to(vendor)): digest(p)
                  for p in sorted((vendor / "Sources").rglob("*"))
                  if p.is_file() and "WebRTC.xcframework" not in p.parts}
output.mkdir(parents=True, exist_ok=False)
os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
sdk = output / "sdk/JazzSDK"
(sdk / "Sources").mkdir(parents=True)
shutil.copy2(vendor / "Package.swift", sdk / "Package.swift")
for item in (vendor / "Sources").iterdir():
    if item.name != "WebRTC.xcframework":
        (sdk / "Sources" / item.name).symlink_to(item)
framework = sdk / "Sources/WebRTC.xcframework"
subprocess.run(["xcodebuild", "-create-xcframework", "-framework",
    str(source / "out/rock-hybrid-ios-device/WebRTC.framework"), "-framework",
    str(source / "out/rock-hybrid-ios-simulator/WebRTC.framework"), "-output", str(framework)], check=True)
sys.path.insert(0, str(HERE.parent / "GuestSDKRebuild"))
from verify_package_inputs import verify_inputs
import plistlib
provenance["slices"] = verify_inputs(source, framework, plistlib.loads((framework / "Info.plist").read_bytes()))
provenance["vendor_wrapper_revision"] = revision
provenance["vendor_files_sha256"] = wrapper_hashes
notices = []
for name in ["LICENSE", "PATENTS", "AUTHORS"]:
    notices.append(f"===== WebRTC {name} =====\n" + (source / name).read_text())
for environment in ["device", "simulator"]:
    license_dir = output / "licenses" / environment
    license_dir.mkdir(parents=True)
    subprocess.run([sys.executable, str(source / "tools_webrtc/libs/generate_licenses.py"),
        "--target", "//sdk:framework_objc", str(license_dir),
        str(source / f"out/rock-hybrid-ios-{environment}")], cwd=source, check=True)
    linked = (license_dir / "LICENSE.md").read_text()
    if not linked.strip():
        raise RuntimeError("Missing linked dependency licenses")
    notices.append(f"===== {environment} linked dependencies =====\n" + html.unescape(linked))
metadata = plistlib.loads((framework / "Info.plist").read_bytes())
for item in metadata["AvailableLibraries"]:
    embedded = framework / item["LibraryIdentifier"] / item["LibraryPath"]
    (embedded / "GuestWebRTC-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    (embedded / "GuestWebRTC-notices.txt").write_text("\n".join(notices) + "\n")
if verify_inputs(source, framework, metadata) != provenance["slices"]:
    raise RuntimeError("Candidate inputs changed during packaging")
(output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
subprocess.run(["xcodegen", "dump", "--spec", str(REPO / "project.yml"), "--type", "json",
                "--file", str(output / "base-spec.json")], check=True)
spec = json.loads((output / "base-spec.json").read_text())
spec["name"] = "MaintenanceExperiment"
for package in spec["packages"].values():
    if "path" in package:
        package["path"] = str(REPO / package["path"])
spec["packages"]["JazzSDK"] = {"path": str(sdk)}
for target in spec["targets"].values():
    for item in target.get("sources", []):
        item["path"] = str(REPO / item["path"])
    for dependency in target.get("dependencies", []):
        if "framework" in dependency:
            dependency["framework"] = str(REPO / dependency["framework"])
    for key, value in target.get("settings", {}).get("base", {}).items():
        if key in ["INFOPLIST_FILE", "CODE_SIGN_ENTITLEMENTS", "SWIFT_OBJC_BRIDGING_HEADER"]:
            target["settings"]["base"][key] = str(REPO / value)
    for script in target.get("postBuildScripts", []):
        if script.get("name") == "Copy provider SDK resources":
            script["script"] = ("CONFERENCE_SDK_SOURCE_DIR=" + shlex.quote(str(vendor / "Sources"))
                + " bash " + shlex.quote(str(REPO / "scripts/copy-sdk-resources.sh")))
project = output / "project"
project.mkdir()
(project / "project-spec.json").write_text(json.dumps(spec, indent=2) + "\n")
for name in ["RockNRoll", "RockNRollTests", "RockNRollUITests", "RockBroadcast", "GuestBroadcast", "Shared",
             "Experiments", "scripts", "ConferenceCore", "Dependencies"]:
    (project / name).symlink_to(REPO / name, target_is_directory=True)
subprocess.run(["xcodegen", "generate", "--spec", str(project / "project-spec.json"), "--project", str(project)], check=True)
