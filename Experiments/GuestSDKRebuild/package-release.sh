#!/bin/bash
set -euo pipefail
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="$(cd "${1:?Pass patched native source}" && pwd)"
framework_dir="$(cd "${2:?Pass assembled WebRTC.xcframework}" && pwd)"
output_dir="${3:?Pass immutable output directory}"
"$experiment_dir/package-notices.sh" "$source_dir" "$framework_dir"
python3 - "$framework_dir" "$output_dir" <<'PY'
import hashlib, json, os, pathlib, plistlib, stat, subprocess, sys, zipfile
framework, output = map(pathlib.Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
archive = output / 'WebRTC.xcframework.zip'
if archive.exists():
    raise SystemExit('Output archive already exists; use a fresh release directory')
metadata = plistlib.loads((framework / 'Info.plist').read_bytes())
metadata['AvailableLibraries'].sort(key=lambda item: item['LibraryIdentifier'])
(framework / 'Info.plist').write_bytes(plistlib.dumps(metadata, sort_keys=True))
for item in metadata['AvailableLibraries']:
    binary = framework / item['LibraryIdentifier'] / item['LibraryPath'] / 'WebRTC'
    symbols = subprocess.check_output(['nm', '-gU', str(binary)], text=True)
    if '_RTCSetConferencePlayoutReserved' not in symbols:
        raise SystemExit('Required conference output API is missing')
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as target:
    for path in sorted(framework.rglob('*')):
        if path.is_symlink():
            raise SystemExit(f'Unexpected symlink in portable iOS artifact: {path}')
        if not path.is_file():
            continue
        entry = zipfile.ZipInfo(path.relative_to(framework.parent).as_posix())
        entry.create_system = 3
        entry.compress_type = zipfile.ZIP_DEFLATED
        mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
        entry.external_attr = (stat.S_IFREG | mode) << 16
        target.writestr(entry, path.read_bytes())
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
(output / 'SHA256SUMS').write_text(f'{checksum}  {archive.name}\n')
(output / 'provenance.json').write_bytes((framework / 'Supporting/provenance.json').read_bytes())
print(checksum)
PY
