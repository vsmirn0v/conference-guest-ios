#!/usr/bin/env python3
"""Provision the pinned sherpa-onnx runtime as a local static xcframework.

Only release binaries whose SHA-256 matches Dependencies/native-macos/sherpa-onnx.lock.json
are used. The merged static library and C header become
Dependencies/SherpaOnnxKit/Artifacts/CSherpaOnnx.xcframework (not committed), which the
SherpaOnnxKit package links. Nothing executable is downloaded at app run time.
"""
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
LOCK = REPOSITORY / "Dependencies/native-macos/sherpa-onnx.lock.json"
CACHE = REPOSITORY / ".build/sherpa-onnx-cache"


def sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch(item):
    target = CACHE / pathlib.PurePosixPath(item["url"]).name
    if not target.exists() or sha256(target) != item["sha256"]:
        CACHE.mkdir(parents=True, exist_ok=True)
        partial = target.with_suffix(target.suffix + ".part")
        with urllib.request.urlopen(item["url"]) as response, partial.open("wb") as out:
            shutil.copyfileobj(response, out)
        if sha256(partial) != item["sha256"]:
            raise SystemExit(f"{target.name} does not match its pinned SHA-256")
        partial.replace(target)
    return target


def evidence_matches(destination, lock):
    evidence = destination.parent / "evidence.json"
    if not destination.is_dir() or not evidence.exists():
        return False
    recorded = json.loads(evidence.read_text())
    library = destination / "macos-arm64/libCSherpaOnnx.a"
    return (recorded.get("archive") == lock["archive"]["sha256"] and recorded.get("header") == lock["header"]["sha256"]
            and library.exists() and sha256(library) == recorded.get("library"))


def main():
    lock = json.loads(LOCK.read_text())
    destination = REPOSITORY / lock["destination"]
    if evidence_matches(destination, lock):
        print(f"sherpa-onnx {lock['version']} ready: {destination.relative_to(REPOSITORY)}")
        return 0
    archive, header = fetch(lock["archive"]), fetch(lock["header"])
    with tempfile.TemporaryDirectory(prefix="sherpa-onnx-") as scratch:
        scratch = pathlib.Path(scratch)
        with tarfile.open(archive) as tar:
            tar.extractall(scratch, filter="data")
        libraries = [next(scratch.rglob(name)) for name in lock["libraries"]]
        merged = scratch / "libCSherpaOnnx.a"
        subprocess.run(["libtool", "-static", "-no_warning_for_no_symbols", "-o", str(merged), *map(str, libraries)], check=True)
        headers = scratch / "Headers"
        headers.mkdir()
        shutil.copy2(header, headers / "c-api.h")
        (headers / "module.modulemap").write_text(
            'module CSherpaOnnx {\n    header "c-api.h"\n    link "c++"\n    export *\n}\n')
        if destination.exists():
            shutil.rmtree(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["xcodebuild", "-create-xcframework", "-library", str(merged), "-headers", str(headers),
                        "-output", str(destination)], check=True, stdout=subprocess.DEVNULL)
    library = destination / "macos-arm64/libCSherpaOnnx.a"
    (destination.parent / "evidence.json").write_text(json.dumps({
        "version": lock["version"], "archive": lock["archive"]["sha256"], "header": lock["header"]["sha256"],
        "library": sha256(library)}, indent=2) + "\n")
    print(f"sherpa-onnx {lock['version']} prepared: {destination.relative_to(REPOSITORY)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
