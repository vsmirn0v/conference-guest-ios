#!/usr/bin/env python3
"""Extract production admission code and test it without native SDK or hardware."""
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
AUDIO = 'Experiments/NativeGuest/GuestSystemAudio.swift'
SHARED = 'Shared/GuestAudioOwnerLease.swift'
GUEST = 'NativeMacGuest/Engines/NativeDesktopGuestEngine.swift'
EXTERNAL = 'NativeMacGuest/Engines/NativeDesktopExternalSession.swift'
FAILURE_MARKER = 'PRIVATE_CHECK_ASSERTION_FAILURE: '

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


def sha(data):
    return hashlib.sha256(data).hexdigest()


def intended_rejection(result, assertion):
    """A crash, timeout or unrelated failed assertion is not mutation coverage."""
    return result.returncode != 0 and FAILURE_MARKER + assertion in result.stderr.splitlines()


def run(repository, output):
    sources, receipts = {}, {}
    for relative in (AUDIO, SHARED, GUEST, EXTERNAL):
        sources[relative] = (repository / relative).read_text()

    def unit(relative, prefix):
        value, line = declaration(sources[relative], prefix)
        key = relative + '::' + prefix
        if key in receipts:
            raise ValueError('Duplicate extraction receipt: ' + key)
        receipts[key] = {'path': relative, 'symbol': prefix, 'line': line, 'sha256': sha(value.encode())}
        return value

    units = [unit(AUDIO, 'enum GuestVPIOReleasePolicy:'), unit(AUDIO, 'struct GuestPrivateCheckAdmission'),
             unit(SHARED, 'struct GuestPrivateInputLeasePolicy'), unit(SHARED, 'struct GuestInputActivationPolicy')]
    prefixes = ['private func revokePrivateCheckAdmission(', 'private func privateCheckObservation(',
        'private func privateCheckLive(', 'private func finishPrivateCheck(', 'private func drainPrivateCheck(',
        'private func quarantinePrivateCheck(', 'private func endAdmittedPrivateCheck(',
        'private func beginAdmittedPrivateCheck(', 'func setLocalPlayoutIntent(',
        'func invalidateStoppedInputPreparation(', 'func shutdown(', 'private final class Completion:',
        'private func perform(', 'private func applyAvailability(']
    methods = [unit(AUDIO, prefix) for prefix in prefixes]
    admission_template = (TESTS / 'PrivateCheckAdmissionTests.swift').read_text()
    text = admission_template.replace('// INSERT PRODUCTION DECLARATIONS', '\n\n'.join(units)).replace(
        '// INSERT PRODUCTION METHODS', '\n\n'.join(methods))
    adapter_template = (TESTS / 'PrivateCheckAdmissionAdapterTests.swift').read_text()
    adapter = adapter_template
    for label, relative in [('GUEST', GUEST), ('EXTERNAL', EXTERNAL)]:
        methods = [unit(relative, 'func startPrivateAudioCheck()'), unit(relative, 'func stopPrivateAudioCheck()')]
        adapter = adapter.replace('// INSERT ' + label + ' METHODS', '\n\n'.join(methods))
    if len(receipts) != 22:
        raise ValueError('Expected 22 source-qualified extraction receipts')
    (output / 'extraction.json').write_text(json.dumps(receipts, indent=2) + '\n')

    results = {}
    def execute(name, content, flags, assertion=None):
        source_path, binary = output / (name + '.swift'), output / name
        source_path.write_text(content)
        command = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', *flags,
                   str(source_path), '-o', str(binary)]
        compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
        (output / (name + '-compile.log')).write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise RuntimeError(name + ' did not compile; compiler failure is not mutation coverage')
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15,
            env={**os.environ, 'SWIFT_BACKTRACE': 'disable'})
        (output / (name + '.log')).write_text(result.stdout + result.stderr)
        passed = intended_rejection(result, assertion) if assertion else result.returncode == 0
        results[name] = {'exitCode': result.returncode, 'expectedAssertion': assertion,
                         'intendedAssertionObserved': bool(assertion and FAILURE_MARKER + assertion in result.stderr.splitlines()),
                         'passed': passed}
        if not passed:
            raise RuntimeError(name + ' failed its expected outcome; see retained log')
        print(name + ': ' + ('intended assertion rejected mutation' if assertion else 'PASS'), flush=True)

    # Verify the mutation result gate itself rejects unrelated crashes/assertions.
    for code, stderr, expected in [(0, FAILURE_MARKER + 'expected', False),
        (-5, '', False), (-5, FAILURE_MARKER + 'unrelated', False),
        (-5, FAILURE_MARKER + 'expected\n', True)]:
        result = subprocess.CompletedProcess([], code, '', stderr)
        if intended_rejection(result, 'expected') != expected:
            raise RuntimeError('Mutation result gate self-check failed')

    flags = ['-D', 'ROCK_VPIO_BUILTIN_RELEASE', '-D', 'ROCK_STOPPED_INPUT_GRAPH']
    execute('positive', text, flags)
    mutations = {
        'cached-selection': (
            'let path = GuestPrivateCheckAdmission.select(self.vpioPolicy, context: context, before: before, after: after)',
            'let path = self.vpioPolicy.privateCheck(context)', 'isolated only and meter committed', 1),
        'deadline-removed': ('&& now < value.deadline', '', 'deadline includes all admission work', 1),
        'pending-sound-revocation-removed': ('privateCheckAdmission.revoke(pendingOnly: true)',
            '_ = privateCheckAdmission.ticket', 'soundABA at queue cannot commit', 1),
        'unscoped-drain': ('guard let ticket = locked({ privateCheckAdmission.ticket }), ticket.id == id else { return true }',
            'guard let ticket = locked({ privateCheckAdmission.ticket }) else { return true }', 'late A cannot disable B', 1),
        'entry-revalidation-removed': ('self.privateCheckObservation(module) == after',
            '{ _ = self.privateCheckObservation(module); return true }()', 'native state drift before entry rejects', 2),
        'ordinary-entry-hook-unwired': ('guard beforeNative?() != false, admission?() != false else { return false }',
            'guard admission?() != false else { return false }', 'ordinary native-entry hook must execute and reject drift', 1),
        'shutdown-owner-retirement-removed': ('self.privateCheckFactory = nil', '_ = self.privateCheckFactory',
            'confirmed shutdown retires admission and factory', 1),
    }
    for name, (before, after, assertion, count) in mutations.items():
        if text.count(before) != count:
            raise ValueError(f'{name}: expected {count} exact mutation preimages, found {text.count(before)}')
        execute('mutant-' + name, text.replace(before, after), flags, assertion)
    for label, adapter_flags in [('standard', []), ('vpio', ['-D', 'ROCK_VPIO_BUILTIN_RELEASE']),
        ('r6', ['-D', 'DEBUG', '-D', 'ROCK_COREAUDIO_DUPLEX_R6'])]:
        execute('adapters-' + label, adapter, adapter_flags)
    for relative, original in sources.items():
        if (repository / relative).read_text() != original:
            raise RuntimeError('Production source changed during test: ' + relative)
    report = {'schema': 2, 'repository': str(repository), 'hardwareOpened': False, 'networkUsed': False,
        'nativeAPI': 'mock boundary; not a native runtime replay', 'mutationResultGateSelfChecks': 4,
        'sourceQualifiedReceipts': len(receipts), 'sources': {key: sha(value.encode()) for key, value in sources.items()},
        'testInputs': {path.name: sha(path.read_bytes()) for path in
            [Path(__file__).resolve(), TESTS / 'PrivateCheckAdmissionTests.swift', TESTS / 'PrivateCheckAdmissionAdapterTests.swift']},
        'extractionSHA256': sha((output / 'extraction.json').read_bytes()), 'results': results}
    (output / 'test-results.json').write_text(json.dumps(report, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', type=Path, default=TESTS.parents[1],
                        help='Production source checkout or immutable source snapshot')
    parser.add_argument('--evidence-dir', type=Path, help='New absent directory; preserve sources, logs and receipts')
    arguments = parser.parse_args()
    repository = arguments.repository.resolve()
    if arguments.evidence_dir:
        output = arguments.evidence_dir.resolve()
        output.mkdir(parents=True, exist_ok=False)
        run(repository, output)
    else:
        with tempfile.TemporaryDirectory(prefix='private-check-admission-') as temporary:
            run(repository, Path(temporary))


if __name__ == '__main__':
    main()
