#!/usr/bin/env python3
"""Audit the pinned M155 source port and repair only its Mac control packaging."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
lock = json.loads((HERE / "m155-lock.json").read_text())
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("downloads", type=Path, help="Contains verified WebRTC.xcframework.zip and source.tar.gz")
parser.add_argument("output", type=Path, help="New, empty output path")
args = parser.parse_args()
downloads, output = args.downloads.resolve(), args.output.resolve()
def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()
for name, expected in [("WebRTC.xcframework.zip", lock["binary_archive_sha256"]),
                       ("source.tar.gz", lock["source_archive_sha256"])]:
    if digest(downloads / name) != expected:
        raise SystemExit(f"Archive identity mismatch: {name}")
output.mkdir(parents=True, exist_ok=False)
framework = output / "mac-control/WebRTC.framework"
# Extract only the trusted, digest-pinned Mac framework, retaining symlinks.
subprocess.run(["unzip", "-q", str(downloads / "WebRTC.xcframework.zip"),
    "WebRTC.xcframework/macos-arm64_x86_64/WebRTC.framework/*", "-d", str(output / "binary")], check=True)
original = output / "binary/WebRTC.xcframework/macos-arm64_x86_64/WebRTC.framework"
framework.parent.mkdir()
subprocess.run(["cp", "-cR", str(original), str(framework)], check=True)
if digest(framework / "WebRTC") != lock["mac_binary_sha256"]:
    raise SystemExit("Unexpected M155 Mac binary")
headers = framework / "Headers"
pending = re.findall(r'<WebRTC/([^>]+)>', (headers / "WebRTC.h").read_text())
done = {"WebRTC.h"}
repairs = []
with tarfile.open(downloads / "source.tar.gz") as archive:
    byname = {}
    for member in archive.getmembers():
        if "/sdk/objc/" in member.name and member.name.endswith(".h"):
            byname.setdefault(Path(member.name).name, []).append(member)
    while pending:
        name = pending.pop()
        if name in done:
            continue
        members = byname.get(name, [])
        if len(members) != 1 or Path(name).name != name:
            raise RuntimeError(f"Ambiguous or invalid public header: {name}")
        member = members[0]
        raw = archive.extractfile(member).read()
        # The GN framework export flattens these formal include paths too.
        exported = re.sub(r'(["<])sdk/objc/[^"<>]+/([^/"<>]+\.h)([">])', r'\1\2\3', raw.decode())
        (headers / name).write_text(exported)
        done.add(name)
        pending += re.findall(r'#(?:import|include) ["<]((?:RTC)[^/"<>]+\.h)[">]', exported)
        repairs.append({"name": name, "source": member.name, "source_sha256": hashlib.sha256(raw).hexdigest(),
                        "export_sha256": hashlib.sha256(exported.encode()).hexdigest()})
    source_root = output / "source"
    source_root.mkdir()
    archive.extractall(source_root, filter="data")
roots = list(source_root.iterdir())
if len(roots) != 1 or not roots[0].is_dir():
    raise RuntimeError("Unexpected source archive structure")
source = roots[0]
old_manifest = framework / "Versions/A/Versions/A/Resources/PrivacyInfo.xcprivacy"
shutil.copy2(old_manifest, framework / "Resources/PrivacyInfo.xcprivacy")
old_manifest.unlink()
shutil.copy2(source / "LICENSE", output / "mac-control/LICENSE")
if digest(framework / "WebRTC") != lock["mac_binary_sha256"]:
    raise RuntimeError("Control binary changed during packaging repair")
results = []
for series in ["WebRTCHybrid", "GuestSDKRebuild"]:
    for patch in sorted((REPO / "Experiments" / series / "patches").glob("0*.patch")):
        check = subprocess.run(["git", "-C", str(source), "apply", "--check", str(patch)], capture_output=True, text=True)
        if check.returncode == 0:
            subprocess.run(["git", "-C", str(source), "apply", str(patch)], check=True)
        results.append({"patch": str(patch.relative_to(REPO)), "sha256": digest(patch),
                        "applied": check.returncode == 0, "diagnostic": check.stderr.strip()})
(output / "evidence.json").write_text(json.dumps({"lock": lock, "header_repairs": repairs, "patch_trial": results,
    "scope": "Unmodified binary control; source port is incomplete. Failed patches may include prerequisites."}, indent=2) + "\n")
print(f"Restored {len(repairs)} headers; {sum(r['applied'] for r in results)}/{len(results)} patches applied")
