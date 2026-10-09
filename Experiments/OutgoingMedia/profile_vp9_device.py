#!/usr/bin/env python3
"""Record one <60-second counterbalanced physical decoder measurement pair."""
import argparse
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True)
parser.add_argument("--trace-device", help="Instruments device name, if its UDID lookup is unavailable")
parser.add_argument("--derived-data", required=True)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--reverse", action="store_true")
parser.add_argument("--invitation", required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer",
           TEST_RUNNER_ROCKNROLL_MEASURE_VP9="1", TEST_RUNNER_ROCKNROLL_TEST_TELEMOST_INVITE=args.invitation)
if args.reverse:
    env["TEST_RUNNER_ROCKNROLL_MEASURE_REVERSE"] = "1"
command = ["xcodebuild", "-project", "RockNRoll.xcodeproj", "-scheme", "RockNRoll", "-configuration", "Debug",
           "-destination", "platform=iOS,id=" + args.device, "-derivedDataPath", args.derived_data,
           "-disableAutomaticPackageResolution", "-parallel-testing-enabled", "NO",
           "-only-testing:RockNRollTests/VP9LiveMeasurementTests/testMatchedIncomingDecoderEnergy", "test-without-building"]
log = args.output / "test.log"
with log.open("w") as stream, (args.output / "trace.log").open("w") as trace_log:
    test = subprocess.Popen(command, env=env, stdout=stream, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 100
    while "CODEC_MEASURE_WAIT" not in log.read_text(errors="replace"):
        if test.poll() is not None or time.monotonic() > deadline:
            test.terminate()
            raise SystemExit("Measurement did not start; see " + str(log))
        time.sleep(0.2)
    # The full template also includes Location Energy Model (no all-process
    # support). Its attach mode crashes on Xcode 27 when the XCTest host exits.
    trace = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Blank", "--instrument", "Power Profiler",
                              "--device", args.trace_device or args.device, "--all-processes", "--time-limit", "55s",
                              "--output", str(args.output / "power.trace")],
                             env=env, stdout=trace_log, stderr=subprocess.STDOUT)
    result = test.wait(timeout=75)
    trace_result = trace.wait(timeout=75)
    for line in log.read_text(errors="replace").splitlines():
        if "CODEC_MEASURE_" in line or " error: " in line or "TEST SUCCEEDED" in line:
            print(line)
    print("test_exit", result, "trace_exit", trace_result)
    raise SystemExit(result or trace_result)
