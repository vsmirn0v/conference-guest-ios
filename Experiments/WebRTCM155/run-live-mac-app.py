#!/usr/bin/env python3
"""Supervise an explicitly signed, disposable native conference diagnostic.

Never installs over an application, changes routes, or resets system services.
Invitation contents and microphone PCM are not copied into the result record.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", required=True, type=Path)
parser.add_argument("--timeout", type=int, default=300)
parser.add_argument("--fixture", type=Path, help="Explicit synthetic acoustic fixture played without changing volume")
parser.add_argument("--executable", default="NativeGuestProbe")
parser.add_argument("--pass-event", default="prototype-pass")
parser.add_argument("--fail-event", default="prototype-failed")
parser.add_argument("--log-name", default="camera-run.jsonl")
args = parser.parse_args()
app = args.app.resolve(strict=True)
if app.suffix != ".app" or not 30 <= args.timeout <= 300:
    parser.error("Expected a diagnostic .app and a 30–300 second deadline")
if any(Path(name).name != name or name in ("", ".", "..") for name in (args.executable, args.log_name)):
    parser.error("Executable and log must be local file names")
executable = app / "Contents/MacOS" / args.executable
if not executable.is_file():
    parser.error("Expected the native diagnostic executable")
out = app.parent
result_path = out / "supervisor-result.json"
log = out / args.log_name
if result_path.exists() or log.exists():
    parser.error("Result or run log already exists; use a new output directory")
def owned_processes():
    listing = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True, timeout=5)
    return [int(parts[0]) for line in listing.splitlines()
            if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == str(executable)]
if owned_processes():
    parser.error("This exact diagnostic is already running")
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, env=env)
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
identity = {str(p.relative_to(app)): sha(p) for p in app.rglob("*") if p.is_file() and not p.is_symlink()}
(out / "signed-artifact-identity.json").write_text(json.dumps(identity, indent=2) + "\n")
supervisor_hash = sha(Path(__file__))
fixture = args.fixture.resolve(strict=True) if args.fixture else None
if fixture and not fixture.is_file():
    parser.error("Expected a regular acoustic fixture file")
fixture_identity = {"path": str(fixture), "sha256": sha(fixture), "bytes": fixture.stat().st_size} if fixture else None
stop_fixture = threading.Event()
fixture_ready = threading.Event()
fixture_lock = threading.Lock()
fixture_process = None
fixture_errors = []
fixture_intervals = []

def stop_process(process):
    if process is None or process.poll() is not None:
        return
    try:
        process.terminate()
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        process.wait(timeout=3)

def play_fixture():
    global fixture_process
    process = None
    try:
        while not stop_fixture.is_set():
            process = subprocess.Popen(["/usr/bin/afplay", str(fixture)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            interval = {"start_uptime": time.monotonic(), "pid": process.pid}
            with fixture_lock:
                fixture_process = process
                fixture_intervals.append(interval)
            fixture_ready.set()
            while process.poll() is None and not stop_fixture.wait(.1):
                pass
            natural_exit = process.poll()
            stop_process(process)
            with fixture_lock:
                interval.update(end_uptime=time.monotonic(), exit=process.returncode,
                                cleanup_termination=natural_exit is None)
                fixture_process = None
            if natural_exit not in (None, 0):
                raise RuntimeError("Acoustic fixture playback failed")
    except Exception as error:
        fixture_errors.append(str(error))
    finally:
        fixture_ready.set()
        try:
            stop_process(process)
        except Exception as error:
            fixture_errors.append("Fixture cleanup: " + str(error))

thread = threading.Thread(target=play_fixture, daemon=True) if fixture else None
started = time.monotonic()
process = None
failure = None
cleanup_errors = []
launch_started = launch_finished = None

def cleanup_step(label, operation):
    try:
        operation()
    except Exception as error:
        cleanup_errors.append(label + ": " + str(error))

def stop_diagnostic():
    global failure
    remaining = owned_processes()
    if remaining:
        failure = failure or "Diagnostic still running after launcher returned"
    for sig, seconds in ((signal.SIGTERM, 3), (signal.SIGKILL, 3)):
        for pid in remaining:
            if pid not in owned_processes():
                continue
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + seconds
        while (remaining := owned_processes()) and time.monotonic() < deadline:
            time.sleep(.1)
        if not remaining:
            return
    raise RuntimeError("Exact diagnostic process did not terminate")

def stop_playback():
    stop_fixture.set()
    if thread and thread.ident is not None:
        thread.join(timeout=4)
        if thread.is_alive():
            with fixture_lock:
                active = fixture_process
            stop_process(active)
            thread.join(timeout=4)
        if thread.is_alive():
            raise RuntimeError("Fixture worker did not terminate")

try:
    if thread:
        thread.start()
        if not fixture_ready.wait(timeout=5) or fixture_errors or not fixture_intervals:
            raise RuntimeError("Acoustic fixture did not start")
    launch_started = time.monotonic()
    process = subprocess.Popen(["open", "-n", "-W", str(app)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    process.wait(timeout=args.timeout)
    launch_finished = time.monotonic()
    if process.returncode:
        raise RuntimeError("LaunchServices reported failure")
except Exception as error:
    failure = str(error)
finally:
    stop_fixture.set()
    # Every owned resource gets cleanup even if another cleanup operation fails.
    cleanup_step("diagnostic", stop_diagnostic)
    cleanup_step("launcher", lambda: stop_process(process))
    cleanup_step("fixture", stop_playback)
    unregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    cleanup_step("unregister", lambda: subprocess.run([unregister, "-u", str(app)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=10))
events = []
if log.exists():
    for line in log.read_text(errors="replace").splitlines():
        try:
            value = json.loads(line)
            if isinstance(value, dict) and "event" in value:
                events.append(value)
        except json.JSONDecodeError:
            pass
try:
    unchanged = all((app / name).is_file() and sha(app / name) == digest for name, digest in identity.items())
    fixture_unchanged = fixture is None or sha(fixture) == fixture_identity["sha256"]
except OSError as error:
    unchanged = fixture_unchanged = False
    failure = failure or "Artifact verification: " + str(error)
pass_events = {args.pass_event, "duplex-pass"}
fail_events = {args.fail_event, "prototype-failed"}
terminal_events = [row for row in events if row["event"] in pass_events | fail_events]
def terminal_pass(row):
    if row["event"] == "duplex-pass":
        seconds = row.get("soakSeconds", 0)
        if type(seconds) is not int or seconds < 0:
            return False
        if seconds > 0 and row.get("soakQualityPassed") is not True:
            return False
    return row["event"] in pass_events and all(row[key] is True for key in ("pass", "passed") if key in row)
passed = any(terminal_pass(row) for row in terminal_events)
failed = any(row["event"] in fail_events or not terminal_pass(row) for row in terminal_events)
with fixture_lock:
    intervals = [dict(row) for row in fixture_intervals]
complete_intervals = [row for row in intervals if "end_uptime" in row]
coverage = None
fixture_brackets_run = fixture is None
if fixture:
    duration = launch_finished - launch_started if launch_started is not None and launch_finished is not None else None
    covered = sum(max(0, min(row["end_uptime"], launch_finished) - max(row["start_uptime"], launch_started))
                  for row in complete_intervals) if duration is not None else None
    fixture_brackets_run = bool(complete_intervals) and duration is not None and \
        complete_intervals[0]["start_uptime"] <= launch_started and complete_intervals[-1]["end_uptime"] >= launch_finished
    coverage = {"basis": "Observed playback process intervals; not measured acoustic output",
                "launch_start_uptime": launch_started, "launch_end_uptime": launch_finished,
                "brackets_launch": fixture_brackets_run,
                "observed_covered_seconds": covered,
                "observed_coverage_fraction": covered / duration if duration and covered is not None else None,
                "maximum_restart_gap_seconds": max((max(0, after["start_uptime"] - before["end_uptime"])
                    for before, after in zip(complete_intervals, complete_intervals[1:])), default=0),
                "intervals": intervals}
result = {"passed": passed and not failed and not failure and not cleanup_errors and not fixture_errors and unchanged
                    and fixture_unchanged and fixture_brackets_run,
          "duration_seconds": time.monotonic() - started, "app": str(app),
          "artifact_identity_unchanged": unchanged, "failure": failure,
          "supervisor_sha256": supervisor_hash,
          "executable": args.executable, "log_name": args.log_name, "cleanup_errors": cleanup_errors,
          "fixture_errors": fixture_errors, "fixture_used": bool(args.fixture),
          "fixture_identity": fixture_identity, "fixture_identity_unchanged": fixture_unchanged,
          "fixture_process_coverage": coverage,
          "events": len(events), "terminal_events": terminal_events,
          "limits": "Native prefixed SDK path; no proprietary wrapper or acoustic intelligibility qualification"}
result_path.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result))
if not result["passed"]:
    raise SystemExit(1)
