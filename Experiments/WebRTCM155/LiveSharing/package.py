#!/usr/bin/env python3
"""Package the isolated screen probe without launching or changing permissions.

Reuses the approved development identity for existing Screen Recording access.
Unregister this exact experiment app path after running; the shared bundle ID
can otherwise shadow the installed app in LaunchServices.
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def run(*args):
    subprocess.run(args, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--framework', required=True, type=Path)
    parser.add_argument('--invite-file', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--evidence-directory', required=True, type=Path)
    parser.add_argument('--codec', choices=['h264', 'vp8', 'vp9'], default='h264')
    parser.add_argument('--ice', choices=['auto', 'tcp-relay', 'udp-relay'], default='auto', help='Diagnostic only; filters explicitly advertised relay URLs')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--screen-control-h264', action='store_true', help='Separate 640x400 H264/TCP control; not full acceptance')
    modes.add_argument('--capture-only', action='store_true', help='Own-window SCK only; no conference connection')
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    framework = args.framework.resolve(strict=True)
    invite = args.invite_file.resolve(strict=True)
    destination = args.output.resolve()
    evidence = args.evidence_directory.resolve()
    if destination.exists() or destination.suffix != '.app':
        parser.error('--output must be a new .app path')
    if framework.name != 'LiveKitWebRTC.framework' or not framework.is_dir():
        parser.error('--framework must name LiveKitWebRTC.framework')
    if not binary.is_file() or not invite.is_file() or not 0 < invite.stat().st_size <= 4096:
        parser.error('Binary and bounded nonempty invitation must be regular files')
    destination.parent.mkdir(parents=True, exist_ok=True)
    evidence.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix='m155-sharing-package-', dir=destination.parent) as tmp:
        app = Path(tmp) / destination.name
        contents = app / 'Contents'
        for name in ['MacOS', 'Frameworks', 'Resources']:
            (contents / name).mkdir(parents=True, exist_ok=True)
        resources = contents / 'Resources'
        resources.chmod(0o700)
        invitation = resources / 'invitation.txt'
        with open(invitation, 'xb') as stream:
            os.chmod(invitation, 0o600)
            stream.write(invite.read_bytes())
        executable = contents / 'MacOS/LiveSharingProbe'
        shutil.copy2(binary, executable)
        executable.chmod(0o755)
        bundled_framework = contents / 'Frameworks' / framework.name
        shutil.copytree(framework, bundled_framework, symlinks=True)
        paths = []
        reading = False
        for line in subprocess.check_output(['otool', '-l', str(executable)], text=True).splitlines():
            if line.split() == ['cmd', 'LC_RPATH']:
                reading = True
            elif reading and line.split()[:1] == ['path']:
                paths.append(line.strip()[5:].rsplit(' (offset ', 1)[0])
                reading = False
        runtime_path = '@executable_path/../Frameworks'
        for path in paths:
            if Path(path).is_absolute():
                run('install_name_tool', '-delete_rpath', path, str(executable))
        if runtime_path not in paths:
            run('install_name_tool', '-add_rpath', runtime_path, str(executable))
        invitation_path = str(destination / 'Contents/Resources/invitation.txt')
        arguments = [invitation_path, str(evidence), args.codec, args.ice]
        if args.screen_control_h264:
            arguments = ['--screen-control-h264', invitation_path, str(evidence)]
        elif args.capture_only:
            arguments = ['--capture-only', str(evidence)]
        info = {'CFBundleExecutable': 'LiveSharingProbe', 'CFBundleIdentifier': 'dev.vsmirn0v.conferenceguest',
                'CFBundleName': 'M155 Synthetic Sharing Probe', 'CFBundlePackageType': 'APPL',
                'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'NSPrincipalClass': 'NSApplication',
                'LSMinimumSystemVersion': '14.2', 'LSUIElement': False,
                'RockLiveSharingArguments': arguments,
                'RockLiveSharingLogPath': str(evidence / 'run.jsonl')}
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        run('codesign', '--force', '--options', 'runtime', '--sign', args.identity, str(bundled_framework))
        run('codesign', '--force', '--options', 'runtime', '--sign', args.identity, str(app))
        run('codesign', '--verify', '--strict', '--deep', str(app))
        os.replace(app, destination)
    print(destination)


if __name__ == '__main__':
    main()
