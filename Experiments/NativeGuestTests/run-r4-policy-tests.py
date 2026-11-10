#!/usr/bin/env python3
"""Compile memory-only R4 assertions against declarations from this checkout."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
TESTS = Path(__file__).resolve().parent
UNITS = {
    "lease": ("Shared/GuestAudioOwnerLease.swift", "struct GuestPrivateInputLeasePolicy"),
    "policy": ("Experiments/NativeGuest/GuestSystemAudio.swift", "enum GuestVPIOReleasePolicy:"),
    "captureGuard": ("NativeMacGuest/MicrophoneActivationExperiment.swift", "private func privateSoundCaptureClosed("),
    "senderTrackFlags": ("Experiments/NativeGuest/GuestEngine.swift", "var audioSenderTrackEnabledForTesting:"),
    "senderFullInventory": ("Experiments/NativeGuest/GuestEngine.swift", "var audioSendersForTesting:"),
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def code_mask(text):
    """Keep offsets while masking Swift comments and quoted string contents."""
    masked = list(text)
    index = 0
    while index < len(text):
        start = index
        if text.startswith("//", index):
            end = text.find("\n", index)
            index = len(text) if end < 0 else end
        elif text.startswith("/*", index):
            depth = 1
            index += 2
            while depth:
                if index >= len(text):
                    raise ValueError("Unterminated Swift block comment")
                if text.startswith("/*", index):
                    depth += 1
                    index += 2
                elif text.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        else:
            quote = index
            while quote < len(text) and text[quote] == "#":
                quote += 1
            if quote >= len(text) or text[quote] != '"':
                index += 1
                continue
            hashes = text[index:quote]
            delimiter = ('"""' if text.startswith('"""', quote) else '"') + hashes
            index = quote + len(delimiter) - len(hashes)
            escape = "\\" + hashes
            while True:
                if index >= len(text):
                    raise ValueError("Unterminated Swift string")
                if text.startswith(escape, index):
                    index += len(escape) + 1
                elif text.startswith(delimiter, index):
                    index += len(delimiter)
                    break
                else:
                    index += 1
        for position in range(start, index):
            if masked[position] != "\n":
                masked[position] = " "
    return "".join(masked)


def declaration(text, prefix):
    masked = code_mask(text)
    matches = list(re.finditer(r"(?m)^[ \t]*" + re.escape(prefix), masked))
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one declaration: {prefix}")
    start = matches[0].start()
    while masked[start] in " \t":
        start += 1
    opening = masked.index("{", matches[0].end())
    depth = 0
    for end in range(opening, len(masked)):
        if masked[end] == "{":
            depth += 1
        elif masked[end] == "}":
            depth -= 1
            if depth == 0:
                return text[start:end + 1], text.count("\n", 0, start) + 1
    raise ValueError(f"Unterminated declaration: {prefix}")


def collect(repository):
    sources, units, receipts = {}, {}, {}
    for name, (relative, prefix) in UNITS.items():
        if relative not in sources:
            sources[relative] = (repository / relative).read_bytes()
        unit, line = declaration(sources[relative].decode(), prefix)
        units[name] = unit
        receipts[name] = {"path": relative, "line": line, "declaration": prefix,
                          "sha256": sha(unit.encode()), "sourceSHA256": sha(sources[relative])}
    return sources, units, receipts


def materialize(units):
    generated = {}
    templates = {}
    for name in ("R4VPIOPolicyTests.swift", "R4CaptureGuardTests.swift", "R4SenderTrackQueryTests.swift"):
        raw = (TESTS / name).read_bytes()
        text = raw.decode()
        templates[name] = sha(raw)
        if name == "R4VPIOPolicyTests.swift":
            text = "import Foundation\n" + units["lease"] + "\n" + units["policy"] + "\n" + text
        else:
            for unit in ("captureGuard",) if name == "R4CaptureGuardTests.swift" else ("senderTrackFlags", "senderFullInventory"):
                marker = "// @production " + unit
                if text.count(marker) != 1:
                    raise ValueError(f"Missing or duplicate production marker: {unit}")
                text = text.replace(marker, units[unit])
        if "// @production " in text:
            raise ValueError("Unresolved production marker")
        generated[name] = text
    return generated, templates


def run(repository, output):
    source_bytes, units, receipts = collect(repository)
    generated, templates = materialize(units)
    report = {"status": "running", "repository": str(repository), "runnerSHA256": sha(Path(__file__).read_bytes()), "productionUnits": receipts,
              "testSHA256": templates, "runs": [], "scope": "Foundation-only memory tests; no app, SDK, meeting or hardware"}
    environment = dict(os.environ)
    environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    environment["CLANG_MODULE_CACHE_PATH"] = str(output / "clang-modules")
    try:
        version = subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", "--version"], env=environment, capture_output=True, text=True, check=True)
        report["compiler"] = (version.stdout + version.stderr).strip()
        for name, source in generated.items():
            (output / name).write_text(source)
        cases = [
            ("policy-default", "R4VPIOPolicyTests.swift", []),
            ("policy-vpio", "R4VPIOPolicyTests.swift", ["ROCK_VPIO_BUILTIN_RELEASE"]),
            ("capture-guard", "R4CaptureGuardTests.swift", ["DEBUG"]),
            ("sender-query", "R4SenderTrackQueryTests.swift", ["DEBUG"]),
        ]
        for name, source, flags in cases:
            executable = output / name
            command = ["xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "5", "-warnings-as-errors",
                       "-parse-as-library", "-module-cache-path", str(output / "swift-modules")]
            for flag in flags:
                command += ["-D", flag]
            command += [str(output / source), "-o", str(executable)]
            compiled = subprocess.run(command, env=environment, capture_output=True, text=True)
            (output / (name + ".compile.log")).write_text(compiled.stdout + compiled.stderr)
            row = {"name": name, "command": command, "compileExitCode": compiled.returncode,
                   "generatedSHA256": sha((output / source).read_bytes())}
            report["runs"].append(row)
            if compiled.returncode:
                raise RuntimeError(f"Compile failed: {name}; see {output / (name + '.compile.log')}")
            completed = subprocess.run([str(executable)], env=environment, capture_output=True, text=True)
            (output / (name + ".log")).write_text(completed.stdout + completed.stderr)
            row.update(exitCode=completed.returncode, output=completed.stdout.strip(), executableSHA256=sha(executable.read_bytes()))
            if completed.returncode:
                raise RuntimeError(f"Assertions failed: {name}; see {output / (name + '.log')}")
            print(name + ": " + completed.stdout.strip(), flush=True)
        for relative, before in source_bytes.items():
            if (repository / relative).read_bytes() != before:
                raise RuntimeError(f"Production source changed during tests: {relative}; rerun on the final source")
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        (output / "results.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("PASS 4 production-extracted R4 cases; no hardware", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=TESTS.parents[1], help="Repository root; defaults to this runner's checkout")
    parser.add_argument("--evidence-dir", type=Path, help="New, absent directory for generated sources, commands, logs and binaries")
    arguments = parser.parse_args()
    repository = arguments.repository.resolve()
    if arguments.evidence_dir:
        output = arguments.evidence_dir.resolve()
        output.mkdir(parents=True, exist_ok=False)
        run(repository, output)
    else:
        with tempfile.TemporaryDirectory(prefix="native-r4-policy-") as temporary:
            run(repository, Path(temporary))


if __name__ == "__main__":
    main()
