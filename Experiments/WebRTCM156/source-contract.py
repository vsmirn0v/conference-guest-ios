#!/usr/bin/env python3
"""Freeze or verify the isolated M156 source, without changing Git branches."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tarfile
import tempfile

COMMIT = "19576e37870bfe5a0a910a32f98ff411f722f43a"
ARCHIVE_SHA = "286d27e706ddd3d91de71526cf35e93ff962e71a0b3f7706a4d54b1c6bd4acd4"
PATCH_SHA = "4f542585a230981c430d5279895f6c148f7dff19c84169257b53a42df6fa1abb"
DEPS_SHA = "635421697f47f55b088894e147dd1e22115b2727edda9238b069419cffb6cc8e"
DEPENDENCY_ROOTS = {".landmines", "build", "buildtools", "ios", "out", "testing", "third_party", "tools"}


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def entries(root, exclude_dependencies=False):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("Source must be a real directory")
    output = {}

    def visit(directory):
        for path in sorted(directory.iterdir()):
            name = path.relative_to(root).as_posix()
            if name == ".git" or (exclude_dependencies and name in DEPENDENCY_ROOTS):
                continue
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                output[name] = {"kind": "link", "target": os.readlink(path)}
            elif stat.S_ISDIR(mode):
                output[name] = {"kind": "directory"}
                visit(path)
            elif stat.S_ISREG(mode):
                output[name] = {"kind": "file", "sha256": sha(path), "executable": bool(mode & 0o111)}
            else:
                raise ValueError(f"Unsupported entry: {name}")

    visit(root)
    return output


def check_inputs(archive, patch, deps):
    if sha(archive) != ARCHIVE_SHA or sha(patch) != PATCH_SHA or sha(deps) != DEPS_SHA:
        raise ValueError("Pinned M156 archive, guest patch or DEPS identity changed")


def freeze(archive, patch, deps, manifest, lock):
    check_inputs(archive, patch, deps)
    if manifest.exists() or lock.exists():
        raise ValueError("Freeze outputs must not exist")
    with tempfile.TemporaryDirectory(prefix="m156-source-contract-") as scratch:
        source = Path(scratch) / "src"
        source.mkdir()
        with tarfile.open(archive, "r:gz") as tar:
            tar.extractall(source, filter="data")
        subprocess.run(["git", "apply", "--check", str(patch)], cwd=source, check=True)
        subprocess.run(["git", "apply", str(patch)], cwd=source, check=True)
        contents = entries(source)
    manifest.write_text(json.dumps({"commit": COMMIT, "entries": contents}, sort_keys=True, indent=2) + "\n")
    lock.write_text(json.dumps({"commit": COMMIT, "archiveSHA256": ARCHIVE_SHA,
                                "patchSHA256": PATCH_SHA, "depsSHA256": DEPS_SHA,
                                "manifestSHA256": sha(manifest)},
                               sort_keys=True, indent=2) + "\n")


def verify(archive, patch, deps, manifest, lock, source):
    check_inputs(archive, patch, deps)
    identity = json.loads(lock.read_text())
    if identity != {"commit": COMMIT, "archiveSHA256": ARCHIVE_SHA,
                    "patchSHA256": PATCH_SHA, "depsSHA256": DEPS_SHA,
                    "manifestSHA256": sha(manifest)}:
        raise ValueError("M156 source lock mismatch")
    expected = json.loads(manifest.read_text())
    if expected.get("commit") != COMMIT or not expected.get("entries"):
        raise ValueError("M156 manifest mismatch")
    actual = entries(source, exclude_dependencies=True)
    if actual != expected["entries"]:
        missing = sorted(expected["entries"].keys() - actual.keys())[:10]
        extra = sorted(actual.keys() - expected["entries"].keys())[:10]
        changed = sorted(k for k in actual.keys() & expected["entries"].keys()
                         if actual[k] != expected["entries"][k])[:10]
        raise ValueError(f"Source mismatch: missing={missing} extra={extra} changed={changed}")
    return {"commit": COMMIT, "entries": len(actual), "manifestSHA256": sha(manifest)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["freeze", "verify"])
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--patch", type=Path, required=True)
    parser.add_argument("--deps", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--source", type=Path)
    args = parser.parse_args()
    archive, patch = args.archive.resolve(strict=True), args.patch.resolve(strict=True)
    deps = args.deps.resolve(strict=True)
    if args.mode == "freeze":
        freeze(archive, patch, deps, args.manifest, args.lock)
    else:
        if args.source is None:
            parser.error("--source is required for verify")
        print(json.dumps(verify(archive, patch, deps, args.manifest, args.lock, args.source), sort_keys=True))


if __name__ == "__main__":
    main()
