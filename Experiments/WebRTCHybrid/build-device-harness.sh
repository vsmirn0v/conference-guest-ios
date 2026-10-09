#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
framework_dir="${1:?Pass the directory containing the patched device LiveKitWebRTC.framework}"
device_id="${2:?Pass the authorized device UDID}"
output_dir="${3:-/tmp/rock-hybrid-device-harness}"
av1_fixture="${4:-}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$output_dir"
python3 - "$experiment_dir" "$framework_dir" "$output_dir" "$av1_fixture" <<'PY'
import json, sys
from pathlib import Path
experiment, framework, output = map(Path, sys.argv[1:4])
repo = experiment.parent.parent
sources = [experiment / name for name in ("Loopback.swift", "DeviceMain.swift")]
sources += [repo / "RockNRoll/NativeRTC" / name for name in ("VP9VideoFormat.swift", "VideoToolboxVP9Session.swift", "VP9HardwareDecoder.swift", "NativeVideoDecoderFactory.swift", "NativeVP9Hybrid.swift")]
sources += [experiment.parent / "TelemostNative" / name for name in ("Bootstrap.swift", "MediaPeer.swift", "SyntheticAudio.swift")]
sources.append(experiment.parent / "AV1Hardware/HardwareProbe.swift")
if sys.argv[4]:
    import shutil
    shutil.copyfile(sys.argv[4], output / "av1-fixture.json")
    sources.append(output / "av1-fixture.json")
spec = {"name": "HybridHarness", "options": {"deploymentTarget": {"iOS": "17.0"}}, "targets": {"HybridHarness": {
    "type": "application", "platform": "iOS", "sources": [{"path": str(path)} for path in sources],
    "dependencies": [{"framework": str(framework / "LiveKitWebRTC.framework"), "embed": True}],
    "info": {"path": str(output / "Info.plist"), "properties": {"CFBundleDisplayName": "VP9 Hybrid Check", "UILaunchScreen": {}, "NSLocalNetworkUsageDescription": "Runs a synthetic video codec check between local test peers."}},
    "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "dev.vsmirn0v.rocknroll.hybridharness", "DEVELOPMENT_TEAM": "5V64BP2H3P", "CODE_SIGN_STYLE": "Automatic", "SWIFT_VERSION": "5.0", "ENABLE_DEBUG_DYLIB": "NO"}}}}}
(output / "project.json").write_text(json.dumps(spec))
PY
xcodegen generate --spec "$output_dir/project.json" --project "$output_dir"
xcodebuild -project "$output_dir/HybridHarness.xcodeproj" -scheme HybridHarness -configuration Debug \
  -destination "id=$device_id" -derivedDataPath "$output_dir/DerivedData" -allowProvisioningUpdates build
