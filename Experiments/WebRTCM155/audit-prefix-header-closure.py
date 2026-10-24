#!/usr/bin/env python3
"""Check projected prefix headers in memory; do not edit source or build an SDK."""
import argparse
import ast
import json
from pathlib import Path
import re
import plistlib
import prefix_overlay as p


def projected(before, patch):
    """Strict unified-diff parser; every context/removal must match source bytes."""
    after, lines, n = dict(before), patch.splitlines(keepends=True), 0
    while n < len(lines):
        if not lines[n].startswith('diff --git a/'):
            raise ValueError('Expected patch file boundary')
        name = lines[n][len('diff --git a/'):].split(' b/')[0]
        if lines[n + 1] != '--- a/' + name + '\n' or lines[n + 2] != '+++ b/' + name + '\n':
            raise ValueError('Unexpected patch file identity')
        old, output, pos = before[name].splitlines(keepends=True), [], 0
        n += 3
        while n < len(lines) and not lines[n].startswith('diff --git '):
            hunk = re.fullmatch(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@\n', lines[n])
            if not hunk:
                raise ValueError('Expected formal unified-diff hunk')
            start, count, new_start, new_count = (int(x) if x is not None else 1 for x in hunk.groups())
            target = start - 1 if count else start
            output.extend(old[pos:target])
            pos, removed, added, n = target, 0, 0, n + 1
            while n < len(lines) and lines[n][0] in ' +-':
                operation, text = lines[n][0], lines[n][1:]
                if operation in ' -':
                    if pos >= len(old) or old[pos] != text:
                        raise ValueError(f'Patch context mismatch: {name}:{pos + 1}')
                    pos, removed = pos + 1, removed + 1
                if operation in ' +':
                    output.append(text)
                    added += 1
                n += 1
            if (removed, added) != (count, new_count):
                raise ValueError('Patch hunk counts do not match')
        after[name] = ''.join(output + old[pos:])
    return after


def audit(root, metadata, patch, headers):
    before = p.load_sources(root)
    if {n: p.sha(s.encode()) for n, s in before.items()} != metadata['inputs']:
        raise ValueError('Frozen source bytes differ from the overlay audit')
    if p.sha(patch.encode()) != metadata['patch_sha256']:
        raise ValueError('Patch differs from the overlay audit')
    after = projected(before, patch)
    if {n: p.sha(s.encode()) for n, s in after.items()} != metadata['outputs']:
        raise ValueError('Projected patch outputs differ from the overlay audit')
    packager = after['tools_webrtc/apple/copy_framework_header.py']
    function = next(n for n in ast.parse(packager).body if isinstance(n, ast.FunctionDef) and n.name == '_ReplaceDoubleQuote')
    namespace = {'re': re}
    exec(compile(ast.Module(body=[function], type_ignores=[]), '<audited-header-packager>', 'exec'), namespace)
    package_line = namespace['_ReplaceDoubleQuote']
    exported = {f.name: f for f in headers.resolve(strict=True).glob('*.h')}
    source_names = {}
    for name in after:
        if name.startswith('sdk/objc/') and name.endswith('.h'):
            source_names.setdefault(Path(name).name, []).append(name)
    public, unresolved, edges, generated = {}, [], [], {}
    for name, file in sorted(exported.items()):
        matches = source_names.get(name, [])
        if len(matches) > 1:
            raise ValueError(f'Ambiguous exported source header: {name}')
        if matches:
            source = after[matches[0]]
            public[name] = '\n'.join(package_line(line) for line in source.splitlines()) + '\n'
        else:
            public[name] = file.read_text()
            generated[str(file)] = p.sha(file.read_bytes())
        for token in p.lex(public[name]):
            operand = p.imported_header(token)
            if not operand:
                continue
            if operand.startswith('LiveKitWebRTC/'):
                target = operand.split('/', 1)[1]
                edges.append({'from': name, 'to': target})
                if target not in exported:
                    unresolved.append({'header': name, 'line': token.line, 'operand': operand})
            elif '"' in token.text and operand not in exported:
                unresolved.append({'header': name, 'line': token.line, 'operand': operand})
    additional, cache = {}, dict(after)

    def load(name):
        if name not in cache:
            path = root / name
            if not path.is_file() or not path.resolve().is_relative_to(root):
                return None
            data = path.read_bytes()
            cache[name] = data.decode('utf-8')
            additional[name] = p.sha(data)
        return cache[name]

    def resolve(owner, operand):
        candidates = (Path(owner).parent / operand, Path(operand), Path('sdk/objc') / operand,
                      Path('sdk/objc/base') / operand)
        for candidate in candidates:
            candidate = (root / candidate).resolve()
            if candidate.is_relative_to(root):
                name = candidate.relative_to(root).as_posix()
                if name in cache or candidate.is_file():
                    return name
        return None

    def imports(owner, source, before_position=None):
        return [target for token in p.lex(source) if before_position is None or token.start < before_position
                if (operand := p.imported_header(token)) and (target := resolve(owner, operand))]

    def exports_macros(start):
        pending, visited = [start], set()
        while pending:
            name = pending.pop()
            if name in visited:
                continue
            visited.add(name)
            if name == 'sdk/objc/base/RTCMacros.h':
                return True
            source = load(name)
            if source is not None:
                pending.extend(imports(name, source))
        return False

    macro_files, missing_macros, test_framework_dependencies = [], [], []
    original_module = plistlib.loads(before['sdk/objc/Info.plist'].encode())['CFBundleName']
    for name, source in sorted(after.items()):
        if Path(name).suffix not in p.CODE_SUFFIXES or name == 'sdk/objc/base/RTCMacros.h':
            continue
        uses = [t for t in p.code_tokens(source) if t.text in p.WRAPPERS]
        if not uses:
            continue
        macro_files.append(name)
        if not any(exports_macros(target) for target in imports(name, source, uses[0].start)):
            framework_imports = [operand for token in p.lex(source) if token.start < uses[0].start
                                 if (operand := p.imported_header(token)) and
                                 operand.startswith(original_module + '/')]
            finding = {'path': name, 'first_macro_line': uses[0].line}
            if 'unittests' in Path(name).parts and framework_imports:
                test_framework_dependencies.append({**finding, 'framework_imports': framework_imports})
            else:
                missing_macros.append(finding)
    return {'schema_version': 1, 'overlay_patch_sha256': metadata['patch_sha256'],
            'projected_files_verified': len(after), 'exported_headers_checked': len(exported),
            'framework_header_edges': edges, 'unresolved_packaged_headers': unresolved,
            'macro_consumer_files_checked': len(macro_files),
            'ordinary_mm_files_checked': sum(name.endswith('.mm') for name in macro_files),
            'missing_macro_import_paths': missing_macros, 'additional_source_header_inputs': additional,
            'unit_test_legacy_framework_dependencies': test_framework_dependencies,
            'existing_generated_header_inputs': generated,
            'scope': 'Static union of literal include/import paths. Legacy framework imports in unit tests are reported separately; conditional branches require compiler acceptance.',
            'passed': not unresolved and not missing_macros}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--audit', type=Path, required=True)
    parser.add_argument('--patch', type=Path, required=True)
    parser.add_argument('--headers', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    root = args.source.resolve(strict=True)
    result = audit(root, json.loads(args.audit.read_text()), args.patch.read_text(), args.headers)
    args.report.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k in {'passed', 'projected_files_verified',
          'exported_headers_checked', 'macro_consumer_files_checked', 'ordinary_mm_files_checked',
          'unresolved_packaged_headers', 'missing_macro_import_paths'}}))
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
