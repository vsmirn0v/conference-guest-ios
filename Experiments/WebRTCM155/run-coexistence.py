#!/usr/bin/env python3
"""Compile/load both Mac SDK namespaces and reject Objective-C class collisions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("guest", type=Path)
parser.add_argument("prefixed", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
guest, prefixed, out = (p.resolve() for p in (args.guest, args.prefixed, args.output))
if out.exists():
    raise SystemExit("Output already exists")
out.mkdir(parents=True)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
binaries = [guest / "WebRTC", prefixed / "LiveKitWebRTC"]
def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()
identities = {str(p): digest(p) for p in binaries}
def classes(p):
    output = subprocess.check_output(["xcrun", "nm", "-a", str(p)], env=env, text=True)
    prefix = "_OBJC_CLASS_$_"
    return {parts[-1][len(prefix):] for line in output.splitlines()
            if (parts := line.split()) and parts[-1].startswith(prefix) and "U" not in parts[:-1]}
collisions = sorted(classes(binaries[0]) & classes(binaries[1]))
if collisions:
    raise SystemExit(f"Objective-C class collisions: {collisions}")
cmd = ["xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macos13.0",
       "-F", str(guest.parent), "-F", str(prefixed.parent), "-framework", "WebRTC",
       "-framework", "LiveKitWebRTC", "-Xlinker", "-rpath", "-Xlinker", str(guest.parent),
       "-Xlinker", "-rpath", "-Xlinker", str(prefixed.parent),
       str(Path(__file__).with_name("CoexistenceProbe.swift")), "-o", str(out / "probe")]
with (out / "compile.log").open("w") as log:
    subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
result = subprocess.run([str(out / "probe")], env=env, capture_output=True, text=True, timeout=20)
(out / "runtime.log").write_text(result.stdout + result.stderr)
if result.returncode or "implemented in both" in result.stderr:
    raise SystemExit("Coexistence probe failed; see runtime.log")
if any(digest(Path(p)) != value for p, value in identities.items()):
    raise SystemExit("Framework changed during test")
(out / "result.json").write_text(json.dumps({"passed": True, "frameworks": identities,
    "class_collisions": collisions, "runtime": result.stdout.strip()}, indent=2) + "\n")
print(result.stdout.strip())
