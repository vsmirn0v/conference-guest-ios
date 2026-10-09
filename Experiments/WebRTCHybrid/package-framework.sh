#!/bin/bash
set -euo pipefail
if [[ $# != 5 ]]; then
  echo "Usage: $0 sourceDir macOutput deviceOutput simulatorOutput outputDir" >&2
  exit 2
fi
experiment_dir="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
"$experiment_dir/verify-source.sh" "$1"
python3 - "$experiment_dir" "$@" <<'PY'
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


def run(*args, cwd=None):
    return subprocess.check_output([str(arg) for arg in args], cwd=cwd, text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def inventory(directory):
    result = {}
    for path in sorted(directory.rglob("*")):
        key = path.relative_to(directory).as_posix()
        if path.is_symlink():
            target = os.readlink(path)
            if Path(target).is_absolute() or not path.resolve().is_relative_to(directory.resolve()):
                raise RuntimeError(f"Nonportable symlink: {path} -> {target}")
            if not path.exists():
                raise RuntimeError(f"Broken symlink: {path} -> {target}")
            result[key] = {"symlink": target}
        elif path.is_file():
            result[key] = {"sha256": sha256(path), "executable": bool(path.stat().st_mode & 0o111)}
    return result


def archive(directory, destination):
    # Fixed ordering/timestamps make identical inputs produce the same checksum.
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        for path in sorted(directory.rglob("*")):
            relative = path.relative_to(directory.parent).as_posix()
            info = zipfile.ZipInfo(relative + ("/" if path.is_dir() and not path.is_symlink() else ""))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            if path.is_symlink():
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                data = os.readlink(path).encode()
            elif path.is_dir():
                info.external_attr = ((stat.S_IFDIR | 0o755) << 16) | 0x10
                data = b""
            else:
                mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                info.external_attr = (stat.S_IFREG | mode) << 16
                data = path.read_bytes()
            output.writestr(info, data, compresslevel=9)


def verify_build(path, target, platform):
    target = target.rsplit(":", 1)[-1]
    pending = run(ninja, "-C", path, "-n", target, cwd=source)
    if pending.splitlines()[-1:] == ["ninja: no work to do."]:
        return
    expected_steps = [
        "[1/2] SOLINK obj/sdk/LiveKitWebRTC obj/sdk/LiveKitWebRTC.TOC LiveKitWebRTC.unstripped",
        "[2/2] POST PROCESSING //sdk:framework_objc_signed_bundle(//build/toolchain/ios:ios_clang_arm64)",
    ]
    steps = [line for line in pending.splitlines() if not line.startswith("ninja: Entering directory ")]
    if platform != "ios" or steps != expected_steps or (path / "LiveKitWebRTC.unstripped").exists():
        raise RuntimeError(f"Build is not up to date: {path}\n{pending}")
    # The pinned iOS graph declares a transient .unstripped output that is absent
    # after a successful build.
    # Check an otherwise identical temporary graph without that output. Ninja
    # still checks all input mtimes, command/rspfile hashes, deps and bundle edges
    # against the original build log. Never touch the real manifests or outputs.
    with tempfile.TemporaryDirectory(prefix="native-ninja-check-") as temporary:
        scratch = Path(temporary)

        def replace_once(text, old, new):
            if text.count(old) != 1:
                raise RuntimeError("Unexpected Ninja graph; cannot verify consumed link output")
            return text.replace(old, new, 1)

        def ninja_path(path):
            return str(path).replace("$", "$$").replace(" ", "$ ").replace(":", "$:")

        link_path = "obj/sdk/framework_objc_shared_library.ninja"
        link = (path / link_path).read_text()
        link = replace_once(link,
            "build obj/sdk/LiveKitWebRTC obj/sdk/LiveKitWebRTC.TOC ./LiveKitWebRTC.unstripped: solink ",
            "build obj/sdk/LiveKitWebRTC obj/sdk/LiveKitWebRTC.TOC: solink ")
        (scratch / "link.ninja").write_text(link)
        toolchain = replace_once((path / "toolchain.ninja").read_text(),
            f"subninja {link_path}\n", f"subninja {ninja_path(scratch / 'link.ninja')}\n")
        (scratch / "toolchain.ninja").write_text(toolchain)
        main = replace_once((path / "build.ninja").read_text(),
            "subninja toolchain.ninja\n", f"subninja {ninja_path(scratch / 'toolchain.ninja')}\n")
        (scratch / "build.ninja").write_text(main)
        final_outputs = ("obj/sdk/LiveKitWebRTC", "LiveKitWebRTC.framework/LiveKitWebRTC")
        original_commands = run(ninja, "-C", path, "-t", "commands", "-s", *final_outputs)
        checked_commands = run(ninja, "-C", path, "-f", scratch / "build.ninja",
                               "-t", "commands", "-s", *final_outputs)
        if original_commands != checked_commands:
            raise RuntimeError("Temporary Ninja graph changed build commands")
        checked = run(ninja, "-C", path, "-f", scratch / "build.ninja", "-n", target, cwd=source)
        if checked.splitlines()[-1:] != ["ninja: no work to do."]:
            raise RuntimeError(f"Build is not up to date after checking consumed output: {path}\n{checked}")
    if sha256(path / final_outputs[0]) != sha256(path / final_outputs[1]):
        raise RuntimeError("Final unsigned iOS bundle binary differs from its linked binary")


experiment = Path(sys.argv[1]).resolve()
source = Path(sys.argv[2]).resolve(strict=True)
output = Path(sys.argv[6]).absolute()
if output.is_symlink():
    raise RuntimeError("Output must not be a symlink")
builds = [
    ("macos-arm64", Path(sys.argv[3]), "//sdk:mac_framework_bundle", "macos", None),
    ("ios-arm64", Path(sys.argv[4]), "//sdk:ios_framework_bundle", "ios", None),
    ("ios-arm64-simulator", Path(sys.argv[5]), "//sdk:ios_framework_bundle", "ios", "simulator"),
]
builds = [(name, (source / path).resolve(strict=True), target, platform, variant)
          for name, path, target, platform, variant in builds]
if len({path for _, path, _, _, _ in builds}) != 3:
    raise RuntimeError("Each slice must have a distinct GN output directory")
for _, path, _, _, _ in builds:
    if output.resolve().is_relative_to(path):
        raise RuntimeError("Packaging output must be outside all build directories")
lock_path = experiment / "build-lock.json"
lock = json.loads(lock_path.read_text())
if lock.get("schema_version") != 1 or not all(
    isinstance(lock.get(key), str) and lock[key]
    for key in ("upstream_version", "source_sha", "recipe_sha")
):
    raise RuntimeError("Unsupported or incomplete build-lock.json")
patches = [source.parent / "apple_prefix.patch", *sorted((experiment / "patches").glob("0*.patch"))]
generator = source / "tools_webrtc/libs/generate_licenses.py"
compiler = source / "third_party/llvm-build/Release+Asserts/bin/clang"
ninja = source / "third_party/ninja/ninja"
depot = source.parent / "depot_tools"
if depot.is_dir():
    os.environ["PATH"] = str(depot) + os.pathsep + os.environ["PATH"]
source_revision = run("git", "-C", source, "rev-parse", "HEAD")
if source_revision != lock["source_sha"]:
    raise RuntimeError("Source revision does not match build-lock.json")
patch_metadata = [{"name": path.name, "sha256": sha256(path)} for path in patches]
input_trees = {}
input_args = {}
for name, path, target, platform, _ in builds:
    verify_build(path, target, platform)
    framework = path / "LiveKitWebRTC.framework"
    input_trees[name] = inventory(framework)
    if not input_trees[name]:
        raise RuntimeError(f"Missing framework: {framework}")
    input_args[name] = (path / "args.gn").read_text()

output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix=f".{output.name}-", dir=output.parent) as temporary:
    staging = Path(temporary)
    release = staging / "release"
    release.mkdir()
    supporting = release / "Supporting"
    supporting.mkdir()
    license_root = supporting / "licenses"
    license_root.mkdir()
    for filename in ("LICENSE", "PATENTS", "AUTHORS"):
        shutil.copy2(source / filename, license_root / filename)
    shutil.copy2(lock_path, supporting / "build-lock.json")
    notices = ["LiveKitWebRTC — WebRTC and linked third-party notices\n"]
    for filename in ("LICENSE", "PATENTS", "AUTHORS"):
        notices.extend([f"\n===== WebRTC {filename} =====\n", (license_root / filename).read_text()])
    slices = []
    framework_arguments = []
    for name, path, target, platform, variant in builds:
        license_dir = license_root / name
        license_dir.mkdir()
        subprocess.run([sys.executable, str(generator), "--target", target,
                        str(license_dir), str(path)], cwd=source, check=True)
        license_text = (license_dir / "LICENSE.md").read_text()
        if not license_text.strip():
            raise RuntimeError(f"License generator produced no notices for {name}")
        notices.extend([f"\n===== {name}: linked dependencies =====\n", html.unescape(license_text)])
        gn_args = input_args[name]
        (supporting / f"{name}.args.gn").write_text(gn_args)
        # Work only on a copy. GN's macOS framework needs the same versioned
        # executable layout correction used by the pinned upstream packager.
        framework = staging / name / "LiveKitWebRTC.framework"
        shutil.copytree(path / "LiveKitWebRTC.framework", framework, symlinks=True)
        executable = framework / "LiveKitWebRTC"
        if platform == "macos" and not executable.is_symlink():
            versioned = framework / "Versions/A/LiveKitWebRTC"
            if not versioned.parent.is_dir() or versioned.exists():
                raise RuntimeError("Unexpected macOS framework layout; refusing to rewrite it")
            executable.rename(versioned)
            executable.symlink_to("Versions/Current/LiveKitWebRTC")
        if run("xcrun", "lipo", "-archs", executable) != "arm64":
            raise RuntimeError(f"Expected an ARM64-only binary for {name}")
        headers = list((framework / "Headers").glob("*.h"))
        if not any("vp9DecoderWithHardwareDecoder:" in header.read_text() for header in headers):
            raise RuntimeError(f"Missing public hybrid API in {name}")
        framework_arguments.extend(["-framework", str(framework)])
        slices.append({"identifier": name, "platform": platform, "variant": variant,
                       "architectures": ["arm64"], "gn_target": target,
                       "gn_args": gn_args, "binary_sha256": sha256(executable)})
    notice_path = supporting / "LiveKitWebRTC-notices.txt"
    notice_path.write_text("\n".join(notices) + "\n")
    xcframework = release / "LiveKitWebRTC.xcframework"
    subprocess.run(["xcodebuild", "-create-xcframework", *framework_arguments,
                    "-output", str(xcframework)], check=True)
    info = plistlib.loads((xcframework / "Info.plist").read_bytes())
    # Xcode discovers slices concurrently; normalize its variable array order.
    info["AvailableLibraries"].sort(key=lambda item: item["LibraryIdentifier"])
    (xcframework / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=True))
    actual = {(item["SupportedPlatform"], item.get("SupportedPlatformVariant"),
               tuple(item["SupportedArchitectures"])) for item in info["AvailableLibraries"]}
    expected = {(platform, variant, ("arm64",)) for _, _, _, platform, variant in builds}
    if actual != expected or len(info["AvailableLibraries"]) != 3:
        raise RuntimeError(f"Unexpected XCFramework slice metadata: {actual}")
    for item in info["AvailableLibraries"]:
        binary = xcframework / item["LibraryIdentifier"] / item["LibraryPath"] / "LiveKitWebRTC"
        original = next(value for value in slices if value["platform"] == item["SupportedPlatform"]
                        and value["variant"] == item.get("SupportedPlatformVariant"))
        if sha256(binary) != original["binary_sha256"]:
            raise RuntimeError(f"XCFramework assembly changed binary bytes: {binary}")
    toolchain = {
        "xcode": run("xcodebuild", "-version"),
        "source_clang": run(compiler, "--version"),
        "source_clang_sha256": sha256(compiler),
        "apple_clang": run("xcrun", "clang", "--version"),
        "sdks": {sdk: run("xcrun", "--sdk", sdk, "--show-sdk-version")
                 for sdk in ("macosx", "iphoneos", "iphonesimulator")},
    }
    provenance = {
        "schema_version": 1, "build_lock": lock,
        "build_lock_sha256": sha256(lock_path), "source_revision": source_revision,
        "patches_in_order": patch_metadata, "slices": slices,
        "tools_observed_at_packaging": toolchain,
        "license_generator_sha256": sha256(generator),
        "packaging_script_sha256": sha256(experiment / "package-framework.sh"),
        "supporting_files": inventory(supporting),
    }
    write_json(supporting / "provenance.json", provenance)
    # Include notices in each embedded framework, not only the outer archive.
    for item in info["AvailableLibraries"]:
        framework = xcframework / item["LibraryIdentifier"] / item["LibraryPath"]
        resource_dir = framework / "Resources" if item["SupportedPlatform"] == "macos" else framework
        if not resource_dir.exists():
            resource_dir.mkdir()
        shutil.copy2(notice_path, resource_dir / notice_path.name)
    shutil.copytree(supporting, xcframework / "Supporting", symlinks=True)
    inventory(xcframework)  # Reject escaping/broken symlinks before distribution.
    artifact = release / "LiveKitWebRTC.xcframework.zip"
    archive(xcframework, artifact)
    checksum = sha256(artifact)
    (release / "SHA256SUMS").write_text(f"{checksum}  {artifact.name}\n")
    # Detect inputs being replaced while this packaging run was in progress.
    for name, path, _, _, _ in builds:
        if inventory(path / "LiveKitWebRTC.framework") != input_trees[name]:
            raise RuntimeError(f"{name} changed during packaging")
        if (path / "args.gn").read_text() != input_args[name]:
            raise RuntimeError(f"{name} GN arguments changed during packaging")
    if sha256(lock_path) != provenance["build_lock_sha256"] or any(
        sha256(path) != item["sha256"] for path, item in zip(patches, patch_metadata)
    ):
        raise RuntimeError("Build lock or patch files changed during packaging")
    subprocess.run([str(experiment / "verify-source.sh"), str(source)], check=True)
    if output.exists():
        if inventory(output) != inventory(release):
            raise RuntimeError(f"Refusing to overwrite a different release: {output}")
        print(f"Existing release is identical: {output}")
    else:
        # Atomic installation; a concurrently created nonempty destination fails.
        release.rename(output)
        print(f"Packaged: {output}")
    print(f"SHA256 {checksum}  LiveKitWebRTC.xcframework.zip")
PY
