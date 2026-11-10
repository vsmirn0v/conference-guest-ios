#!/usr/bin/env python3
"""Rebuild the native LiveKitWebRTC.framework from the pinned M156 source.

Encodes the complete, verified procedure so the framework can be rebuilt
without rediscovering the overlay order. Every step verifies its result;
a framework that skips a check is not a candidate.

Usage (from the repository root):

  python3 Experiments/WebRTCM156/rebuild_framework.py verify-tree
  python3 Experiments/WebRTCM156/rebuild_framework.py build
  python3 Experiments/WebRTCM156/rebuild_framework.py package --output-dir .build/webrtc-m156-desktop-audio/<new-name>
  python3 Experiments/WebRTCM156/rebuild_framework.py overlay --regenerate

Prerequisites and background: see REBUILD.md next to this file.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import sys

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
EXPERIMENT = REPOSITORY / "Experiments/WebRTCM156"
sys.path.insert(0, str(REPOSITORY / "NativeMacGuest"))
import native_dependencies  # noqa: E402

SOURCE = REPOSITORY / ".build/webrtc-m156-port/workspace/src"
OUT = SOURCE / "out/configuration-recovery"
BASELINE_MANIFEST = (REPOSITORY / ".build/webrtc-m156-desktop-audio"
                     "/native-framework-screen-r5/provenance/source-manifest-screen-r5.json")
R5_BASE_MANIFEST_SHA256 = "c721741efe93373c953cc4bacc78438104862e8a8050b73a04313a36ac274adb"
# Known, intentional deltas against the screen-r5 tree: the audio route files
# (owned by the route locks) and the gate's audio_device_buffer dependency.
# Everything else must match byte-for-byte.
KNOWN_TREE_DELTAS = {"sdk/BUILD.gn"}
SYNC_NOISE = {"resources/audio_coding/music_stereo_48kHz.pcm_.gstmp",
              "resources/audio_coding/speech_mono_16kHz.pcm_.gstmp",
              "resources/audio_coding/testfile32kHz.pcm_.gstmp"}

TEST_BINARIES = ("modules_audio_device_audio_engine_default_route_policy_unittest_bin",
                 "modules_audio_device_audio_engine_configuration_recovery_gate_unittest_bin",
                 "modules_audio_device_fine_audio_buffer_unittest_bin")
TEST_TARGETS = ("modules/audio_device:audio_engine_default_route_policy_unittest_bin",
                "modules/audio_device:audio_engine_configuration_recovery_gate_unittest_bin",
                "modules/audio_device:fine_audio_buffer_unittest_bin")
EXPECTED_TEST_COUNTS = {TEST_BINARIES[0]: 6, TEST_BINARIES[1]: 6, TEST_BINARIES[2]: 12}

# The framework must export these C-linkage entry points. A missing or
# C++-mangled export means a patch hunk was lost (see REBUILD.md pitfalls).
REQUIRED_EXPORTS = (
    "_LKRTCSetApplicationCaptureMuted",
    "_LKRTCApplicationCaptureMuted",
    "_LKRTCApplicationCaptureState",
    "_LKRTCUnmuteApplicationCaptureIfState",
    "_LKRTCSetApplicationInputMuteIntent",
    "_LKRTCApplicationInputMuteReconfiguring",
    "_LKRTCSetConferencePlayoutReserved",
)


def run(*command, cwd=SOURCE, env=None):
    print("+", " ".join(str(part) for part in command), flush=True)
    subprocess.run([str(part) for part in command], cwd=cwd, check=True,
                   env={"DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                        **(env or {})})


def sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_entries():
    import importlib.util
    spec = importlib.util.spec_from_file_location("source_contract", EXPERIMENT / "source-contract.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.entries(SOURCE, exclude_dependencies=True)


def route_lock_contract():
    return native_dependencies.audio_route_recovery_contract(REPOSITORY)


def verify_tree():
    """The tree must equal the screen-r5 baseline plus the locked route files."""
    if not BASELINE_MANIFEST.exists():
        raise SystemExit(f"Missing baseline manifest: {BASELINE_MANIFEST}")
    entries = source_entries()
    baseline = json.loads(BASELINE_MANIFEST.read_text())["entries"]
    contract = route_lock_contract()
    errors = []
    for name, expected in contract["sourceOverrides"].items():
        if entries.get(name, {}).get("sha256") != expected:
            errors.append(f"route file differs from its lock: {name}")
    for name, entry in baseline.items():
        if name in contract["sourceOverrides"] or name in SYNC_NOISE or name in KNOWN_TREE_DELTAS:
            continue
        if entries.get(name) != entry:
            errors.append(f"differs from screen-r5 baseline: {name}")
    extra = sorted(set(entries) - set(baseline) - set(contract["sourceOverrides"]))
    if extra:
        errors.append(f"unexpected extra files: {extra}")
    if errors:
        for error in errors[:20]:
            print("ERROR:", error)
        raise SystemExit("Tree verification failed; restore the patch series before building")
    print(f"Tree verified: screen-r5 baseline + {len(contract['sourceOverrides'])} locked route files "
          f"+ known deltas {sorted(KNOWN_TREE_DELTAS)}")


def regenerate_overlay():
    """Regenerate the LK namespace overlay for the current tree state."""
    fork = REPOSITORY / ".build/webrtc-m150-fork"
    if not fork.exists():
        raise SystemExit("Clone the pinned M150 fork first (see REBUILD.md prerequisites)")
    qualified = (REPOSITORY / ".build/webrtc-m156-desktop-audio"
                 "/native-framework-screen-r5/LiveKitWebRTC.xcframework/macos-arm64"
                 "/LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC")
    livekit = REPOSITORY / f".build/native-sdk/client-sdk-swift-{native_dependencies.SDK_REVISION}"
    run(sys.executable, REPOSITORY / "Experiments/WebRTCM155/prefix_overlay.py", "plan",
        "--source", SOURCE, "--old-fork", fork, "--flavor", "livekit",
        "--qualified-prefix-binary", qualified, "--livekit-source", livekit,
        "--audit", REPOSITORY / ".build/webrtc-m156-port/namespace-audio-route-r1.json",
        "--patch", REPOSITORY / ".build/webrtc-m156-port/namespace-audio-route-r1.patch",
        cwd=REPOSITORY)
    print("Overlay regenerated; apply it to the tree with: git apply "
          ".build/webrtc-m156-port/namespace-audio-route-r1.patch")


def build():
    verify_tree()
    run(SOURCE / "third_party/ninja/ninja", "-C", OUT, "-j4", "sdk:mac_framework_bundle")
    run(SOURCE / "third_party/ninja/ninja", "-C", OUT, "-j4", *TEST_TARGETS)
    for binary in TEST_BINARIES:
        result = subprocess.run([str(OUT / binary)], capture_output=True, text=True)
        counts = dict(EXPECTED_TEST_COUNTS)
        for line in result.stdout.splitlines():
            if "RunTestCount=" in line and binary in line:
                counts[binary] = int(line.split("mean=")[1].split(",")[0])
            if "FAILED" in line:
                raise SystemExit(f"{binary} reported a failure: {line}")
        if counts[binary] != EXPECTED_TEST_COUNTS[binary]:
            raise SystemExit(f"{binary}: expected {EXPECTED_TEST_COUNTS[binary]} tests, "
                             f"ran {counts[binary]}")
        print(f"{binary}: {counts[binary]}/{EXPECTED_TEST_COUNTS[binary]} passed")
    verify_exports(OUT / "LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC")


def verify_exports(binary):
    symbols = subprocess.run(["nm", "-gU", str(binary)], capture_output=True, text=True, check=True).stdout
    missing = [name for name in REQUIRED_EXPORTS if name not in symbols]
    mangled = [name for name in REQUIRED_EXPORTS[2:4] if f"__Z{len(name) - 1}{name[1:]}" in symbols]
    if missing:
        raise SystemExit(f"Framework is missing gate exports (a patch hunk was lost): {missing}")
    if mangled:
        raise SystemExit(f"Gate exports have C++ linkage (header declarations lost): {mangled}")
    plain = subprocess.run(["strings", str(binary)], capture_output=True, text=True, check=True).stdout
    if "-[RTCPeerConnection " in plain or "-[LKRTCPeerConnection " not in plain:
        raise SystemExit("Framework lost the LK namespace overlay (plain RTCPeerConnection classes found)")
    print(f"Exports verified: {len(REQUIRED_EXPORTS)} gate entry points, LK namespace present")


def package(output_dir):
    output = pathlib.Path(output_dir).resolve()
    if output.exists():
        raise SystemExit(f"Refusing to replace an existing candidate: {output}")
    framework = OUT / "LiveKitWebRTC.framework"
    if not framework.exists():
        raise SystemExit("Build first: the framework bundle is missing")
    verify_exports(framework / "Versions/A/LiveKitWebRTC")
    output.mkdir(parents=True)
    run("xcodebuild", "-create-xcframework", "-framework", framework,
        "-output", output / "LiveKitWebRTC.xcframework", cwd=REPOSITORY)
    licenses = REPOSITORY / ".build/webrtc-m156-desktop-audio/native-framework-screen-r5/licenses"
    if licenses.exists():
        run("cp", "-R", licenses, output / "licenses", cwd=REPOSITORY)
    manifest_path = REPOSITORY / ".build/webrtc-m156-port/source-manifest-audio-route-r1.json"
    evidence = {
        "scope": "native audio route recovery candidate; see Experiments/WebRTCM156/REBUILD.md",
        "sourceRevision": route_lock_contract()["upstreamRevision"],
        "frameworkBinarySHA256": sha256(output / "LiveKitWebRTC.xcframework/macos-arm64"
                                        "/LiveKitWebRTC.framework/LiveKitWebRTC"),
        "sourceManifest": str(manifest_path),
        "sourceManifestSHA256": sha256(manifest_path),
        "compilerSHA256": sha256("/Applications/Xcode.app/Contents/Developer/Toolchains"
                                 "/XcodeDefault.xctoolchain/usr/bin/clang"),
        "gnArgsSHA256": sha256(OUT / "args.gn"),
        "audioRouteRecovery": route_lock_contract(),
    }
    (output / "build-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    native_dependencies.verify_audio_route_recovery_framework(output, REPOSITORY)
    print(f"Candidate packaged and contract-verified: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("verify-tree", help="verify the workspace tree state before building")
    sub.add_parser("build", help="verify the tree, build the framework and run native audio tests")
    sub.add_parser("overlay", help="regenerate the LK namespace overlay for the current tree").add_argument(
        "--regenerate", action="store_true", help="accepted for explicitness; regeneration is the only mode")
    package_parser = sub.add_parser("package", help="create and verify a new framework candidate")
    package_parser.add_argument("--output-dir", required=True)
    arguments = parser.parse_args()
    if arguments.command == "verify-tree":
        verify_tree()
    elif arguments.command == "build":
        build()
    elif arguments.command == "overlay":
        regenerate_overlay()
    elif arguments.command == "package":
        package(arguments.output_dir)


if __name__ == "__main__":
    main()
