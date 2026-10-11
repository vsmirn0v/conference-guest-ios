#!/usr/bin/env python3
"""Counterbalanced camera-only preview phases, each recording below five minutes."""
import argparse
import json
import os
import re
from pathlib import Path
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--device', required=True)
p.add_argument('--directory', type=Path, required=True)
p.add_argument('--surface', choices=['native', 'pip'], required=True)
p.add_argument('--reverse', action='store_true')
p.add_argument('--rates', choices=['30', '30,60'], default='30,60')
p.add_argument('--power-target', choices=['process', 'all'], default='process')
p.add_argument('--skip-power', action='store_true', help='Collect latency and getrusage CPU without Instruments')
p.add_argument('--seconds', type=int, default=90, choices=range(15, 111))
a = p.parse_args()
a.directory.mkdir(parents=True, exist_ok=False)
(a.directory / 'request.json').write_text(json.dumps({'rates': a.rates, 'surface': a.surface, 'seconds': a.seconds, 'power': not a.skip_power}))
root = Path(__file__).resolve().parents[2]
build = root / '.build/preview-cadence'
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           TEST_RUNNER_ROCK_PREVIEW_MEASURE='1', TEST_RUNNER_ROCK_PREVIEW_SURFACE=a.surface,
           TEST_RUNNER_ROCK_PREVIEW_REVERSE='1' if a.reverse else '0',
           TEST_RUNNER_ROCK_PREVIEW_SECONDS=str(a.seconds), TEST_RUNNER_ROCK_PREVIEW_RATES=a.rates)
command = ['xcodebuild', 'test-without-building', '-project', str(build / 'PreviewExperiment.xcodeproj'),
           '-scheme', 'PreviewExperiment', '-destination', 'platform=iOS,id=' + a.device,
           '-derivedDataPath', str(build / 'DerivedData'), '-disableAutomaticPackageResolution',
           '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
           '-only-testing:RockNRollUITests/PreviewCadenceUITests/testControlledPreviewMeasurement',
           '-resultBundlePath', str(a.directory / 'test.xcresult')]
with (a.directory / 'test.log').open('w') as log, (a.directory / 'power.log').open('w') as power_log:
    test = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, cwd=root)
    trace = None
    try:
        deadline = time.monotonic() + 150
        while 'PREVIEW_MEASURE_READY ' not in (a.directory / 'test.log').read_text(errors='replace'):
            if test.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('Camera not ready; inspect test.log')
            time.sleep(0.5)
        print('Camera ready; ' + ('collecting app timings' if a.skip_power else 'starting power capture'), flush=True)
        pid = re.findall(r'app with pid (\d+)', (a.directory / 'test.log').read_text(errors='replace'))[-1]
        (a.directory / 'pid.txt').write_text(pid)
        phases = len(a.rates.split(','))
        trace = None if a.skip_power else subprocess.Popen(['xcrun', 'xctrace', 'record', '--template', 'Blank',
            '--instrument', 'Power Profiler', '--device', a.device,
            *(['--all-processes'] if a.power_target == 'all' else ['--instrument', 'Time Profiler', '--attach', pid]),
            '--time-limit', str(phases * (a.seconds + 12) + 30) + 's',
            '--output', str(a.directory / 'power.trace')], env=env, stdout=power_log, stderr=subprocess.STDOUT)
        test_result = test.wait(timeout=phases * (a.seconds + 12) + 60)
        trace_result = trace.wait(timeout=180) if trace else 0
        print('test_exit', test_result, 'trace_exit', trace_result, flush=True)
        subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', a.device,
                        '--domain-type', 'appDataContainer', '--domain-identifier',
                        'dev.vsmirn0v.conferenceguest.previewexperiment', '--source',
                        'Library/Caches/preview-experiment.jsonl', '--destination', str(a.directory / 'measurements.jsonl')],
                       env=env, check=True)
        raise SystemExit(test_result or trace_result)
    finally:
        if test.poll() is None:
            test.terminate(); test.wait(timeout=10)
        if trace and trace.poll() is None:
            trace.send_signal(2); trace.wait(timeout=30)
