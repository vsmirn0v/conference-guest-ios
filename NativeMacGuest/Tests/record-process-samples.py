#!/usr/bin/env python3
"""Record bounded CPU/RSS samples for the installed native Mac app.

Start the desired test manually using the app, then run this recorder during a
known, fixed phase. It never joins or controls a meeting and does not read its
invitation, contents, audio or video. Use a fresh output path for every run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time

APP = Path("/Applications/Rock'N'Roll for Mac.app")
EXECUTABLE = APP / "Contents/MacOS/RockNRoll Native Guest"


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(data)
    return digest.hexdigest()


def installed_process():
    found = subprocess.run(['pgrep', '-x', 'RockNRoll Native Guest'], text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    candidates = []
    for pid in found.stdout.split():
        if not pid.isdecimal():
            continue
        process = subprocess.run(['ps', '-p', pid, '-o', 'command='], text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        command = process.stdout.strip()
        if command == str(EXECUTABLE) or command.startswith(str(EXECUTABLE) + ' '):
            candidates.append(int(pid))
    if len(candidates) != 1:
        raise RuntimeError('Expected exactly one running installed native Mac app.')
    return candidates[0]


def sample(pid):
    process = subprocess.run(['ps', '-p', str(pid), '-o', '%cpu=', '-o', 'rss='],
                             text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    parts = process.stdout.split()
    if process.returncode or len(parts) != 2:
        raise RuntimeError('The selected app process exited or could not be sampled.')
    cpu, rss_kib = float(parts[0]), int(parts[1])
    if cpu < 0 or rss_kib < 0:
        raise RuntimeError('Invalid process sample.')
    return {'cpuPercent': cpu, 'residentMiB': round(rss_kib / 1024, 2)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', required=True, choices=('guest', 'telemost', 'trueconf', 'rock'))
    parser.add_argument('--phase', required=True, choices=('idle', 'joining', 'receiving', 'sending'))
    parser.add_argument('--duration', type=int, default=15, help='Number of one-second samples (1–180).')
    parser.add_argument('--output', required=True, type=Path, help='New JSON evidence path; existing files are never replaced.')
    args = parser.parse_args()
    if not 1 <= args.duration <= 180:
        parser.error('--duration must be between 1 and 180 seconds')
    if args.output.exists():
        parser.error('--output already exists')
    if not EXECUTABLE.is_file():
        parser.error('The expected installed app executable is unavailable')
    try:
        pid = installed_process()
        digest = sha256(EXECUTABLE)
        info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
        samples = []
        start = time.monotonic()
        for index in range(args.duration):
            # The exact PID must remain the installed app throughout the series.
            if installed_process() != pid:
                raise RuntimeError('The installed app process changed during sampling.')
            row = sample(pid)
            row['elapsedSeconds'] = round(time.monotonic() - start, 3)
            samples.append(row)
            if index + 1 < args.duration:
                time.sleep(max(0.0, start + index + 1 - time.monotonic()))
        if sha256(EXECUTABLE) != digest:
            raise RuntimeError('The installed executable changed during sampling.')
    except (OSError, ValueError, RuntimeError) as exc:
        parser.exit(1, f'Sampling failed: {exc}\n')
    evidence = {
        'schemaVersion': 1,
        'provider': args.provider,
        'phase': args.phase,
        'app': {'bundleIdentifier': info.get('CFBundleIdentifier'),
                'version': info.get('CFBundleShortVersionString'),
                'build': info.get('CFBundleVersion'), 'executableSHA256': digest},
        'intervalSeconds': 1,
        'samples': samples,
        'limits': ['CPU is the process statistic reported by ps, not energy use.',
                   'The phase and participant/route conditions are operator supplied; this recorder does not verify media.',
                   'Compare only runs on the same hardware, OS, route and media workload.']
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation avoids replacing previous evidence, including on races.
    with args.output.open('x', encoding='utf-8') as stream:
        json.dump(evidence, stream, indent=2)
        stream.write('\n')
    print(f'Recorded {len(samples)} samples to {args.output}.')


if __name__ == '__main__':
    main()
