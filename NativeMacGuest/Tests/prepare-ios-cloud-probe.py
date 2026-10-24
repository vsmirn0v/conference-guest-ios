#!/usr/bin/env python3
"""Build a separate Production CloudKit test app; never install or launch it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output-dir", type=Path, required=True)
parser.add_argument("--marker", required=True)
parser.add_argument("--phase", choices=("write", "reorder", "verify"), default="reorder")
args = parser.parse_args()
try:
    uuid.UUID(args.marker)
except ValueError:
    parser.error("--marker must be a generated UUID")
root = Path(__file__).resolve().parents[2]
evidence = args.output_dir.resolve()
evidence.mkdir(parents=True, exist_ok=False)
bundle_id = "dev.vsmirn0v.conferenceguest.cloudprobe"
entitlements = {"com.apple.developer.icloud-container-identifiers": ["iCloud.dev.vsmirn0v.conferenceguest"],
                "com.apple.developer.icloud-container-environment": "Production",
                "com.apple.developer.icloud-services": ["CloudKit"]}
(evidence / "CloudProbe.entitlements").write_bytes(plistlib.dumps(entitlements))
(evidence / "project.yml").write_text(f'''name: CloudProbe
options:
  deploymentTarget:
    iOS: '16.0'
packages:
  ConferenceCore:
    path: {root / 'ConferenceCore'}
targets:
  CloudProbe:
    type: application
    platform: iOS
    sources:
      - path: {root / 'NativeMacGuest/Tests/CloudProbeApp.swift'}
      - path: {root / 'RockNRoll/CloudRoomTransport.swift'}
    dependencies:
      - package: ConferenceCore
    scheme:
      testTargets: [CloudProbeTests]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: {bundle_id}
        PRODUCT_MODULE_NAME: RockNRoll
        DEVELOPMENT_TEAM: 5V64BP2H3P
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_ENTITLEMENTS: {evidence / 'CloudProbe.entitlements'}
        GENERATE_INFOPLIST_FILE: YES
        MARKETING_VERSION: '0.1'
        CURRENT_PROJECT_VERSION: '1'
        SWIFT_VERSION: '5.0'
        TARGETED_DEVICE_FAMILY: '1,2'
        INFOPLIST_KEY_CFBundleDisplayName: 'Cloud QA probe'
        SUPPORTED_PLATFORMS: iphoneos
        ARCHS: arm64
  CloudProbeTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: {root / 'RockNRollTests/CloudRoomTransportLiveTests.swift'}
    dependencies:
      - target: CloudProbe
      - package: ConferenceCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: {bundle_id}.tests
        PRODUCT_MODULE_NAME: RockNRollTests
        DEVELOPMENT_TEAM: 5V64BP2H3P
        CODE_SIGN_STYLE: Automatic
        GENERATE_INFOPLIST_FILE: YES
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/CloudProbe.app/CloudProbe
        BUNDLE_LOADER: $(TEST_HOST)
        SWIFT_VERSION: '5.0'
''')
environment = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
subprocess.run(["xcodegen", "generate", "--spec", str(evidence / "project.yml"), "--project", str(evidence)], check=True, env=environment)
with (evidence / "build.log").open("w") as log:
    result = subprocess.run(["xcodebuild", "-project", str(evidence / "CloudProbe.xcodeproj"), "-scheme", "CloudProbe",
        "-configuration", "Debug", "-destination", "generic/platform=iOS", "-derivedDataPath", str(evidence / "Xcode"),
        "-jobs", "4", "-allowProvisioningUpdates", "build-for-testing"], stdout=log, stderr=subprocess.STDOUT, env=environment)
if result.returncode:
    raise SystemExit(f"Cloud probe build failed ({result.returncode}); inspect {evidence / 'build.log'}")
products = evidence / "Xcode/Build/Products"
host = products / "Debug-iphoneos/CloudProbe.app"
signed = plistlib.loads(subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(host)], stderr=subprocess.DEVNULL))
if (signed.get("com.apple.developer.icloud-container-environment") != "Production" or
    signed.get("com.apple.developer.icloud-container-identifiers") != entitlements["com.apple.developer.icloud-container-identifiers"] or
    signed.get("application-identifier") != "5V64BP2H3P." + bundle_id):
    raise SystemExit("Signed cloud probe identity/environment differs from the isolated Production request")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(host)], check=True)
profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(host / "embedded.mobileprovision")], stderr=subprocess.DEVNULL))
profile_entitlements = profile["Entitlements"]
environments = profile_entitlements.get("com.apple.developer.icloud-container-environment", [])
if ("Production" not in environments or profile_entitlements.get("application-identifier") != signed["application-identifier"] or
    profile_entitlements.get("com.apple.developer.icloud-container-identifiers") != signed["com.apple.developer.icloud-container-identifiers"]):
    raise SystemExit("Provisioning profile does not authorize the isolated signed Production container")
runfiles = list(products.glob("*.xctestrun"))
if len(runfiles) != 1:
    raise SystemExit("Expected exactly one cloud probe xctestrun")
run = plistlib.loads(runfiles[0].read_bytes())
target = run["CloudProbeTests"]
target["EnvironmentVariables"].update({"ROCK_CLOUD_LIVE_TEST": "1", "ROCK_CLOUD_TEST_MARKER": args.marker, "ROCK_CLOUD_TEST_PHASE": args.phase})
target["OnlyTestIdentifiers"] = ["CloudRoomTransportLiveTests/testEncryptedCloudRoundtrip"]
prepared = products / "cloud-probe-isolated.xctestrun"
prepared.write_bytes(plistlib.dumps(run))
receipt = {"bundleIdentifier": bundle_id, "host": str(host), "xctestrun": str(prepared), "marker": args.marker, "phase": args.phase,
    "cloudEnvironment": signed["com.apple.developer.icloud-container-environment"], "profileUUID": profile["UUID"],
    "profileExpires": str(profile["ExpirationDate"]), "profileCloudEnvironments": profile["Entitlements"].get("com.apple.developer.icloud-container-environment"),
    "sources": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in
        [root / "NativeMacGuest/Tests/CloudProbeApp.swift", root / "RockNRoll/CloudRoomTransport.swift", root / "RockNRollTests/CloudRoomTransportLiveTests.swift", root / "ConferenceCore/Package.swift"] + sorted((root / "ConferenceCore/Sources").rglob("*.swift"))},
    "binariesSHA256": {str(p.relative_to(host)): hashlib.sha256(p.read_bytes()).hexdigest() for p in
        [host / "CloudProbe", host / "CloudProbe.debug.dylib", host / "PlugIns/CloudProbeTests.xctest/CloudProbeTests"]},
    "installedOrLaunched": False}
(evidence / "preparation.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt, indent=2))
