#!/usr/bin/env python3
"""Installed native companion physical capture qualification; synthetic two-party room."""
import argparse, datetime, hashlib, http.server, json, os, pathlib, re, secrets, signal, subprocess, sys, threading, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'NativeMacGuest/distribution'))
from build_support import application_executable, installed_application
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--derived-data', type=pathlib.Path, default=ROOT/'.build/udp-sdk-comparison/DerivedData')
p.add_argument('--destination', default='platform=macOS,arch=arm64')
p.add_argument('--lifecycle-only', action='store_true', help='Do not qualify acoustic audibility; retain normal AEC and strict transport checks')
p.add_argument('--manifest', type=pathlib.Path, default=ROOT/'.build/native-mac-guest/build-evidence.json',
               help='Exact installed native app build-evidence.json to verify before and after capture')
a = p.parse_args()
run = ROOT/'.build/native-guest'/('capture-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
run.mkdir(mode=0o700, parents=True)
ipc = run/'peer-control'; ipc.mkdir(mode=0o700)
probe = ROOT/'.build/native-guest/NativeGuestProbe'
app = installed_application('/Applications')
helper = str(application_executable(app))
manifest = json.loads(a.manifest.read_text())
def verify_artifact():
    if installed_application('/Applications') != app:
        raise RuntimeError('Installed companion location changed; reject measurement')
    for relative, expected in manifest['artifacts'].items():
        if hashlib.sha256((app/relative).read_bytes()).hexdigest() != expected:
            raise RuntimeError('Installed companion changed; reject measurement')
    for relative, expected in manifest['sources'].items():
        if hashlib.sha256((ROOT/relative).read_bytes()).hexdigest() != expected:
            raise RuntimeError('Companion source differs from tested artifact')
verify_artifact()
(run/'artifact-identity.json').write_text(json.dumps(manifest,indent=2))
identity_paths = [probe, ROOT/'.build/native-guest/MacCaptureRoute']
products = a.derived_data/'Build/Products'
for name in ['RockNRoll', 'RockNRoll.debug.dylib', 'RockNRollTests']:
    identity_paths.extend(path for path in products.rglob(name) if path.is_file())
identity_paths.extend(ROOT/name for name in [
    'RockNRollTests/NativeGuestOutgoingTests.swift',
    'Experiments/NativeGuestTests/run-mac-capture.py',
    'Experiments/NativeGuestTests/MacCaptureRoute.swift',
    'Experiments/NativeGuest/GuestCompanionPeer.swift', 'Experiments/NativeGuest/Main.swift'])
harness_identity = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in identity_paths}
(run/'harness-identity.json').write_text(json.dumps(harness_identity,indent=2))
def verify_harness():
    for name, expected in harness_identity.items():
        if hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() != expected:
            raise RuntimeError('Capture harness changed during measurement')
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
invite = run/'invitation.txt'
with (run/'bootstrap.log').open('w') as log:
    subprocess.run([str(probe),'--create-room','https://salutejazz.ru','--output',str(invite)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=35)
wave = run/'speech.aiff'
subprocess.run(['/usr/bin/say','-o',str(wave),'Native microphone validation. The meeting is still running. Testing clear speech and camera recovery. '*8],check=True,timeout=30)
env['TEST_RUNNER_ROCKNROLL_TEST_NATIVE_COMPANION_INVITE'] = invite.read_text().strip()
token = secrets.token_hex(32)
class ControlServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
class ControlHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        try:
            length = int(self.headers.get('Content-Length','0'))
            if self.path != '/' or not 0 < length <= 4096 or not secrets.compare_digest(self.headers.get('Authorization',''),token):
                self.send_error(403); return
            command = json.loads(self.rfile.read(length))
            temporary = ipc/'http-command.json'; temporary.write_text(json.dumps(command)); temporary.replace(ipc/'command.json')
            deadline = time.monotonic()+75
            while time.monotonic()<deadline:
                try: result = json.loads((ipc/'result.json').read_text())
                except (FileNotFoundError,json.JSONDecodeError): result = {}
                if result.get('sequence') == command['sequence']:
                    payload = json.dumps(result).encode()
                    self.send_response(200); self.send_header('Content-Length',str(len(payload))); self.end_headers(); self.wfile.write(payload); return
                time.sleep(.1)
            self.send_error(504)
        except (BrokenPipeError,ConnectionResetError): pass
        except BaseException: self.send_error(500)
server = ControlServer(('127.0.0.1',0),ControlHandler)
server_thread = threading.Thread(target=server.serve_forever,daemon=True); server_thread.start()
env['TEST_RUNNER_ROCKNROLL_TEST_NATIVE_CAPTURE_ENDPOINT'] = 'http://127.0.0.1:'+str(server.server_port)+'/'
env['TEST_RUNNER_ROCKNROLL_TEST_NATIVE_CAPTURE_TOKEN'] = token
failure = None
with (run/'peer.jsonl').open('w') as log, (run/'host.log').open('w') as host, (run/'route.log').open('w') as route_log, (run/'stimulus.jsonl').open('w') as stimulus, (run/'afplay.log').open('w') as player_log:
    peer = subprocess.Popen([str(probe),'--invite-file',str(invite),'--companion-peer','--evidence-directory',str(ipc),'--seconds','480'],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
    test = player = route_guard = None
    route = ROOT/'.build/native-guest/MacCaptureRoute'
    saved_route = run/'original-routes.json'
    try:
        subprocess.run([str(route),'--builtins',str(saved_route)],stdout=route_log,stderr=subprocess.STDOUT,check=True,timeout=10)
        route_guard = subprocess.Popen([str(route),'--guard',str(saved_route),str(os.getpid())],stdout=route_log,stderr=subprocess.STDOUT)
        deadline = time.monotonic()+30
        while not (ipc/'ready.json').exists():
            if peer.poll() is not None: raise RuntimeError('Independent peer failed to start')
            if time.monotonic()>deadline: raise RuntimeError('Independent peer startup timed out')
            time.sleep(.1)
        cmd = ['xcodebuild','test-without-building','-project','RockNRoll.xcodeproj','-scheme','RockNRoll','-destination',a.destination,
               '-derivedDataPath',str(a.derived_data),'-parallel-testing-enabled','NO',
               '-only-testing:RockNRollTests/NativeGuestOutgoingTests/'+('testInstalledCompanionCaptureLifecycle' if a.lifecycle_only else 'testInstalledCompanionMicrophoneCameraAndReconnect'),
               '-resultBundlePath',str(run/'host.xcresult')]
        test = subprocess.Popen(cmd,cwd=ROOT,env=env,stdout=host,stderr=subprocess.STDOUT)
        deadline = time.monotonic()+450
        while test.poll() is None:
            if time.monotonic()>deadline: raise RuntimeError('Installed capture test timed out')
            if peer.poll() is not None:
                result = json.loads((ipc/'result.json').read_text()) if (ipc/'result.json').exists() else {}
                if result.get('phase') not in ['finished','failure-cleanup'] or not result.get('pass'):
                    raise RuntimeError('Independent peer ended before acceptance')
            if player is None or player.poll() is not None:
                if player is not None:
                    stimulus.write(json.dumps({'event':'end','time':time.monotonic(),'pid':player.pid,'exit':player.returncode})+'\n'); stimulus.flush()
                    if player.returncode: raise RuntimeError('Acoustic stimulus failed; qualification invalid')
                player = subprocess.Popen(['/usr/bin/afplay','-v','0.55',str(wave)],stdout=player_log,stderr=subprocess.STDOUT)
                stimulus.write(json.dumps({'event':'start','time':time.monotonic(),'pid':player.pid})+'\n'); stimulus.flush()
            time.sleep(.2)
        if test.returncode: raise RuntimeError('Installed capture XCTest failed; retained evidence')
        peer.wait(timeout=10)
        if peer.returncode: raise RuntimeError('Independent peer failed')
    except BaseException as error:
        failure = error
    finally:
        def cleanup_step(operation):
            global failure
            try: operation()
            except BaseException as error:
                if failure is None: failure = error
        def stop_process(process, timeout):
            if process is not None and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=timeout)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
        def finalize_stimulus():
            if player is None: return
            natural_exit = player.poll()
            stimulus.write(json.dumps({'event':'final','time':time.monotonic(),'pid':player.pid,
                                       'exit':natural_exit,'cleanupTermination':natural_exit is None})+'\n'); stimulus.flush()
            try:
                if natural_exit not in [None,0]: raise RuntimeError('Acoustic stimulus failed before cleanup')
            finally: stop_process(player,5)
        cleanup_step(finalize_stimulus)
        cleanup_step(lambda: stop_process(test,15))
        def stop_owned_helper():
            if failure is None: return
            for pid_text in re.findall(r'NATIVE_CAPTURE_READY pid=(\d+)',(run/'host.log').read_text()):
                pid = int(pid_text)
                actual = subprocess.run(['ps','-p',str(pid),'-o','comm='],capture_output=True,text=True).stdout.strip()
                if actual == helper: os.kill(pid,signal.SIGTERM)
        cleanup_step(stop_owned_helper)
        def stop_peer():
            if peer.poll() is not None: return
            try:
                old = json.loads((ipc/'command.json').read_text()) if (ipc/'command.json').exists() else {'sequence':0}
                command = {'sequence':old['sequence']+1,'operation':'stop','phase':'supervisor-cleanup','audio':False,'video':False,'remoteParticipants':0}
                temporary = ipc/'supervisor-command.json'; temporary.write_text(json.dumps(command)); temporary.replace(ipc/'command.json')
                peer.wait(timeout=15)
            finally: stop_process(peer,10)
        cleanup_step(stop_peer)
        def observe_cleanup():
            with (run/'cleanup.jsonl').open('w') as log:
                subprocess.run([str(probe),'--invite-file',str(invite),'--expect-alone','--seconds','5'],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=60)
        def restore_routes():
            if saved_route.exists():
                subprocess.run([str(route),'--restore',str(saved_route)],stdout=route_log,stderr=subprocess.STDOUT,check=True,timeout=10)
            if route_guard is not None: route_guard.wait(timeout=5)
        cleanup_step(restore_routes)
        cleanup_step(observe_cleanup)
        cleanup_step(verify_artifact)
        cleanup_step(verify_harness)
        cleanup_step(server.shutdown)
        cleanup_step(server.server_close)
print(run)
if failure is not None: raise failure
print('PASS: installed companion capture lifecycle, controls, reconnect and cleanup; strict acoustic qualification=' + str(not a.lifecycle_only))
