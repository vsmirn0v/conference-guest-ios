#!/usr/bin/env python3
"""Derive expected M155 content from the pinned archive plus cumulative patch.

Only a temporary Git object store/index is written; no source tree is copied.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile
import zlib

from source_tools import ARCHIVE_SHA256, SOURCE_SHA, archive_members, check_archive, digest


def make_manifest(archive_path, patch, output):
    check_archive(archive_path)
    patch = Path(patch).resolve(strict=True)
    patch_data = patch.read_bytes()
    output = Path(output)
    if output.exists() or output.is_symlink():
        raise ValueError(f"Manifest output already exists: {output}")
    original = {}
    with tempfile.TemporaryDirectory(prefix="m155-manifest-index-") as temporary:
        store = Path(temporary) / "objects.git"
        subprocess.run(["git", "init", "--bare", "--object-format=sha1", "-q", str(store)], check=True)
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update(GIT_DIR=str(store), GIT_INDEX_FILE=str(Path(temporary) / "index"))
        index = bytearray()
        with tarfile.open(archive_path) as archive:
            for name, member in archive_members(archive):
                if member.isdir():
                    continue
                data = os.fsencode(member.linkname) if member.issym() else archive.extractfile(member).read()
                mode = "120000" if member.issym() else ("100755" if member.mode & 0o111 else "100644")
                blob = b"blob " + str(len(data)).encode() + b"\0" + data
                oid = hashlib.sha1(blob).hexdigest()
                path = store / "objects" / oid[:2] / oid[2:]
                path.parent.mkdir(exist_ok=True)
                if not path.exists():
                    path.write_bytes(zlib.compress(blob))
                original[oid] = (hashlib.sha256(data).hexdigest(), data if member.issym() else None)
                index.extend(f"{mode} {oid}\t".encode() + os.fsencode(name) + b"\0")
        subprocess.run(["git", "update-index", "-z", "--index-info"],
                       input=index, env=env, check=True)
        subprocess.run(["git", "apply", "--cached"], input=patch_data, env=env, check=True)
        records = subprocess.check_output(["git", "ls-files", "--stage", "-z"], env=env)
        reader = subprocess.Popen(["git", "cat-file", "--batch"], env=env,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        entries = {}
        try:
            for record in records.split(b"\0"):
                if not record:
                    continue
                metadata, name_bytes = record.split(b"\t", 1)
                mode, oid, stage = metadata.decode().split()
                if stage != "0" or mode not in ("100644", "100755", "120000"):
                    raise ValueError(f"Unsupported index entry: {record!r}")
                name = os.fsdecode(name_bytes)
                known_hash, data = original.get(oid, (None, None))
                if known_hash is None or (mode == "120000" and data is None):
                    reader.stdin.write(oid.encode() + b"\n")
                    reader.stdin.flush()
                    header = reader.stdout.readline().split()
                    if len(header) != 3 or header[1] != b"blob":
                        raise ValueError(f"Invalid Git blob response: {header!r}")
                    size = int(header[2])
                    data = reader.stdout.read(size)
                    if len(data) != size or reader.stdout.read(1) != b"\n":
                        raise ValueError("Truncated Git blob")
                    known_hash = hashlib.sha256(data).hexdigest()
                entries[name] = ({"type": "symlink", "target": os.fsdecode(data)}
                                 if mode == "120000" else
                                 {"type": "file", "sha256": known_hash, "executable": mode == "100755"})
                for parent in PurePosixPath(name).parents:
                    if parent.as_posix() != ".":
                        entries[parent.as_posix()] = {"type": "directory"}
        finally:
            reader.stdin.close()
            reader.stdout.close()
            if reader.wait() != 0:
                raise ValueError("Git object reader failed")
    manifest = {"schema_version": 1, "source_sha": SOURCE_SHA,
                "source_archive_sha256": ARCHIVE_SHA256,
                "patch_sha256": hashlib.sha256(patch_data).hexdigest(),
                "entries": dict(sorted(entries.items()))}
    with output.open("x") as stream:
        stream.write(json.dumps(manifest, indent=2) + "\n")
    return {"path": str(output), "sha256": digest(output), "entries": len(entries)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    parser.add_argument("patch")
    parser.add_argument("output")
    args = parser.parse_args()
    print(json.dumps(make_manifest(args.archive, args.patch, args.output), indent=2))
