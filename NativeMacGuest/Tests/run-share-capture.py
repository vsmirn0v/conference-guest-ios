#!/usr/bin/env python3
"""Compile and run the ShareCapture standalone tests via the verified meeting fixture runner."""
import argparse
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--framework-root',
                    help='Directory containing LiveKitWebRTC.xcframework and build-evidence.json; defaults to the SDK lock')
args = parser.parse_args()
command = ['bash', str(root / 'NativeMacGuest/Tests/run-meeting-engine-fixtures.sh'), 'share-capture']
if args.framework_root is not None:
    command += ['--framework-root', str((root / args.framework_root).resolve())]
raise SystemExit(subprocess.run(command).returncode)
