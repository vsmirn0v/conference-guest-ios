#!/usr/bin/env python3
"""Plan or run a completely local compile of the pinned LiveKit production SDK."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess

LIVEKIT = "57a84d71c33e97349963c1cbd442fb4b01428b7c"
UNIFFI = "7a9bf91b1601d5c408ae0cac7dc2047b5a4f615e"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def pinned(root, revision):
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=root)
    if actual != revision or dirty:
        raise ValueError(f"Expected clean pinned checkout at {revision}: {root}")


def tool(name, env):
    return subprocess.check_output(["xcrun", "--find", name], text=True, env=env).strip()


def prepare(args):
    env = dict(os.environ)
    if args.developer_dir:
        env["DEVELOPER_DIR"] = str(args.developer_dir.resolve(strict=True))
    packages = args.source_packages.resolve(strict=True)
    livekit = packages / "checkouts/client-sdk-swift"
    uniffi = packages / "checkouts/livekit-uniffi-xcframework"
    pinned(livekit, LIVEKIT)
    pinned(uniffi, UNIFFI)
    state_file = packages / "workspace-state.json"
    state = json.loads(state_file.read_text())["object"]
    deps = {d["packageRef"]["identity"]: d for d in state["dependencies"]}
    for name, revision in (("client-sdk-swift", LIVEKIT), ("livekit-uniffi-xcframework", UNIFFI)):
        if deps[name]["state"]["checkoutState"]["revision"] != revision:
            raise ValueError(f"Resolved workspace pin mismatch: {name}")
    rust_artifacts = [a for a in state["artifacts"] if a["targetName"] == "RustLiveKitUniFFI"]
    if len(rust_artifacts) != 1:
        raise ValueError("Expected exactly one locally resolved RustLiveKitUniFFI artifact")
    rust_root = Path(rust_artifacts[0]["path"]).resolve(strict=True)
    rust_info = rust_root / "Info.plist"
    libraries = plistlib.loads(rust_info.read_bytes())["AvailableLibraries"]
    platform = "macos" if args.platform == "macos" else "ios"
    variant = None if args.platform == "macos" else "simulator"
    slices = [x for x in libraries if x["SupportedPlatform"] == platform and
              x.get("SupportedPlatformVariant") == variant and "arm64" in x["SupportedArchitectures"]]
    if len(slices) != 1:
        raise ValueError("Expected one RustLiveKitUniFFI arm64 slice for this platform")
    rust = rust_root / slices[0]["LibraryIdentifier"] / slices[0]["LibraryPath"]
    webrtc = args.webrtc_framework.resolve()
    if webrtc.name != "LiveKitWebRTC.framework":
        raise ValueError("Pass the platform slice named LiveKitWebRTC.framework")
    out = args.output.resolve()
    protected = (packages, livekit, uniffi, rust_root, webrtc)
    if args.output.is_symlink() or any(out.is_relative_to(p) or p.is_relative_to(out) for p in protected):
        raise ValueError("Output must be separate from SDK and dependency trees")
    if out.is_dir() and any(p.is_symlink() for p in out.rglob("*")):
        raise ValueError("Compilation output must not contain symlinks")
    if args.execute and not (webrtc / "LiveKitWebRTC").is_file():
        raise ValueError("Build the prefixed LiveKitWebRTC framework before executing this harness")
    sdk_name = "macosx" if args.platform == "macos" else "iphonesimulator"
    sdk = subprocess.check_output(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True, env=env).strip()
    minimum = args.deployment_target or ("11.0" if args.platform == "macos" else "13.0")
    triple = (f"arm64-apple-macosx{minimum}" if args.platform == "macos" else
              f"arm64-apple-ios{minimum}-simulator")
    clang, swiftc, libtool = tool("clang", env), tool("swiftc", env), tool("libtool", env)
    commands, inputs = [], {str(state_file): digest(state_file), str(rust_info): digest(rust_info)}
    for root in (livekit, uniffi):
        paths = [root / "Package.swift"] + sorted(p for p in (root / "Sources").rglob("*") if p.is_file())
        inputs.update({str(p): digest(p) for p in paths})
    for framework in (rust, webrtc):
        if framework.is_dir():
            paths = sorted(p for p in framework.rglob("*") if p.is_file() and not p.is_symlink())
            inputs.update({str(p): digest(p) for p in paths})
    module_dir, library_dir = out / "Modules", out / "lib"
    common_c = [clang, "-target", triple, "-isysroot", sdk, "-g", "-O0", "-fmodules",
                "-fmodules-cache-path=" + str(out / "ClangModuleCache")]
    module_roots = [livekit / "Sources/CLiveKitProto", livekit / "Sources/LKObjCHelpers"]
    for name in ("CLiveKitProto", "LKObjCHelpers"):
        root, objects = livekit / "Sources" / name, []
        sources = sorted(p for p in root.rglob("*") if p.suffix in {".c", ".m"})
        if not sources:
            raise ValueError(f"No sources in {name}")
        for n, source in enumerate(sources):
            obj = out / "Objects" / name / f"{n}-{source.stem}.o"
            command = common_c + ["-I", str(root / "include")]
            if source.suffix == ".m":
                command += ["-fobjc-arc"]
            commands.append(command + ["-c", str(source), "-o", str(obj)])
            objects.append(str(obj))
        commands.append([libtool, "-static", "-o", str(library_dir / f"lib{name}.a")] + objects)
    common_swift = [swiftc, "-target", triple, "-sdk", sdk, "-Onone", "-g", "-D", "SWIFT_PACKAGE",
                    "-D", "DEBUG", "-parse-as-library", "-enable-batch-mode", "-j", str(args.jobs),
                    "-module-cache-path", str(out / "SwiftModuleCache"), "-I", str(module_dir),
                    "-L", str(library_dir), "-F", str(rust.parent), "-F", str(webrtc.parent)]
    for root in module_roots:
        common_swift += ["-I", str(root), "-Xcc", "-I" + str(root / "include")]
    targets = (("LiveKitUniFFI", uniffi, "5"), ("LiveKitNanopb", livekit, args.swift_version),
               ("LiveKit", livekit, args.swift_version))
    target_sources, output_maps = {}, {}
    for name, root, language in targets:
        sources = sorted((root / "Sources" / name).rglob("*.swift"))
        if not sources:
            raise ValueError(f"No Swift sources in {name}")
        target_sources[name] = [str(p) for p in sources]
        object_root = out / "Objects" / name
        output_map = object_root / "output-map.json"
        output_maps[str(output_map)] = {str(source): {"object": str(object_root / f"{n}-{source.stem}.o")}
                                        for n, source in enumerate(sources)}
        command = common_swift + ["-output-file-map", str(output_map)] + ["-swift-version", language, "-package-name", root.name.replace("-", "_"),
                                 "-module-name", name, "-emit-module", "-emit-module-path",
                                 str(module_dir / (name + ".swiftmodule")), "-emit-library"]
        if name != "LiveKit":
            command += ["-static", "-o", str(library_dir / ("lib" + name + ".a"))]
        else:
            command += ["-o", str(library_dir / "libLiveKit.dylib"), "-lLiveKitUniFFI", "-lLiveKitNanopb",
                        "-lCLiveKitProto", "-lLKObjCHelpers", "-framework", "LiveKitWebRTC",
                        "-framework", "RustLiveKitUniFFI", "-Xlinker", "-install_name", "-Xlinker",
                        "@rpath/libLiveKit.dylib", "-Xlinker", "-rpath", "-Xlinker", str(webrtc.parent)]
        commands.append(command + [str(p) for p in sources])
    return {"schema_version": 1, "source_packages": str(packages), "output": str(out),
            "platform": args.platform, "target_triple": triple, "swift_language_mode": args.swift_version,
            "developer_directory": env.get("DEVELOPER_DIR"), "sdk": sdk,
            "livekit_revision": LIVEKIT, "uniffi_revision": UNIFFI,
            "webrtc_framework": str(webrtc), "webrtc_framework_exists": webrtc.is_dir(),
            "rust_framework": str(rust), "inputs": inputs, "target_sources": target_sources,
            "commands": commands, "output_file_maps": output_maps,
            "excluded_dependencies": {"swift-protobuf": "test-only", "swift-docc-plugin": "documentation-only"},
            "scope": "Production source compilation and dynamic linking; no tests or resources packaging."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-packages", type=Path, required=True)
    parser.add_argument("--webrtc-framework", type=Path, required=True)
    parser.add_argument("--platform", choices=("macos", "ios-simulator"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift-version", choices=("5", "6"), default="6")
    parser.add_argument("--deployment-target")
    parser.add_argument("--developer-dir", type=Path, help="Use this Xcode without changing xcode-select")
    parser.add_argument("--jobs", type=int, choices=range(1, 9), default=2)
    parser.add_argument("--execute", action="store_true", help="Run compilers; otherwise only write the local command plan")
    args = parser.parse_args()
    plan = prepare(args)
    out = Path(plan["output"])
    out.mkdir(parents=True, exist_ok=True)
    (out / "compile-plan.json").write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    (out / "commands.sh").write_text("#!/bin/bash\nset -euo pipefail\n" +
                                      "\n".join(shlex.join(c) for c in plan["commands"]) + "\n")
    if args.execute:
        env = dict(os.environ)
        if plan["developer_directory"]:
            env["DEVELOPER_DIR"] = plan["developer_directory"]
        (out / "compile-result.json").unlink(missing_ok=True)
        for path in (out / "Modules", out / "lib", out / "Objects/CLiveKitProto", out / "Objects/LKObjCHelpers"):
            path.mkdir(parents=True, exist_ok=True)
        for name, mapping in plan["output_file_maps"].items():
            path = Path(name)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(mapping, indent=2) + "\n")
        for n, command in enumerate(plan["commands"]):
            print(f"[{n + 1}/{len(plan['commands'])}] {Path(command[0]).name}", flush=True)
            with (out / f"{n:02}-compiler.log").open("w") as log:
                completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=env)
                if completed.returncode:
                    raise SystemExit(f"Compiler step {n + 1} failed ({completed.returncode}); see {out / f'{n:02}-compiler.log'}")
        # A successful libtool exit alone can conceal missing temporary object
        # files. Persistent output maps plus member counts prove real codegen.
        archive_members = {}
        for name, minimum in (("CLiveKitProto", 8), ("LKObjCHelpers", 1),
                              ("LiveKitUniFFI", 3), ("LiveKitNanopb", 3)):
            archive = out / "lib" / f"lib{name}.a"
            members = subprocess.check_output([tool("ar", env), "-t", str(archive)],
                                              env=env, text=True).splitlines()
            objects = [member for member in members if member.endswith(".o")]
            if len(objects) < minimum:
                raise ValueError(f"Incomplete archive {archive}: {len(objects)} object members")
            archive_members[name] = objects
        changed = [p for p, expected in plan["inputs"].items() if digest(Path(p)) != expected]
        if changed:
            raise ValueError(f"Inputs changed during compilation: {changed[:10]}")
        pinned(Path(plan["source_packages"]) / "checkouts/client-sdk-swift", LIVEKIT)
        pinned(Path(plan["source_packages"]) / "checkouts/livekit-uniffi-xcframework", UNIFFI)
        outputs = {str(p): digest(p) for directory in (out / "Modules", out / "lib")
                   for p in directory.rglob("*") if p.is_file()}
        (out / "compile-result.json").write_text(json.dumps({"passed": True, "outputs": outputs,
                                                          "archive_members": archive_members}, indent=2) + "\n")
    print(json.dumps({"executed": args.execute, "commands": len(plan["commands"]), "output": str(out),
                      "swift_sources": {k: len(v) for k, v in plan["target_sources"].items()}}))


if __name__ == "__main__":
    main()
