#!/usr/bin/env python3
"""Package an existing native guest probe; never launch it or change media permissions.

This local test intentionally reuses the previously approved application identity.
Its LaunchServices registration can shadow the shipping app with the same ID;
the operator must unregister this exact prototype bundle path after testing.
This script does not register or launch the bundle.
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid


def run(*command):
    subprocess.run(command, check=True)


def main():
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", required=True, help="Existing Apple Development signing identity")
    parser.add_argument("--invite-file", required=True, type=Path, help="Disposable room invitation; copied privately")
    parser.add_argument("--binary", type=Path, default=repo / ".build/native-guest/NativeGuestProbe")
    parser.add_argument("--framework", required=True, type=Path, help="Native macOS LiveKitWebRTC.framework slice")
    parser.add_argument("--output", type=Path, default=repo / ".build/native-guest/NativeGuestPrototype.app")
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--codec", choices=("h264", "vp8", "vp9"), default="h264", help="Explicit prototype codec comparison")
    parser.add_argument("--no-camera", action="store_true", help="Use generated video for a microphone-only hardware check")
    parser.add_argument("--reaction", action="store_true", help="Explicitly request a native thumbs-up reaction during the test")
    parser.add_argument("--reconnect", action="store_true", help="Fault both prototype sockets and verify automatic recovery")
    parser.add_argument("--toggle", action="store_true", help="Explicitly exercise the prototype camera publication toggle")
    parser.add_argument("--fixture-bypass-voice-processing", action="store_true", help="Diagnostic acoustic fixture only: disable system echo cancellation")
    parser.add_argument("--real-audio", action="store_true", help="Explicitly opt in to live microphone publication")
    parser.add_argument("--real-playout", action="store_true", help="Explicitly opt in to received audio through Mac speakers")
    parser.add_argument("--duplex", action="store_true", help="Normal AEC with one physical microphone/speaker endpoint and a synthetic remote peer")
    parser.add_argument("--duplex-aec-comparison", action="store_true", help="Explicit bounded full-processing bypass comparison; requires --duplex")
    parser.add_argument("--duplex-reconnect-cycles", type=int, help="Repeat both reconnect paths 1 to 3 times; requires normal --duplex")
    parser.add_argument("--duplex-soak-seconds", type=int, help="40–120 seconds in 20-second increments, split around up to two reconnect cycles")
    parser.add_argument("--duplex-ice", choices=("auto", "tcp-relay", "udp-relay", "udp-receive", "udp-publish"), help="Explicit transport experiment using only advertised endpoints")
    parser.add_argument("--rtc-event-log-directory", type=Path, help="Private bounded RTP/RTCP diagnostic logs; duplex only")
    args = parser.parse_args()
    if args.rtc_event_log_directory is not None and not args.duplex:
        parser.error("RTC event logs require duplex")
    if args.duplex_ice is not None and not args.duplex:
        parser.error("--duplex-ice requires --duplex")
    if args.duplex_soak_seconds is not None and (not args.duplex or args.duplex_aec_comparison or not 40 <= args.duplex_soak_seconds <= 120 or args.duplex_soak_seconds % 20 != 0 or (args.duplex_reconnect_cycles or 1) > 2):
        parser.error("Soak requires normal duplex, 40–120 seconds in 20-second increments, at most two reconnect cycles")
    if args.duplex_reconnect_cycles is not None and (not args.duplex or args.duplex_aec_comparison or not 1 <= args.duplex_reconnect_cycles <= 3):
        parser.error("Reconnect repetitions require normal --duplex and a count from 1 to 3")
    if args.duplex_aec_comparison and not args.duplex:
        parser.error("--duplex-aec-comparison requires --duplex")
    if args.duplex and any((args.real_audio, args.real_playout, args.reaction, args.toggle, args.reconnect, args.fixture_bypass_voice_processing)):
        parser.error("--duplex is a separate normal-AEC lifecycle check; other media modes are incompatible")
    if args.fixture_bypass_voice_processing and not args.real_audio:
        parser.error("--fixture-bypass-voice-processing requires --real-audio")
    if args.real_audio and (args.reaction or args.toggle):
        parser.error("The physical microphone diagnostic uses its own measured mute/resume sequence")
    if args.reaction and (args.toggle or args.seconds < 15):
        parser.error("--reaction requires at least 15 seconds and cannot use --toggle")
    if args.no_camera and args.reaction:
        parser.error("--reaction requires the camera")
    if args.real_audio and args.real_playout:
        parser.error("Choose one physical audio direction per paired test to avoid microphone/speaker feedback")
    binary = args.binary.resolve(strict=True)
    framework = args.framework.resolve(strict=True)
    invitation = args.invite_file.resolve(strict=True)
    destination = args.output.resolve()
    if framework.name != "LiveKitWebRTC.framework" or not framework.is_dir():
        parser.error("--framework must name LiveKitWebRTC.framework")
    if destination.suffix != ".app":
        parser.error("--output must name an .app bundle")
    if not binary.is_file() or not invitation.is_file() or invitation.stat().st_size > 4096:
        parser.error("Binary and invitation must be regular files; invitation must be at most 4096 bytes")
    invitation_data = invitation.read_bytes()
    if not invitation_data.strip():
        parser.error("Invitation file is empty")
    if destination.exists():
        previous_info = destination / "Contents/Info.plist"
        if not previous_info.is_file() or plistlib.loads(previous_info.read_bytes()).get("CFBundleExecutable") != "NativeGuestProbe":
            parser.error("Refusing to replace a bundle that is not this prototype")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="native-guest-package-", dir=destination.parent) as temporary:
        staged = Path(temporary) / destination.name
        contents = staged / "Contents"
        macos = contents / "MacOS"
        resources = contents / "Resources"
        frameworks = contents / "Frameworks"
        for directory in [macos, resources, frameworks]:
            directory.mkdir(parents=True, exist_ok=True)
        os.chmod(resources, 0o700)
        executable = macos / "NativeGuestProbe"
        shutil.copy2(binary, executable)
        os.chmod(executable, 0o755)
        bundled_invitation = resources / "invitation.txt"
        descriptor = os.open(bundled_invitation, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(invitation_data)
        bundled_framework = frameworks / framework.name
        shutil.copytree(framework, bundled_framework, symlinks=True)
        load_commands = subprocess.check_output(["otool", "-l", str(executable)], text=True)
        runtime_path = "@executable_path/../Frameworks"
        # Parse LC_RPATH records, removing local build roots that would otherwise
        # win over the signed framework bundled below under hardened runtime.
        reading_rpath = False
        relative_paths = []
        for line in load_commands.splitlines():
            fields = line.split()
            if fields[:2] == ["cmd", "LC_RPATH"]:
                reading_rpath = True
            elif reading_rpath and fields and fields[0] == "path":
                path = line.strip()[5:].rsplit(" (offset ", 1)[0]
                if Path(path).is_absolute():
                    run("install_name_tool", "-delete_rpath", path, str(executable))
                else:
                    relative_paths.append(path)
                reading_rpath = False
        if runtime_path not in relative_paths:
            run("install_name_tool", "-add_rpath", runtime_path, str(executable))
        arguments = ["--pair", "--seconds", str(args.seconds), "--codec", args.codec,
                     "--invite-file", str(destination / "Contents/Resources/invitation.txt")]
        if not args.duplex:
            arguments += ["--save-frame", str(destination.parent / "camera-received.png")]
        if not args.no_camera and not args.duplex:
            arguments.append("--camera")
        if args.duplex:
            arguments.append("--duplex")
        if args.rtc_event_log_directory is not None:
            arguments += ["--rtc-event-log-directory", str(args.rtc_event_log_directory.resolve())]
        if args.duplex_ice is not None:
            arguments += ["--duplex-ice", args.duplex_ice]
        if args.duplex_soak_seconds is not None:
            arguments += ["--duplex-soak-seconds", str(args.duplex_soak_seconds)]
        if args.duplex_aec_comparison:
            arguments.append("--duplex-aec-comparison")
        if args.duplex_reconnect_cycles is not None:
            arguments += ["--duplex-reconnect-cycles", str(args.duplex_reconnect_cycles)]
        if args.reaction:
            arguments.append("--reaction")
        if args.toggle:
            arguments.append("--toggle")
        if args.reconnect:
            arguments.append("--reconnect")
        if args.real_audio:
            arguments.append("--real-audio")
        if args.fixture_bypass_voice_processing:
            arguments.append("--fixture-bypass-voice-processing")
        if args.real_playout:
            arguments.append("--real-playout")
        info = {
            "CFBundleExecutable": "NativeGuestProbe",
            "CFBundleIdentifier": "dev.vsmirn0v.conferenceguest",
            "CFBundleName": "Native Guest Prototype",
            "CFBundleDisplayName": "Native Guest Prototype",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "CFBundleSupportedPlatforms": ["MacOSX"],
            "LSMinimumSystemVersion": "13.0",
            "LSUIElement": True,
            "NSPrincipalClass": "NSApplication",
            "NSCameraUsageDescription": "Publishes the built-in Mac camera only to your disposable native guest test room for the selected short test.",
            "RockNativeGuestArguments": arguments,
            "RockNativeGuestLogPath": str(destination.parent / "camera-run.jsonl"),
        }
        if args.real_audio or args.duplex:
            info["NSMicrophoneUsageDescription"] = "Publishes the Mac microphone only to your disposable native guest test room after explicit audio opt-in. No audio recording files are saved."
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        entitlements = Path(temporary) / "camera.entitlements"
        media_entitlements = {"com.apple.security.device.camera": True}
        if args.real_audio or args.duplex:
            media_entitlements["com.apple.security.device.audio-input"] = True
        entitlements.write_bytes(plistlib.dumps(media_entitlements))
        run("codesign", "--force", "--options", "runtime", "--sign", args.identity, str(bundled_framework))
        run("codesign", "--force", "--options", "runtime", "--sign", args.identity,
            "--entitlements", str(entitlements), str(staged))
        run("codesign", "--verify", "--strict", "--deep", str(staged))
        if destination.exists():
            previous = destination.with_name(destination.stem + ".previous-" + uuid.uuid4().hex[:8] + ".app")
            os.replace(destination, previous)
        os.replace(staged, destination)
    print(destination)


if __name__ == "__main__":
    main()
