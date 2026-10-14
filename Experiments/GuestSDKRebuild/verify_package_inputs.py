"""Read-only freshness and identity checks for assembled GN framework outputs."""

import hashlib
import json
import os
from pathlib import Path
import subprocess


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(*args, cwd):
    environment = os.environ.copy()
    environment["NINJA_STATUS"] = "[%f/%t] "
    return subprocess.check_output(
        [str(arg) for arg in args], cwd=cwd, env=environment, text=True,
        stderr=subprocess.STDOUT,
    ).strip()


def verify_build(source, output, target):
    ninja = source / "third_party/ninja/ninja"
    pending = run(ninja, "-C", output, "-n", target, cwd=source)
    # A pending manifest regeneration is also stale. A dry run must contain no
    # build steps, even if its final line says there is no work for the target.
    lines = [line for line in pending.splitlines()
             if not line.startswith("ninja: Entering directory ")]
    if lines != ["ninja: no work to do."]:
        raise RuntimeError(f"Build is not up to date: {output}\n{pending}")


def verify_arguments(source, output, expected):
    # Ask GN for evaluated values rather than interpreting its input language.
    arguments = json.loads(run(source / "buildtools/mac/gn", "args", output,
                               "--list", "--json", cwd=source))
    actual = {item["name"]: item.get("current", item["default"])["value"]
              for item in arguments}
    for name, value in expected.items():
        if actual.get(name) != json.dumps(value):
            raise RuntimeError(f"Unexpected GN argument {name} for {output}: {actual.get(name)}")


def contained_path(root, relative):
    path = Path(relative)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise RuntimeError(f"Invalid framework path: {relative}")
    resolved = (root / path).resolve(strict=True)
    if not resolved.is_relative_to(root.resolve()):
        raise RuntimeError(f"Framework path escapes artifact: {relative}")
    return resolved


def verify_inputs(source, framework, metadata):
    libraries = metadata["AvailableLibraries"]
    expected = {None: "device", "simulator": "simulator"}
    variants = [item.get("SupportedPlatformVariant") for item in libraries]
    if len(libraries) != len(expected) or set(variants) != set(expected):
        raise RuntimeError("Expected exactly one iOS device and one simulator slice")
    identifiers = [item["LibraryIdentifier"] for item in libraries]
    if len(set(identifiers)) != len(identifiers):
        raise RuntimeError("Duplicate framework slice identifier")
    slices = []
    outputs = set()
    for item in libraries:
        if (item["SupportedPlatform"] != "ios"
                or item["SupportedArchitectures"] != ["arm64"]
                or item["LibraryPath"] != "WebRTC.framework"):
            raise RuntimeError(f"Unexpected framework slice: {item}")
        environment = expected[item.get("SupportedPlatformVariant")]
        output = (source / f"out/rock-hybrid-ios-{environment}").resolve(strict=True)
        if output in outputs:
            raise RuntimeError("Each slice must have a distinct GN output directory")
        outputs.add(output)
        verify_build(source, output, "ios_framework_bundle")
        verify_arguments(source, output, {
            "target_os": "ios", "target_cpu": "arm64", "target_environment": environment,
            "enable_stripping": False, "ios_enable_code_signing": False,
        })
        binary = contained_path(framework, item["LibraryIdentifier"] + "/" + item["LibraryPath"] + "/WebRTC")
        built_binary = output / "WebRTC.framework/WebRTC"
        digest = sha256(built_binary)
        if sha256(output / "obj/sdk/WebRTC") != digest:
            raise RuntimeError(f"Framework differs from linked binary: {output}")
        if sha256(binary) != digest:
            raise RuntimeError(f"Assembled framework differs from current GN output: {binary}")
        slices.append({"identifier": item["LibraryIdentifier"],
                       "binary_sha256": digest,
                       "gn_args": (output / "args.gn").read_text()})
    return slices
