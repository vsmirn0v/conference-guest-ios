#!/usr/bin/env python3
"""Summarize SDK-related global symbols in a baseline inventory's Mach-O files.

This is positive evidence only. Stripped symbols, symbol renaming, ObjC/C++ code
and dynamically loaded code prevent it from proving any dependency is absent.
The app is read-only; raw symbol names and filesystem paths are not emitted.
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess


MODULES = ("LiveKit", "LiveKitWebRTC", "WebRTC", "JazzSDK", "JazzCore", "TrueConfSDK", "TelemostSDK")
SWIFT_MODULE = re.compile(r"\$s(\d+)([A-Za-z_][A-Za-z_0-9]*)")
OBJC_CLASS = re.compile(r"OBJC_(?:CLASS|METACLASS)_\$_([A-Za-z_][A-Za-z_0-9]*)")


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    root = args.app.resolve(strict=True)
    if args.output.resolve().is_relative_to(root) or args.output.resolve() == args.manifest.resolve():
        parser.error("output must not overwrite the app or manifest")
    manifest = json.loads(args.manifest.read_text())
    result = {"schemaVersion": 1, "manifestSHA256": sha256(args.manifest), "binaries": [],
              "limitations": [
                  "Global symbol counts provide positive evidence only; absent matches do not establish absence of SDK code.",
                  "Swift matching uses encoded module identifiers; Objective-C matching uses a small fixed class-prefix list.",
                  "This does not identify local/stripped symbols, static archives, licenses, runtime loads or all transitive sources."
              ]}
    for entry in manifest["app"]["entries"]:
        if "macho" not in entry:
            continue
        rel = pathlib.PurePosixPath(entry["path"])
        if rel.is_absolute() or ".." in rel.parts:
            raise ValueError("manifest has unsafe binary path")
        binary = root.joinpath(*rel.parts)
        if binary.is_symlink() or not binary.is_file() or sha256(binary) != entry["sha256"]:
            raise ValueError("app differs from manifest: " + str(rel))
        row = {"path": str(rel), "sha256": entry["sha256"], "scans": {}}
        for mode, option in (("definedExternal", "-gU"), ("undefinedExternal", "-u")):
            scan = subprocess.run(["/usr/bin/nm", option, str(binary)], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, errors="replace")
            counts = {k: 0 for k in MODULES}
            objc = {k: 0 for k in MODULES}
            for line in scan.stdout.splitlines():
                match = SWIFT_MODULE.search(line)
                if match:
                    module = match.group(2)[:int(match.group(1))]
                    if module in counts:
                        counts[module] += 1
                match = OBJC_CLASS.search(line)
                if match:
                    for module in MODULES:
                        if match.group(1).startswith(module):
                            objc[module] += 1
            row["scans"][mode] = {"status": "pass" if scan.returncode == 0 else "failed",
                                  "swiftModuleMatches": counts, "objcClassPrefixMatches": objc}
        result["binaries"].append(row)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    failures = sum(scan["status"] != "pass" for row in result["binaries"] for scan in row["scans"].values())
    print(f"Inspected {len(result['binaries'])} manifest-bound Mach-O files; {failures} scan failures")
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
