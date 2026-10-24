#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
framework_dir="$(cd "${1:?Pass a directory containing WebRTC.framework}" && pwd)"
platform="${2:?Expected mac or simulator}"
output="${3:?Pass a new output directory}"
[[ ! -e "$output" ]] || { echo "Output already exists" >&2; exit 1; }
mkdir -p "$output"
output="$(cd "$output" && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
module=WebRTC
swift_source="${ROCK_WEBRTC_PROBE_SOURCE:-$experiment_dir/MediaProbe.swift}"
source_input="$swift_source"
case "${ROCK_WEBRTC_API:-guest}" in
guest) ;;
prefixed)
  module=LiveKitWebRTC
  swift_source="$output/MediaProbe.swift"
  python3 - "$source_input" "$swift_source" <<'PY'
import pathlib,re,sys
text=pathlib.Path(sys.argv[1]).read_text().replace('import WebRTC','import LiveKitWebRTC')
# Only formal API identifiers are transformed; the tested logic is identical.
pathlib.Path(sys.argv[2]).write_text(re.sub(r'\bRTC[A-Za-z0-9_]*\b',lambda m:'LK'+m[0],text))
PY
  ;;
*) echo "Expected ROCK_WEBRTC_API=guest or prefixed" >&2; exit 1 ;;
esac
shasum -a 256 "$framework_dir/$module.framework/$module" > "$output/framework.sha256"
case "$platform" in
mac)
  xcrun --sdk macosx swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -F "$framework_dir" -framework "$module" \
    -Xlinker -rpath -Xlinker "$framework_dir" "$swift_source" -o "$output/probe"
  python3 - "$output" <<'PY'
import pathlib,subprocess,sys
out=pathlib.Path(sys.argv[1])
with (out/'result.json').open('wb') as result,(out/'runtime.log').open('wb') as log:
    process=subprocess.run([str(out/'probe')],stdout=result,stderr=log,timeout=50)
raise SystemExit(process.returncode)
PY
  ;;
simulator)
  device="${ROCK_SIMULATOR:?Pass an explicitly selected simulator UUID}"
  app="$output/Probe.app"
  mkdir -p "$app/Frameworks"
  cp -cR "$framework_dir/$module.framework" "$app/Frameworks/"
  xcrun --sdk iphonesimulator swiftc -O -parse-as-library -target arm64-apple-ios14.0-simulator \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -F "$framework_dir" -framework "$module" \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks "$swift_source" -o "$app/Probe"
  python3 - "$app/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
    plistlib.dump({'CFBundleIdentifier':'org.rocknroll.webrtcprobe','CFBundleExecutable':'Probe',
        'CFBundleName':'WebRTC isolated probe','CFBundleVersion':'1','CFBundleShortVersionString':'1.0',
        'CFBundlePackageType':'APPL','LSRequiresIPhoneOS':True,'MinimumOSVersion':'14.0',
        'UILaunchScreen':{},'UIDeviceFamily':[1,2],
        'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,
            'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[
                {'UISceneConfigurationName':'Default','UISceneDelegateClassName':'ProbeScene'}]}}},f)
PY
  codesign --force --sign - "$app/Frameworks/$module.framework" > "$output/sign.log" 2>&1
  codesign --force --sign - "$app" >> "$output/sign.log" 2>&1
  xcrun simctl install "$device" "$app"
  container="$(xcrun simctl get_app_container "$device" org.rocknroll.webrtcprobe data)"
  # A reused simulator may hold an earlier result; remove only this probe's file.
  rm -f "$container/Documents/result.json"
  xcrun simctl launch --terminate-running-process "$device" org.rocknroll.webrtcprobe > "$output/launch.log"
  trap 'xcrun simctl terminate "$device" org.rocknroll.webrtcprobe >/dev/null 2>&1 || true' EXIT
  python3 - "$container/Documents/result.json" "$output/result.json" <<'PY'
import pathlib,sys,time
source,out=map(pathlib.Path,sys.argv[1:]); deadline=time.monotonic()+50
while time.monotonic()<deadline:
    if source.exists():
        out.write_bytes(source.read_bytes()); break
    time.sleep(.25)
else: raise SystemExit('Probe timed out; no result was produced')
PY
  ;;
*) echo "Expected mac or simulator" >&2; exit 1 ;;
esac
shasum -a 256 -c "$output/framework.sha256"
python3 - "$output/result.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1])); assert result['passed'],result
for item in result['results']:
    print(item['requestedCodec'],item['frames'],item['sizes'])
PY
