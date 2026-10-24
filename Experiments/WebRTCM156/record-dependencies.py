#!/usr/bin/env python3
"""Record the isolated M156 checkout and compiler identities without syncing."""
import ast
import hashlib
import json
import pathlib
import subprocess
import sys


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit('usage: record-dependencies.py WORKSPACE OUTPUT.json')
    workspace = pathlib.Path(sys.argv[1]).resolve(strict=True)
    output = pathlib.Path(sys.argv[2]).resolve()
    if output.exists() or output.is_relative_to(workspace / 'src'):
        raise SystemExit('output must be new and outside src')
    entries_text = (workspace / '.gclient_entries').read_text()
    prefix, expression = entries_text.split('=', 1)
    if prefix.strip() != 'entries':
        raise SystemExit('unexpected gclient entries format')
    entries = ast.literal_eval(expression.strip())
    if not isinstance(entries, dict) or entries.get('src') is not None:
        raise SystemExit('unexpected gclient solution')
    checkouts: dict[str, dict[str, str]] = {}
    non_git: dict[str, str] = {}
    for relative, url in sorted(entries.items()):
        if relative == 'src':
            continue
        if not isinstance(relative, str) or not relative.startswith('src/') or '..' in pathlib.PurePosixPath(relative).parts:
            raise SystemExit(f'invalid dependency path: {relative!r}')
        if not isinstance(url, str):
            raise SystemExit(f'invalid dependency URL: {relative}')
        if ':' in relative or not url.startswith('https://'):
            non_git[relative] = url
            continue
        path = workspace / relative
        expected = url.rsplit('@', 1)[-1]
        actual = run('git', '-C', str(path), 'rev-parse', 'HEAD')
        if len(expected) != 40 or actual != expected:
            raise SystemExit(f'checkout revision mismatch: {relative}: {actual} != {expected}')
        if subprocess.run(['git', '-C', str(path), 'diff', '--quiet', 'HEAD', '--']).returncode:
            raise SystemExit(f'tracked dependency changes: {relative}')
        checkouts[relative] = {'revision': actual, 'url': url.rsplit('@', 1)[0]}
    tools = {
        name: sha256(workspace / path)
        for name, path in {
            'clang': 'src/third_party/llvm-build/Release+Asserts/bin/clang',
            'gn': 'src/buildtools/mac/gn',
            'ninja': 'src/third_party/ninja/ninja',
        }.items()
    }
    report = {
        'schemaVersion': 1,
        'gitCheckouts': checkouts,
        'downloadedNonGitDeclarations': non_git,
        'toolSHA256': tools,
        'gclientEntriesSHA256': sha256(workspace / '.gclient_entries'),
        'depsSHA256': sha256(workspace / 'src/DEPS'),
        'xcodeVersion': run('/usr/bin/env', 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer', 'xcodebuild', '-version'),
        'limitations': 'CIPD and GCS package bytes are not independently audited by this recorder.',
    }
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(f"verified {len(checkouts)} clean pinned Git checkouts; {len(non_git)} non-Git declarations recorded")


if __name__ == '__main__':
    main()
