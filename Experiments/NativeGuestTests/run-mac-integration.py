#!/usr/bin/env python3
"""Authorized synthetic Mac host/helper acceptance with an exact-process crash supervisor."""
import argparse, datetime, json, os, pathlib, re, signal, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'NativeMacGuest/distribution'))
from build_support import application_executable, installed_application
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--invite-file', required=True, type=pathlib.Path)
p.add_argument('--derived-data', type=pathlib.Path, default=ROOT/'.build/udp-sdk-comparison/DerivedData')
p.add_argument('--destination', default='platform=macOS,arch=arm64')
a = p.parse_args()
run = ROOT/'.build/native-guest'/('integration-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
run.mkdir(mode=0o700, parents=True)
probe = ROOT/'.build/native-guest/NativeGuestProbe'
app_executable = str(application_executable(installed_application('/Applications')))
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
env['TEST_RUNNER_ROCKNROLL_TEST_NATIVE_COMPANION_INVITE'] = a.invite_file.read_text().strip()
env['TEST_RUNNER_ROCKNROLL_TEST_NATIVE_COMPANION_CRASH_SUPERVISOR'] = '1'
source_log, host_log = run/'source.jsonl', run/'host.log'
with source_log.open('w') as src, host_log.open('w') as log:
    source = subprocess.Popen([str(probe),'--invite-file',str(a.invite_file),'--pair','--seconds','120',
                               '--codec','h264','--pair-ice','auto'],cwd=ROOT,stdout=src,stderr=subprocess.STDOUT)
    test = None
    failure = None
    try:
        deadline = time.monotonic()+30
        while time.monotonic()<deadline:
            if source.poll() is not None: raise RuntimeError('Synthetic source exited before publication')
            events = []
            for line in source_log.read_text().splitlines():
                try: events.append(json.loads(line))
                except json.JSONDecodeError: pass
            if any(x.get('event')=='publishing' for x in events): break
            time.sleep(.2)
        else: raise RuntimeError('Synthetic source did not publish')
        cmd = ['xcodebuild','test-without-building','-project','RockNRoll.xcodeproj','-scheme','RockNRoll',
               '-destination',a.destination,'-derivedDataPath',str(a.derived_data),'-parallel-testing-enabled','NO',
               '-only-testing:RockNRollTests/NativeGuestIntegrationTests/testMacCompanionJoinReceiveControlsLeaveAndRejoin',
               '-resultBundlePath',str(run/'host.xcresult')]
        test = subprocess.Popen(cmd,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
        deadline, handled = time.monotonic()+260, set()
        while test.poll() is None:
            if time.monotonic()>deadline: raise RuntimeError('Host acceptance timed out')
            text = host_log.read_text()
            if source.poll() is not None and 'NATIVE_COMPANION_ACCEPTANCE cycle=2' not in text:
                raise RuntimeError('Synthetic source ended before final media acceptance; invalid setup')
            for pid_text in re.findall(r'NATIVE_COMPANION_CRASH_REQUEST pid=(\d+)',text):
                pid = int(pid_text)
                if pid in handled: continue
                actual = subprocess.check_output(['ps','-p',str(pid),'-o','comm='],text=True).strip()
                if actual != app_executable: raise RuntimeError('Refusing to signal a different process')
                os.kill(pid,signal.SIGKILL); handled.add(pid)
                print('Controlled companion failure delivered',flush=True)
            time.sleep(.1)
        print('Host acceptance exit:',test.returncode,flush=True)
        if test.returncode or len(handled)!=1: raise RuntimeError('Host acceptance failed; retain the run evidence')
    except BaseException as error:
        failure = error
    finally:
        if test is not None and test.poll() is None:
            test.terminate(); test.wait(timeout=15)
        # Only helpers identified by this test's authenticated status may be stopped.
        if failure is not None:
            for pid_text in re.findall(r'NATIVE_COMPANION_READY cycle=\d+ pid=(\d+)',host_log.read_text()):
                pid = int(pid_text)
                if pid <= 0: continue
                actual = subprocess.run(['ps','-p',str(pid),'-o','comm='],text=True,capture_output=True).stdout.strip()
                if actual == app_executable: os.kill(pid,signal.SIGTERM)
        try:
            source.wait(timeout=140)
            if source.returncode: raise RuntimeError('Synthetic source failed; invalid setup')
        except subprocess.TimeoutExpired:
            source.terminate(); source.wait(timeout=10)
            if failure is None: failure = RuntimeError('Synthetic source timed out')
        except BaseException as error:
            if failure is None: failure = error
        # Always retain an independent cleanup result, including failed host runs.
        try:
            with (run/'cleanup.jsonl').open('w') as cleanup:
                subprocess.run([str(probe),'--invite-file',str(a.invite_file),'--seconds','5','--expect-alone'],
                               cwd=ROOT,stdout=cleanup,stderr=subprocess.STDOUT,check=True,timeout=60)
        except BaseException as error:
            if failure is None: failure = error
print(run)
if failure is not None: raise failure
print('PASS: host/helper acceptance and independent cleanup observer')
