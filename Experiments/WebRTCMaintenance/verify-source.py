#!/usr/bin/env python3
"""Verify an isolated M150 candidate without weakening shipping verifiers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent


def verify(source, flavor, baseline=False):
    lock = json.loads((ROOT / "maintenance-lock.json").read_text())
    source = Path(source).resolve(strict=True)
    head = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if head != lock["base_source_sha"]:
        raise RuntimeError("Unexpected source revision")
    patches = []
    if flavor == "prefixed":
        patches.append(REPO / lock["prefix_patch"])
    for series in ("hybrid_patches", "guest_patches"):
        locked = [REPO / path for path in lock[series]]
        actual = sorted(locked[0].parent.glob("0*.patch"))
        if actual != locked:
            raise RuntimeError(f"Patch series changed: {series}")
    patches.extend(REPO / path for path in lock["hybrid_patches"])
    if flavor == "guest":
        patches.extend(REPO / path for path in lock["guest_patches"])
    if not baseline:
        patches.extend(ROOT / item["patch"] for item in lock["maintenance"])
        if flavor == "prefixed":
            patches.append(ROOT / "patches/upstream-test-target.patch")
    for patch in patches:
        relative = str(patch.relative_to(REPO))
        if hashlib.sha256(patch.read_bytes()).hexdigest() != lock["patch_sha256"][relative]:
            raise RuntimeError(f"Patch identity changed: {relative}")
    with tempfile.TemporaryDirectory(prefix="rock-maintenance-index-") as scratch:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(scratch) / "index"))
        def git(*args):
            return subprocess.check_output(["git", "-C", str(source), *args], env=env, text=True)
        git("read-tree", "HEAD")
        for patch in patches:
            git("apply", "--cached", str(patch))
        git("diff", "--exit-code", "--no-ext-diff")
        unexpected = git("ls-files", "--others", "--exclude-standard").splitlines()
        if unexpected:
            raise RuntimeError(f"Unexpected source files: {unexpected}")
    return {"base_source_sha": head, "flavor": flavor, "baseline": baseline,
            "patches": {str(p.relative_to(REPO)): lock["patch_sha256"][str(p.relative_to(REPO))]
                        for p in patches}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("flavor", choices=["guest", "prefixed"])
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    print(json.dumps(verify(args.source, args.flavor, args.baseline), indent=2))
