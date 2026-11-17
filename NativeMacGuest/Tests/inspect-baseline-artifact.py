#!/usr/bin/env python3
"""Inventory an existing app and available build evidence without modifying them.

Only app-relative paths, sanitized dynamic links, package identities, and hashes are
recorded. Static code cannot be ruled out solely from these observations.
"""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess

MAGIC = {bytes.fromhex(v) for v in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca",
    "cafebabf", "bfbafeca")}


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def safe_link(value):
    if value.startswith(("@rpath/", "@loader_path/", "@executable_path/", "/System/Library/", "/usr/lib/")):
        return value
    if value.startswith("/"):
        return "<external>/" + pathlib.PurePosixPath(value).name
    return value


def links(path):
    result = subprocess.run(["/usr/bin/otool", "-L", str(path)], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        return {"status": "failed", "libraries": []}
    # Exclude the first line, which may contain an absolute local path.
    lines = result.stdout.splitlines()[1:]
    return {"status": "pass", "libraries": [safe_link(line.strip().split(" (compatibility version", 1)[0])
                                                for line in lines if line.strip()]}


def inspect_app(root):
    entries = []
    for directory, names, files in os.walk(root, followlinks=False):
        names.sort(); files.sort()
        base = pathlib.Path(directory)
        for name in names + files:
            path = base / name
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                target = os.readlink(path)
                entries.append({"path": rel, "kind": "symlink", "target": safe_link(target)})
            elif path.is_dir():
                entries.append({"path": rel, "kind": "directory"})
            elif path.is_file():
                with path.open("rb") as stream:
                    is_macho = stream.read(4) in MAGIC
                item = {"path": rel, "kind": "file", "size": path.stat().st_size, "sha256": digest(path)}
                if is_macho:
                    item["macho"] = links(path)
                entries.append(item)
            else:
                entries.append({"path": rel, "kind": "other"})
    return entries


def inspect_lock(path):
    if not path:
        return None
    data = json.loads(path.read_text())
    return {"sha256": digest(path), "pins": [{"identity": p.get("identity"), "kind": p.get("kind"),
                                                "state": p.get("state")} for p in data.get("pins", [])]}


def inspect_link_lists(root):
    if not root:
        return None
    # Hash files themselves, not build-machine paths they contain. Their existence
    # proves only which lists were available, not a full static dependency audit.
    lists = sorted(root.rglob("*.LinkFileList"))
    return [{"path": p.relative_to(root).as_posix(), "sha256": digest(p),
             "lineCount": len(p.read_bytes().splitlines())} for p in lists if p.is_file()]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--app", type=pathlib.Path, required=True)
    p.add_argument("--package-lock", type=pathlib.Path)
    p.add_argument("--link-dir", type=pathlib.Path)
    p.add_argument("--label", default="unspecified")
    p.add_argument("--source-revision", default="unknown")
    p.add_argument("--output", type=pathlib.Path, required=True)
    args = p.parse_args()
    root = args.app.resolve(strict=True)
    if not root.is_dir() or not (root / "Contents/Info.plist").is_file():
        p.error("--app must be a macOS app bundle")
    if args.output.resolve().is_relative_to(root):
        p.error("output must be outside the inspected app")
    if args.package_lock and args.output.resolve() == args.package_lock.resolve():
        p.error("output must not overwrite the package lock")
    if args.link_dir and args.output.resolve().is_relative_to(args.link_dir.resolve()):
        p.error("output must be outside the inspected build evidence")
    info = plistlib.loads((root / "Contents/Info.plist").read_bytes())
    manifest = {
        "schemaVersion": 1,
        "label": args.label,
        "sourceRevision": args.source_revision,
        "app": {"bundleID": info.get("CFBundleIdentifier"), "version": info.get("CFBundleShortVersionString"),
                "build": info.get("CFBundleVersion"), "entries": inspect_app(root)},
        "packageLock": inspect_lock(args.package_lock),
        "linkFileLists": inspect_link_lists(args.link_dir),
        "limitations": [
            "Dynamic libraries are observed with otool -L for each recognized Mach-O file; tool failures are explicit.",
            "Hashes and dependency names do not prove that prohibited SDK code is absent or identify statically linked source.",
            "Link-file-list hashes and package pins are build evidence, not proof that every static object was audited or linked.",
            "Symlinks are inventoried without following directory symlinks; code signature, extended attributes and timestamps are not checked."
        ]
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    failures = [e["path"] for e in manifest["app"]["entries"] if e.get("macho", {}).get("status") == "failed"]
    print(f"Inventoried {len(manifest['app']['entries'])} entries; {len(failures)} Mach-O link inspection failures")
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
