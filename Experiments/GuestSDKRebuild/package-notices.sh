#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="$(cd "${1:?Pass patched native source}" && pwd)"
framework_dir="$(cd "${2:?Pass assembled WebRTC.xcframework}" && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
"$experiment_dir/verify-source.sh" "$source_dir"
python3 - "$source_dir" "$framework_dir" "$experiment_dir" <<'PY'
import hashlib
import html
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys

source, framework, experiment = map(pathlib.Path, sys.argv[1:])
supporting = framework / 'Supporting'
supporting.mkdir(exist_ok=True)
licenses = supporting / 'licenses'
licenses.mkdir(exist_ok=True)
notices = ['Modified WebRTC — WebRTC and linked third-party notices\n']
for name in ('LICENSE', 'PATENTS', 'AUTHORS'):
    shutil.copy2(source / name, licenses / name)
    notices.extend([f'\n===== WebRTC {name} =====\n', (source / name).read_text()])
slices = []
metadata = plistlib.loads((framework / 'Info.plist').read_bytes())
for item in metadata['AvailableLibraries']:
    if item['SupportedPlatform'] != 'ios' or item['SupportedArchitectures'] != ['arm64']:
        raise RuntimeError(f'Unexpected framework slice: {item}')
    environment = 'simulator' if item.get('SupportedPlatformVariant') == 'simulator' else 'device'
    output = source / f'out/rock-hybrid-ios-{environment}'
    license_dir = licenses / environment
    license_dir.mkdir(exist_ok=True)
    subprocess.run([sys.executable, str(source / 'tools_webrtc/libs/generate_licenses.py'),
                    '--target', '//sdk:framework_objc', str(license_dir), str(output)],
                   cwd=source, check=True)
    linked = (license_dir / 'LICENSE.md').read_text()
    if not linked.strip():
        raise RuntimeError(f'Empty linked notices: {environment}')
    notices.extend([f'\n===== {environment}: linked dependencies =====\n', html.unescape(linked)])
    binary = framework / item['LibraryIdentifier'] / item['LibraryPath'] / 'WebRTC'
    slices.append({'identifier': item['LibraryIdentifier'],
                   'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                   'gn_args': (output / 'args.gn').read_text()})
provenance = {
    'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip(),
    'vendor_wrapper_revision': '6d5f92869690fa22bb489a9089aa554d733c6936',
    'patches': [{'name': p.name, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                for p in sorted((experiment / 'patches').glob('*.patch'))],
    'slices': slices,
}
notice = supporting / 'GuestWebRTC-notices.txt'
notice.write_text('\n'.join(notices) + '\n')
manifest = supporting / 'provenance.json'
manifest.write_text(json.dumps(provenance, indent=2) + '\n')
for item in metadata['AvailableLibraries']:
    embedded = framework / item['LibraryIdentifier'] / item['LibraryPath']
    shutil.copy2(notice, embedded / notice.name)
    shutil.copy2(manifest, embedded / 'GuestWebRTC-provenance.json')
print(f'Embedded notices and source provenance in {framework}')
PY
