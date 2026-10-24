#!/usr/bin/env python3
"""Prepare an isolated, pinned LiveKit SDK using the native desktop M156 framework."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess


SDK_REVISION = "57a84d71c33e97349963c1cbd442fb4b01428b7c"
REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
MANIFEST_DEPENDENCY = '.package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "150.7871.02")'


def git(source, *arguments):
    return subprocess.check_output(["git", "-C", str(source), *arguments], text=True).strip()


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def prepare(source, framework, destination):
    source, framework, destination = source.resolve(), framework.resolve(), destination.resolve()
    if not source.is_dir():
        raise SystemExit(f"Supply --source with a clean LiveKit checkout at {SDK_REVISION}; missing {source}")
    revision = git(source, "rev-parse", "HEAD")
    if revision != SDK_REVISION:
        raise SystemExit(f"LiveKit SDK must be at {SDK_REVISION}; found {revision}")
    if git(source, "status", "--porcelain", "--untracked-files=all"):
        raise SystemExit("The source LiveKit checkout has local changes; use a clean source checkout.")
    manifests = {path.name: path.read_text() for path in source.glob("Package*.swift")}
    if not manifests or any(value.count(MANIFEST_DEPENDENCY) != 1 for value in manifests.values()):
        raise SystemExit("Pinned LiveKit manifests have an unexpected WebRTC dependency.")
    info = plistlib.loads((framework / "Info.plist").read_bytes())
    libraries = info.get("AvailableLibraries", [])
    mac = [entry for entry in libraries if entry.get("SupportedPlatform") == "macos" and
           "arm64" in entry.get("SupportedArchitectures", [])]
    if len(mac) != 1:
        raise SystemExit("Expected exactly one native arm64 macOS framework slice.")
    binary = framework / mac[0]["LibraryIdentifier"] / mac[0]["LibraryPath"] / "LiveKitWebRTC"
    marker = {"schema": 1, "sdk_revision": revision, "framework": str(framework),
              "framework_sha256": digest(binary), "source_package_sha256": digest(source / "Package.swift")}
    destination.mkdir(parents=True, exist_ok=True)
    sdk = destination / "client-sdk-swift"
    marker_path = destination / "native-livekit.json"
    if sdk.exists():
        if not marker_path.exists() or json.loads(marker_path.read_text()) != marker:
            raise SystemExit(f"Refusing to overwrite an unrelated or stale SDK copy: {sdk}")
    else:
        shutil.copytree(source, sdk, ignore=shutil.ignore_patterns(".git", ".build", ".swiftpm", ".DS_Store"))
        marker_path.write_text(json.dumps(marker, indent=2) + "\n")
    # SwiftPM selects a version-specific manifest on recent toolchains.
    for name, original in manifests.items():
        path = sdk / name
        dependency_patch = original.replace(MANIFEST_DEPENDENCY, '.package(path: "../webrtc-xcframework")')
        patched = dependency_patch.replace(".macOS(.v10_15)", ".macOS(.v13)")
        if path.read_text() not in (original, dependency_patch, patched):
            raise SystemExit(f"Refusing to replace local changes to SDK manifest: {path}")
        if path.read_text() != patched:
            path.chmod(0o644)
            path.write_text(patched)
    wrapper = destination / "webrtc-xcframework"
    wrapper.mkdir(exist_ok=True)
    link = wrapper / "LiveKitWebRTC.xcframework"
    if link.is_symlink():
        if link.resolve() != framework:
            raise SystemExit(f"Refusing to change another framework link: {link}")
    elif link.exists():
        raise SystemExit(f"Refusing to overwrite an existing framework: {link}")
    else:
        link.symlink_to(framework, target_is_directory=True)
    wrapper_manifest = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "LiveKitWebRTC", platforms: [.macOS(.v13)],
    products: [.library(name: "LiveKitWebRTC", targets: ["LiveKitWebRTC"])],
    targets: [.binaryTarget(name: "LiveKitWebRTC", path: "LiveKitWebRTC.xcframework")])
'''
    wrapper_path = wrapper / "Package.swift"
    if wrapper_path.exists() and wrapper_path.read_text() != wrapper_manifest:
        raise SystemExit(f"Refusing to replace local changes to the WebRTC wrapper: {wrapper_path}")
    if not wrapper_path.exists():
        wrapper_path.write_text(wrapper_manifest)
    print(json.dumps({"livekit_package": str(sdk), "webrtc_package": str(wrapper), **marker}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=pathlib.Path, default=REPOSITORY / ".build/native-mac-guest-m156/HostDerivedData/SourcePackages/checkouts/client-sdk-swift")
    parser.add_argument("--framework", type=pathlib.Path, default=REPOSITORY / ".build/webrtc-m156-port/native-framework/LiveKitWebRTC.xcframework")
    parser.add_argument("--destination", type=pathlib.Path, default=REPOSITORY / ".build/native-desktop-dependencies")
    options = parser.parse_args()
    prepare(options.source, options.framework, options.destination)
