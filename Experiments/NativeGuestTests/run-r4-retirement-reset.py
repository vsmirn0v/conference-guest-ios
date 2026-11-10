#!/usr/bin/env python3
"""Reconstruct the exact R4 native source from committed artifacts and test its retirement blocks."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

TESTS = Path(__file__).resolve().parent
SOURCE = "modules/audio_device/audio_engine_device.mm"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def member(archive, name):
    matches = [entry for entry in archive.getmembers() if entry.name == name]
    if len(matches) != 1 or not matches[0].isfile():
        raise ValueError("Missing, duplicate or nonregular archive member: " + name)
    return archive.extractfile(matches[0]).read()


def archived(repository, profile):
    root = repository / "Dependencies/native-macos"
    lock_bytes = (root / profile).read_bytes()
    lock = json.loads(lock_bytes)
    if Path(lock["archive"]).name != lock["archive"]:
        raise ValueError("Archive must be a filename")
    data = (root / lock["archive"]).read_bytes()
    if sha(data) != lock["archiveSHA256"]:
        raise ValueError("Archive differs from committed lock")
    archive = tarfile.open(fileobj=io.BytesIO(data))
    evidence_bytes = member(archive, "build-evidence.json")
    if sha(evidence_bytes) != lock["files"]["build-evidence.json"]["sha256"]:
        raise ValueError("Build evidence differs from lock inventory")
    return archive, json.loads(evidence_bytes), sha(lock_bytes)


def closing_brace(text, opening):
    depth, index = 0, opening
    while index < len(text):
        if text.startswith("//", index):
            end = text.find("\n", index)
            index = len(text) if end < 0 else end
            continue
        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            if end < 0:
                raise ValueError("Unterminated C++ comment")
            index = end + 2
            continue
        if text[index] in "\"'":
            quote = text[index]
            index += 1
            while index < len(text):
                if text[index] == "\\":
                    index += 2
                elif text[index] == quote:
                    index += 1
                    break
                else:
                    index += 1
            continue
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise ValueError("Unclosed C++ scope")


def scope(text, prefix):
    if text.count(prefix) != 1:
        raise ValueError("Expected one production scope: " + prefix)
    start = text.index(prefix)
    opening = text.index("{", start + len(prefix))
    return text[start:closing_brace(text, opening) + 1]


def collect(source):
    body = scope(source, "int32_t AudioEngineDevice::ApplyDeviceEngineState(")
    preparation = "const bool no_engine = !engine_device_ && !input_node_instantiated_;"
    entry = "bool input_instance_retired = false;"
    if body.count(entry) != 1 or source.count(preparation) != 1:
        raise ValueError("Native retirement/preparation declaration changed")
    return {"entry": entry,
            "release": scope(body, "if (state.prev.IsAnyEnabled() && !state.next.IsAnyEnabled())"),
            "cleanup": scope(body, "if (!engine_device_)"), "preparation": preparation}


def run(repository, output, negative_controls):
    r3, e3, r3_lock = archived(repository, "sdk.vpio-private-r3.lock.json")
    r4, e4, r4_lock = archived(repository, "sdk.vpio-private-r4.lock.json")
    if e4["baseProfileSHA256"] != r3_lock:
        raise ValueError("R4 does not identify the retained R3 base")
    overlay = member(r3, e3["sourceOverlay"])
    if sha(overlay) != e3["sourceOverlaySHA256"]:
        raise ValueError("R3 overlay hash differs from its evidence")
    with tarfile.open(fileobj=io.BytesIO(overlay)) as archive:
        baseline = member(archive, SOURCE)
    baseline_entry = next(entry for entry in e3["sourceFiles"] if entry["path"] == SOURCE)
    if sha(baseline) != baseline_entry["sha256"]:
        raise ValueError("R3 source differs from its manifest")
    patch = (repository / "Experiments/WebRTCM156/private-input-experiment-r4.patch").read_bytes()
    if sha(patch) != e4["sourcePatchSHA256"] or patch != member(r4, "provenance/source-patch.patch"):
        raise ValueError("R4 workspace and archived patches differ")
    manifest = member(r4, "provenance/source-manifest.json")
    if sha(manifest) != e4["sourceManifestSHA256"]:
        raise ValueError("R4 source manifest differs from its evidence")
    source_path = output / "reconstructed" / SOURCE
    source_path.parent.mkdir(parents=True)
    source_path.write_bytes(baseline)
    patch_path = output / "R4.patch"
    patch_path.write_bytes(patch)
    # Use an isolated repository so Git cannot discover or mutate the real checkout.
    subprocess.run(["git", "init", "--quiet", str(output / "reconstructed")], check=True)
    subprocess.run(["git", "-C", str(output / "reconstructed"), "apply",
                    "--include=" + SOURCE, str(patch_path)], check=True, capture_output=True, text=True)
    source_bytes = source_path.read_bytes()
    expected = json.loads(manifest)["entries"][SOURCE]["sha256"]
    if sha(source_bytes) != expected:
        raise ValueError("Patched R3 source does not reconstruct exact archived R4 source")
    units = collect(source_bytes.decode())
    template = (TESTS / "R4RetirementResetTests.cc").read_text()
    for name, body in units.items():
        marker = "// @production " + name
        if template.count(marker) != 1:
            raise ValueError("Missing or duplicate production marker: " + name)
        template = template.replace(marker, body)
    mutations = {"positive": template}
    if negative_controls:
        mutations.update({"no-reset": template.replace("input_node_instantiated_ = false;", "(void)input_node_instantiated_;"),
                          "absent-engine-grants-proof": template.replace("bool input_instance_retired = false;", "bool input_instance_retired = true;"),
                          "ignore-stop-result": template.replace("input_instance_retired = units_stopped;", "input_instance_retired = true;"),
                          "cleanup-live-engine": template.replace("if (!engine_device_)", "if (true)")})
        for owner in ("source_node_", "sink_node_", "input_mixer_node_", "converter_ref_", "converter_buffer_", "configuration_observer_"):
            mutations["ignore-" + owner] = re.sub(r"\s*&&\s*!" + re.escape(owner) + r"\b", "", template)
    report = {"status": "running", "scope": "Exact native release/cleanup blocks with memory-only stop/observer/ownership stubs; no audio APIs or SDK/app rebuild",
              "sourceSHA256": expected, "r3LockSHA256": r3_lock, "r4LockSHA256": r4_lock,
              "patchSHA256": sha(patch), "runnerSHA256": sha(Path(__file__).read_bytes()),
              "templateSHA256": sha((TESTS / "R4RetirementResetTests.cc").read_bytes()),
              "productionUnitSHA256": {name: sha(text.encode()) for name, text in units.items()}, "runs": [],
              "limitations": ["StopDeviceEngineAudioUnits, observer callbacks and reference retention are stubs.",
                              "Intervening native graph/node teardown and AVAudioEngine behavior are not executed.",
                              "Only the archived native .mm file is reconstructed; full SDK source replay remains incomplete."]}
    environment = dict(os.environ)
    environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    environment["ASAN_OPTIONS"] = "detect_leaks=0:halt_on_error=1"
    environment["UBSAN_OPTIONS"] = "halt_on_error=1"
    try:
        for name, text in mutations.items():
            if name != "positive" and text == template:
                raise ValueError("Negative control did not mutate a production statement: " + name)
            path, binary = output / (name + ".cc"), output / name
            path.write_text(text)
            command = ["xcrun", "--sdk", "macosx", "clang++", "-std=c++17", "-DTARGET_OS_OSX=1", "-Wall", "-Wextra", "-Werror",
                       "-O1", "-g", "-fno-omit-frame-pointer", "-fsanitize=address,undefined", str(path), "-o", str(binary)]
            compiled = subprocess.run(command, env=environment, capture_output=True, text=True)
            (output / (name + ".compile.log")).write_text(compiled.stdout + compiled.stderr)
            if compiled.returncode:
                raise RuntimeError("Native test compilation failed: " + name)
            completed = subprocess.run([str(binary)], env=environment, capture_output=True, text=True)
            row = {"name": name, "command": command, "compileExitCode": compiled.returncode, "exitCode": completed.returncode,
                   "expectedFailure": name != "positive", "output": (completed.stdout + completed.stderr).strip(), "generatedSHA256": sha(path.read_bytes())}
            report["runs"].append(row)
            (output / (name + ".log")).write_text(completed.stdout + completed.stderr)
            if (name == "positive") != (completed.returncode == 0):
                raise RuntimeError("Unexpected native retirement test result: " + name)
            if name != "positive" and (completed.returncode != 1 or not completed.stderr.startswith("FAIL: ")):
                raise RuntimeError("Negative control must fail its assertion, not crash: " + name)
            print(name + ": " + row["output"], flush=True)
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        (output / "results.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=TESTS.parents[1])
    parser.add_argument("--evidence-dir", type=Path)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    if args.evidence_dir:
        output = args.evidence_dir.resolve()
        output.mkdir(parents=True, exist_ok=False)
        run(args.repository.resolve(), output, args.negative_controls)
    else:
        with tempfile.TemporaryDirectory(prefix="native-r4-retirement-") as temporary:
            run(args.repository.resolve(), Path(temporary), args.negative_controls)


if __name__ == "__main__":
    main()
