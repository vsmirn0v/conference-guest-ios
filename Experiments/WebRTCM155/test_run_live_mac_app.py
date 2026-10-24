"""Supervisor regressions using temporary files and mocked operating-system calls.

Run from the repository root:
    python3 -m unittest discover -s Experiments/WebRTCM155 -p test_run_live_mac_app.py -v

No application, playback, signing, process signal or registration operation runs.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("run-live-mac-app.py").resolve()


class SupervisorTests(unittest.TestCase):
    def run_supervisor(self, event, *, custom=False, fixture=False, ps_failure=False, stale_log=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app = root / "Probe.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            executable = "LiveSharingProbe" if custom else "NativeGuestProbe"
            (app / "Contents/MacOS" / executable).write_bytes(b"mock executable")
            log_name = "run.jsonl" if custom else "camera-run.jsonl"
            if stale_log:
                (root / log_name).write_text('{"event":"prototype-pass"}\n')
            calls = []
            ps_calls = 0

            class Process:
                next_pid = 100

                def __init__(self, command, **kwargs):
                    calls.append(command)
                    self.command = command
                    self.returncode = None
                    self.pid = Process.next_pid
                    Process.next_pid += 1
                    if command[0] == "open":
                        (root / log_name).write_text(json.dumps(event) + "\n")
                    elif command[0] != "/usr/bin/afplay":
                        raise AssertionError("Unexpected process request: " + repr(command))

                def poll(self):
                    return self.returncode

                def wait(self, timeout=None):
                    if self.command[0] == "open":
                        # Give the fixture worker an observable interval; no media runs.
                        time.sleep(.02)
                        self.returncode = 0
                    return self.returncode

                def terminate(self):
                    self.returncode = -15

                def kill(self):
                    self.returncode = -9

            def check_output(command, **kwargs):
                nonlocal ps_calls
                self.assertEqual(command, ["ps", "-axo", "pid=,comm="])
                ps_calls += 1
                if ps_failure and ps_calls > 1:
                    raise subprocess.CalledProcessError(1, command)
                return ""

            argv = [str(SCRIPT), "--app", str(app)]
            if custom:
                argv += ["--executable", executable, "--pass-event", "live-sharing-complete",
                         "--fail-event", "live-sharing-failed", "--log-name", log_name]
            if fixture:
                wave = root / "synthetic.wav"
                wave.write_bytes(b"mock synthetic fixture")
                argv += ["--fixture", str(wave)]
            with patch.object(sys, "argv", argv), \
                 patch.object(subprocess, "run", side_effect=lambda command, **kwargs: calls.append(command)), \
                 patch.object(subprocess, "check_output", side_effect=check_output), \
                 patch.object(subprocess, "Popen", side_effect=Process) as launch, \
                 patch.object(os, "kill") as signal_process, \
                 contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                exit_code = 0
                try:
                    runpy.run_path(str(SCRIPT), run_name="__main__")
                except SystemExit as error:
                    exit_code = error.code
                signal_process.assert_not_called()
                if stale_log:
                    self.assertEqual(exit_code, 2)
                    launch.assert_not_called()
                    self.assertFalse((root / "supervisor-result.json").exists())
                    return None
            result = json.loads((root / "supervisor-result.json").read_text())
            self.assertEqual(exit_code, 0 if result["passed"] else 1)
            self.assertTrue(any(command[0].endswith("/lsregister") and command[1:] == ["-u", str(app)]
                                for command in calls), "Unregistration must survive another cleanup failure")
            return result

    def test_default_pass(self):
        self.assertTrue(self.run_supervisor({"event": "prototype-pass"})["passed"])

    def test_custom_terminal_pass(self):
        result = self.run_supervisor({"event": "live-sharing-complete", "pass": True}, custom=True)
        self.assertTrue(result["passed"])
        self.assertEqual(result["executable"], "LiveSharingProbe")
        self.assertEqual(result["log_name"], "run.jsonl")

    def test_explicit_false_terminal_rejected(self):
        self.assertFalse(self.run_supervisor({"event": "live-sharing-complete", "pass": False}, custom=True)["passed"])

    def test_nonboolean_terminal_rejected(self):
        self.assertFalse(self.run_supervisor({"event": "live-sharing-complete", "pass": 1}, custom=True)["passed"])

    def test_cleanup_failure_does_not_skip_unregistration(self):
        result = self.run_supervisor({"event": "prototype-pass"}, ps_failure=True)
        self.assertFalse(result["passed"])
        self.assertTrue(result["cleanup_errors"])

    def test_fixture_identity_and_process_coverage(self):
        result = self.run_supervisor({"event": "prototype-pass"}, fixture=True)
        self.assertTrue(result["passed"])
        self.assertTrue(result["fixture_identity_unchanged"])
        self.assertEqual(result["fixture_identity"]["bytes"], len(b"mock synthetic fixture"))
        coverage = result["fixture_process_coverage"]
        self.assertTrue(coverage["brackets_launch"])
        self.assertAlmostEqual(coverage["observed_coverage_fraction"], 1)
        self.assertEqual(len(coverage["intervals"]), 1)
        self.assertTrue(coverage["intervals"][0]["cleanup_termination"])

    def test_stale_log_rejected_before_launch(self):
        self.run_supervisor({"event": "prototype-pass"}, stale_log=True)

    def test_positive_soak_requires_explicit_true_quality(self):
        for quality in (None, False, 1, "true"):
            with self.subTest(quality=quality):
                event = {"event": "duplex-pass", "soakSeconds": 80}
                if quality is not None:
                    event["soakQualityPassed"] = quality
                self.assertFalse(self.run_supervisor(event)["passed"])

    def test_positive_soak_passes_with_true_quality(self):
        self.assertTrue(self.run_supervisor({"event": "duplex-pass", "soakSeconds": 80,
                                             "soakQualityPassed": True})["passed"])

    def test_no_soak_does_not_require_quality_result(self):
        self.assertTrue(self.run_supervisor({"event": "duplex-pass", "soakSeconds": 0,
                                             "soakQualityPassed": None})["passed"])

    def test_malformed_soak_duration_rejected(self):
        for seconds in (-1, True, "80"):
            with self.subTest(seconds=seconds):
                self.assertFalse(self.run_supervisor({"event": "duplex-pass", "soakSeconds": seconds,
                                                     "soakQualityPassed": True})["passed"])


if __name__ == "__main__":
    unittest.main()
