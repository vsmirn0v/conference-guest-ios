#!/usr/bin/env python3
"""Run one opt-in cloud test in a Production-signed native Debug test host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--xctestrun", type=Path, required=True)
parser.add_argument("--output-dir", type=Path, required=True, help="New evidence directory; never replaces earlier results")
parser.add_argument("--mode", choices=("baseline", "rooms", "continuation", "write", "reorder", "verify", "cleanup"), required=True)
parser.add_argument("--marker", help="Same generated UUID on both devices for cross-device phases")
args = parser.parse_args()
source = args.xctestrun.resolve()
if args.mode in ("write", "reorder", "verify", "cleanup"):
    if not args.marker:
        parser.error("Cross-device phases require --marker")
if args.marker:
    try:
        uuid.UUID(args.marker)
    except ValueError:
        parser.error("--marker must be a generated UUID")
data = plistlib.loads(source.read_bytes())


def replace_root(value):
    if isinstance(value, dict):
        return {key: replace_root(item) for key, item in value.items()}
    if isinstance(value, list):
        return [replace_root(item) for item in value]
    if isinstance(value, str):
        return value.replace("__TESTROOT__", str(source.parent))
    return value


data = replace_root(data)
target = data.get("NativeDesktopTests")
if not isinstance(target, dict):
    raise SystemExit("Expected the native NativeDesktopTests xctestrun target")
host = Path(target["TestHostPath"])
if host.parent.name != "Debug":
    raise SystemExit("Use a Debug test host: its XCTest launch guard bypasses the user's normal library and preferences")
signature = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(host)], capture_output=True, check=True)
entitlements = plistlib.loads(signature.stdout)
container = "iCloud.dev.vsmirn0v.conferenceguest"
if entitlements.get("com.apple.developer.icloud-container-environment") != "Production":
    raise SystemExit("Cloud probe requires the actual signed Production entitlement; rebuild Debug with CLOUDKIT_ENVIRONMENT=Production APS_ENVIRONMENT=production")
if container not in entitlements.get("com.apple.developer.icloud-container-identifiers", []):
    raise SystemExit("Signed host does not contain the shipping private CloudKit container")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(host)], check=True)
info = plistlib.loads((host / "Contents/Info.plist").read_bytes())
binary = host / "Contents/MacOS" / info["CFBundleExecutable"]
flags = {
    "baseline": {"ROCK_NATIVE_CLOUD_ACCOUNT_PROBE": "1"},
    "rooms": {"ROCK_CLOUD_LIVE_TEST": "1"},
    "continuation": {"ROCK_NATIVE_CONTINUATION_LIVE_TEST": "1"},
}
environment = target.setdefault("EnvironmentVariables", {})
for key in ("ROCK_NATIVE_CLOUD_ACCOUNT_PROBE", "ROCK_CLOUD_LIVE_TEST", "ROCK_NATIVE_CONTINUATION_LIVE_TEST", "ROCK_CLOUD_TEST_MARKER", "ROCK_CLOUD_TEST_PHASE"):
    environment.pop(key, None)
environment.update(flags.get(args.mode, {"ROCK_CLOUD_LIVE_TEST": "1", "ROCK_CLOUD_TEST_MARKER": args.marker, "ROCK_CLOUD_TEST_PHASE": args.mode}))
method = {"baseline": "testSignedAccountBaseline", "continuation": "testContinuationClaimsTransitionsAndReplacementWithdrawal"}.get(args.mode, "testEncryptedCloudRoundtrip")
selector = "NativeDesktopTests/NativeCloudServiceTests/" + method
target["OnlyTestIdentifiers"] = ["NativeCloudServiceTests/" + method]
target.pop("SkipTestIdentifiers", None)
evidence = args.output_dir.resolve()
evidence.mkdir(parents=True, exist_ok=False)
runfile = evidence / "cloud.xctestrun"
runfile.write_bytes(plistlib.dumps(data))
(evidence / "preflight.json").write_text(json.dumps({
    "mode": args.mode, "marker": args.marker, "host": str(host),
    "bundleIdentifier": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
    "build": info["CFBundleVersion"], "executableSHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "cloudEnvironment": "Production", "container": container, "test": selector,
}, indent=2) + "\n")
command = ["xcodebuild", "test-without-building", "-xctestrun", str(runfile), "-destination", "platform=macOS,arch=arm64",
           "-parallel-testing-enabled", "NO", "-only-testing:" + selector, "-resultBundlePath", str(evidence / "CloudServices.xcresult")]
with (evidence / "test.log").open("w") as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
        env=dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"))
print(f"Cloud {args.mode}: exit={result.returncode}; evidence={evidence}")
raise SystemExit(result.returncode)
