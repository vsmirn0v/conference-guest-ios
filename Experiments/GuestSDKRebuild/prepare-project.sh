#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$experiment_dir/../.." && pwd)"
source_dir="$(cd "${1:?Pass patched native source}" && pwd)"
vendor_dir="$(cd "${2:?Pass pinned vendor SDK checkout}" && pwd)"
output_dir="${3:-$repo_dir/.build/guest-sdk-experiment}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
"$experiment_dir/verify-source.sh" "$source_dir"
[[ "$(git -C "$vendor_dir" rev-parse HEAD)" == 6d5f92869690fa22bb489a9089aa554d733c6936 ]] || {
    echo "Vendor wrapper revision mismatch" >&2; exit 1;
}
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
sdk_dir="$output_dir/sdk/JazzSDK"
mkdir -p "$sdk_dir/Sources" "$output_dir/project"
if [[ -f "$sdk_dir/Package.swift" && ! -L "$sdk_dir/Package.swift" ]]; then chmod u+w "$sdk_dir/Package.swift"; fi
cp "$vendor_dir/Package.swift" "$sdk_dir/Package.swift"
for artifact in "$vendor_dir"/Sources/*; do
    name="$(basename "$artifact")"
    [[ "$name" != WebRTC.xcframework ]] || continue
    [[ -e "$sdk_dir/Sources/$name" ]] || ln -s "$artifact" "$sdk_dir/Sources/$name"
done
framework="$sdk_dir/Sources/WebRTC.xcframework"
if [[ -e "$framework" ]]; then
    mv "$framework" "$output_dir/WebRTC.previous-$(date +%s).xcframework"
fi
xcodebuild -create-xcframework \
    -framework "$source_dir/out/rock-hybrid-ios-device/WebRTC.framework" \
    -framework "$source_dir/out/rock-hybrid-ios-simulator/WebRTC.framework" \
    -output "$framework"
"$experiment_dir/package-notices.sh" "$source_dir" "$framework"
xcodegen dump --spec "$repo_dir/project.yml" --type json --file "$output_dir/base-spec.json"
python3 - "$repo_dir" "$output_dir" "$vendor_dir/Sources" <<'PY'
import json,pathlib,shlex,sys
repo,out,resources=map(pathlib.Path,sys.argv[1:])
spec=json.loads((out/'base-spec.json').read_text())
spec['name']='GuestSDKExperiment'
spec['packages']['JazzSDK']={'path':str(out/'sdk/JazzSDK')}
for package in spec['packages'].values():
    if 'path' in package: package['path']=str(repo/package['path'])
for target in spec['targets'].values():
    for source in target.get('sources',[]):
        source['path']=str(repo/source['path'])
    for dependency in target.get('dependencies',[]):
        if 'framework' in dependency: dependency['framework']=str(repo/dependency['framework'])
    for key,value in target.get('settings',{}).get('base',{}).items():
        if key in ['INFOPLIST_FILE','CODE_SIGN_ENTITLEMENTS','SWIFT_OBJC_BRIDGING_HEADER']:
            target['settings']['base'][key]=str(repo/value)
    for script in target.get('postBuildScripts',[]):
        if script.get('name')=='Copy provider SDK resources':
            script['script']='CONFERENCE_SDK_SOURCE_DIR='+shlex.quote(str(resources))+' bash '+shlex.quote(str(repo/'scripts/copy-sdk-resources.sh'))
(out/'project'/'project-spec.json').write_text(json.dumps(spec,indent=2)+'\n')
for name in ['RockNRoll','RockNRollTests','RockNRollUITests','RockBroadcast','GuestBroadcast','Shared','Experiments','scripts','ConferenceCore','Dependencies']:
    link=out/'project'/name
    if not link.exists(): link.symlink_to(repo/name,target_is_directory=True)
PY
xcodegen generate --spec "$output_dir/project/project-spec.json" --project "$output_dir/project"
echo "Experimental project: $output_dir/project/GuestSDKExperiment.xcodeproj"
