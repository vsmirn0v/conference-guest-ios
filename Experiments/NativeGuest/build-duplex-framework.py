#!/usr/bin/env python3
"""Build the isolated Mac prototype patch, restoring the input source afterward.

Requires the existing dependency-synced, built native tree. Never installs an app,
changes shipping dependency pins, resets a checkout, or overwrites an output.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def run(*args, cwd=None):
    try:
        return subprocess.check_output([str(arg) for arg in args], cwd=cwd, text=True)
    except subprocess.CalledProcessError as error:
        print(error.output)
        raise


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--event-logs", action="store_true", help="Separate diagnostic build with native RTC event logs and parser")
    args = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    source = args.source.resolve(strict=True)
    output = args.output.resolve()
    if output.exists():
        parser.error("Output must be a new directory")
    experiment = Path(__file__).resolve().parent
    patch = experiment / "input-mixer-start-mute.patch"
    relative = "modules/audio_device/audio_engine_device.mm"
    audio = source / relative
    lock = json.loads((experiment.parent / "WebRTCHybrid/build-lock.json").read_text())
    revision = run("git", "rev-parse", "HEAD", cwd=source).strip()
    if revision != lock["source_sha"]:
        parser.error("Source revision does not match the native build lock")
    # Preserve every other source change; reject a pre-existing edit to this file.
    subprocess.run(["git", "diff", "--exit-code", "HEAD", "--", relative], cwd=source, check=True)
    run("git", "apply", "--check", patch, cwd=source)
    original = audio.read_bytes()
    build = source / ("out/rock-native-guest-eventlog" if args.event_logs else "out/rock-hybrid-mac")
    if args.event_logs:
        gn_args = (source / "out/rock-hybrid-mac/args.gn").read_text()
        if "rtc_enable_protobuf = false" not in gn_args:
            parser.error("Unexpected base protobuf setting")
        gn_args = gn_args.replace("rtc_enable_protobuf = false", "rtc_enable_protobuf = true")
        run(source / "buildtools/mac/gn", "gen", build, "--args=" + gn_args, cwd=source)
    ninja = source / "third_party/ninja/ninja"
    output.mkdir(parents=True)
    modified = None
    metadata = {"sourceRevision": revision, "sourceBeforeSHA256": digest(original), "patchSHA256": digest(patch.read_bytes())}
    try:
        run("git", "apply", patch, cwd=source)
        modified = audio.read_bytes()
        metadata["sourcePatchedSHA256"] = digest(modified)
        subprocess.run([str(ninja), "-C", str(build), "-j4", "mac_framework_bundle"], cwd=source, check=True)
        if args.event_logs:
            subprocess.run([str(ninja), "-C", str(build), "-j4", "rtc_event_log_to_text"], cwd=source, check=True)
            metadata["gnArgumentsSHA256"] = digest((build / "args.gn").read_bytes())
        run("xcodebuild", "-create-xcframework", "-framework", build / "LiveKitWebRTC.framework",
            "-output", output / "LiveKitWebRTC.xcframework")
        framework = output / "LiveKitWebRTC.xcframework/macos-arm64/LiveKitWebRTC.framework"
        metadata["frameworkBinarySHA256"] = digest((framework / "LiveKitWebRTC").read_bytes())
    finally:
        if modified is not None:
            if audio.read_bytes() != modified:
                raise RuntimeError("Concurrent source edit detected; preserved it instead of restoring")
            audio.write_bytes(original)
            metadata["sourceRestoredSHA256"] = digest(audio.read_bytes())
        (output / "build-evidence.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(output)


if __name__ == "__main__":
    main()
