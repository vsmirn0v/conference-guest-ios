#!/usr/bin/env python3
"""APFS-clone an existing M150 build tree, canonicalize tests and apply maintenance."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("maintenance_verify", HERE / "verify-source.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("base", type=Path)
parser.add_argument("flavor", choices=["guest", "prefixed"])
parser.add_argument("output", type=Path, help="New workspace directory")
args = parser.parse_args()
base, output = args.base.resolve(strict=True), args.output.resolve()
if output == base or output.is_relative_to(base):
    raise SystemExit("Output must be outside the base source")
lock = json.loads((HERE / "maintenance-lock.json").read_text())
output.mkdir(parents=True, exist_ok=False)
source = output / "src"
subprocess.run(["cp", "-cR", str(base), str(source)], check=True)
# Some existing local build trees contained an unrelated gtest-in-XCTest
# adaptation. Undo only that exact known delta in our clone, never in the base.
revert = lock["preparation_only_revert"]
patch = HERE / revert["patch"]
if hashlib.sha256(patch.read_bytes()).hexdigest() != revert["sha256"]:
    raise SystemExit("Preparation patch identity mismatch")
check = subprocess.run(["git", "-C", str(source), "apply", "--reverse", "--check", str(patch)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if check.returncode == 0:
    subprocess.run(["git", "-C", str(source), "apply", "--reverse", str(patch)], check=True)
module.verify(source, args.flavor, baseline=True)
patches = [HERE / item["patch"] for item in lock["maintenance"]]
if args.flavor == "prefixed":
    patches.append(HERE / "patches/upstream-test-target.patch")
for patch in patches:
    relative = str(patch.relative_to(HERE.parent.parent))
    if hashlib.sha256(patch.read_bytes()).hexdigest() != lock["patch_sha256"][relative]:
        raise SystemExit(f"Maintenance patch identity mismatch: {relative}")
    subprocess.run(["git", "-C", str(source), "apply", str(patch)], check=True)
provenance = module.verify(source, args.flavor)
(output / "source-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
print(source)
