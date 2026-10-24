#!/usr/bin/env python3
"""Emit a deterministic namespace overlay; never edit a source checkout."""
import argparse
import ast
from dataclasses import dataclass
import difflib
import hashlib
import json
from pathlib import Path
import plistlib
import posixpath
import subprocess

FORK_SHA = "0385653a83f21acf3c916466d4088b29fe2f160b"
LIVEKIT_SHA = "57a84d71c33e97349963c1cbd442fb4b01428b7c"
CODE_SUFFIXES = {".h", ".m", ".mm", ".cc", ".cpp", ".c"}
NATIVE_ROOTS = ("api", "audio", "call", "common_audio", "common_video",
                "logging", "media", "modules", "p2p", "pc", "rtc_base", "test", "video")
PACKAGING = ("sdk/BUILD.gn", "sdk/objc/Info.plist",
             "tools_webrtc/ios/generate_umbrella_header.py",
             "tools_webrtc/apple/copy_framework_header.py",
             "tools_webrtc/ios/build_ios_libs.py")
WRAPPERS = {"RTC_OBJC_TYPE": "type", "RTC_CONSTANT_TYPE": "constant"}
RESERVED = set(WRAPPERS) | {"RTC_EXTERN", "RTC_OBJC_EXPORT"}


def sha(data):
    return hashlib.sha256(data).hexdigest()


@dataclass(frozen=True)
class Token:
    kind: str
    text: str
    start: int
    end: int
    line: int


def lex(source):
    """C/ObjC lexical spans, including comments and raw strings as opaque tokens."""
    result, i, line = [], 0, 1
    while i < len(source):
        start, first_line = i, line
        c = source[i]
        if c == "#" and not source[source.rfind("\n", 0, i) + 1:i].strip():
            word = i + 1
            while word < len(source) and source[word] in " \t":
                word += 1
            end_word = word
            while end_word < len(source) and source[end_word].isalpha():
                end_word += 1
            directive = source[word:end_word]
            if directive in {"error", "warning", "include", "import", "pragma"}:
                end = source.find("\n", end_word)
                while end >= 0 and source[end - 1:end] == "\\":
                    end = source.find("\n", end + 1)
                i = len(source) if end < 0 else end
                kind = "directive"
            else:
                i, kind = i + 1, "punctuation"
        elif c.isspace():
            i += 1
            while i < len(source) and source[i].isspace():
                i += 1
            kind = "space"
        elif source.startswith("//", i):
            end = source.find("\n", i)
            i = len(source) if end < 0 else end
            kind = "comment"
        elif source.startswith("/*", i):
            end = source.find("*/", i + 2)
            if end < 0:
                raise ValueError("Unterminated block comment")
            i, kind = end + 2, "comment"
        elif any(source.startswith(prefix + '"', i)
                 for prefix in ("R", "u8R", "uR", "UR", "LR")):
            quote = source.index('"', i)
            opening = source.find("(", quote + 1)
            if opening < 0 or opening - quote > 17:
                raise ValueError("Invalid C++ raw string")
            ending = ")" + source[quote + 1:opening] + '"'
            end = source.find(ending, opening + 1)
            if end < 0:
                raise ValueError("Unterminated C++ raw string")
            i, kind = end + len(ending), "string"
        elif c.isdigit():
            i += 1
            while i < len(source) and (source[i].isalnum() or source[i] in "._" or
                                      (source[i] == "'" and i + 1 < len(source) and source[i + 1].isalnum())):
                i += 1
            kind = "number"
        elif c in ('"', "'"):
            quote, i = c, i + 1
            while i < len(source):
                if source[i] == "\\":
                    i += 2
                elif source[i] == quote:
                    i += 1
                    break
                else:
                    i += 1
            else:
                raise ValueError("Unterminated string or character literal")
            kind = "string"
        elif c.isalpha() or c == "_":
            i += 1
            while i < len(source) and (source[i].isalnum() or source[i] == "_"):
                i += 1
            kind = "identifier"
        else:
            i, kind = i + 1, "punctuation"
        text = source[start:i]
        result.append(Token(kind, text, start, i, first_line))
        line += text.count("\n")
    return result


def code_tokens(source):
    """Ignore all preprocessing except executable replacement-list tokens."""
    tokens = [t for t in lex(source) if t.kind not in {"space", "comment", "string", "directive"}]
    excluded = set()
    for n, token in enumerate(tokens):
        if token.text != "#" or source[source.rfind("\n", 0, token.start) + 1:token.start].strip():
            continue
        end = source.find("\n", token.end)
        while end >= 0 and source[end - 1:end] == "\\":
            end = source.find("\n", end + 1)
        end = len(source) if end < 0 else end
        ids = [j for j in range(n, len(tokens)) if tokens[j].start < end]
        if len(ids) < 2 or tokens[ids[1]].text != "define":
            excluded.update(ids)
            continue
        # Keep a macro's name and formal parameters intact. Its body may refer
        # to API types and therefore participates in namespace transformation.
        stop = n + 3
        if stop < len(tokens) and tokens[stop].text == "(" and tokens[stop].start == tokens[stop - 1].end:
            stop = matching(tokens, stop) + 1
        excluded.update(range(n, stop))
    return [t for n, t in enumerate(tokens) if n not in excluded]


def matching(tokens, start, opening="(", closing=")"):
    depth = 0
    for n in range(start, len(tokens)):
        if tokens[n].text == opening:
            depth += 1
        elif tokens[n].text == closing:
            depth -= 1
            if depth == 0:
                return n
    raise ValueError(f"Unbalanced {opening} at line {tokens[start].line}")


def argument_name(tokens, start):
    if tokens[start].text in WRAPPERS and start + 3 < len(tokens) and tokens[start + 1].text == "(":
        return tokens[start + 2].text, start + 3
    return tokens[start].text, start


def add_symbol(symbols, name, kind, path, line, evidence):
    if name in RESERVED or not name.startswith("RTC") or not name.isidentifier():
        return
    entry = symbols.setdefault(name, {"kind": kind, "argument": name, "proofs": []})
    if entry["kind"] != kind:
        raise ValueError(f"Conflicting namespace classification: {name}")
    proof = {"path": path, "line": line, "declaration": evidence}
    if proof not in entry["proofs"]:
        entry["proofs"].append(proof)


def inventory(contents, objc_only=False):
    """Derive symbols from wrappers and C/ObjC declaration grammar."""
    symbols = {}
    for path, source in sorted(contents.items()):
        try:
            ts = code_tokens(source)
        except ValueError as error:
            raise ValueError(f"{path}: {error}") from error
        for n, t in enumerate(ts):
            if t.text in WRAPPERS and n + 3 < len(ts) and ts[n + 1].text == "(" and ts[n + 3].text == ")":
                add_symbol(symbols, ts[n + 2].text, WRAPPERS[t.text], path, t.line, t.text)
            if t.text == "@" and n + 2 < len(ts) and ts[n + 1].text in {"interface", "implementation", "protocol", "class"}:
                if ts[n + 2].text != "(":
                    name, _ = argument_name(ts, n + 2)
                    add_symbol(symbols, name, "type", path, t.line, "ObjC declaration")
            if not objc_only and t.text in {"NS_ENUM", "NS_OPTIONS", "CF_ENUM", "CF_OPTIONS"} and n + 1 < len(ts) and ts[n + 1].text == "(":
                end = matching(ts, n + 1)
                depth, comma = 0, None
                for j in range(n + 2, end):
                    depth += (ts[j].text == "(") - (ts[j].text == ")")
                    if ts[j].text == "," and depth == 0:
                        comma = j
                        break
                if comma is not None:
                    name, _ = argument_name(ts, comma + 1)
                    add_symbol(symbols, name, "type", path, t.line, "enum type")
                if end + 1 < len(ts) and ts[end + 1].text == "{":
                    close, j = matching(ts, end + 1, "{", "}"), end + 2
                    while j < close:
                        name, after = argument_name(ts, j)
                        add_symbol(symbols, name, "type", path, ts[j].line, "enumerator")
                        j, depth = after + 1, 0
                        while j < close:
                            if ts[j].text in {"(", "[", "{"}:
                                depth += 1
                            elif ts[j].text in {")", "]", "}"}:
                                depth -= 1
                            if ts[j].text == "," and depth == 0:
                                j += 1
                                break
                            j += 1
            if not objc_only and t.text == "typedef":
                end, depth = n + 1, 0
                while end < len(ts):
                    if ts[end].text == ";" and depth == 0:
                        break
                    depth += (ts[end].text in {"(", "[", "{"}) - (ts[end].text in {")", "]", "}"})
                    end += 1
                body = ts[n + 1:end]
                if any(x.text in {"NS_ENUM", "NS_OPTIONS", "CF_ENUM", "CF_OPTIONS"} for x in body):
                    continue
                caret = next((j for j in range(n + 1, end) if ts[j].text == "^"), None)
                if caret is not None and caret + 1 < end:
                    name, _ = argument_name(ts, caret + 1)
                    add_symbol(symbols, name, "type", path, t.line, "block typedef")
                elif end > n + 1:
                    name = ts[end - 1].text
                    add_symbol(symbols, name, "type", path, t.line, "typedef")
            if not objc_only and t.text in {"RTC_EXTERN", "RTC_OBJC_EXPORT", "FOUNDATION_EXPORT"}:
                end = n + 1
                while end < len(ts) and ts[end].text not in {";", "@", "{"}:
                    end += 1
                for item in ts[n + 1:end]:
                    if item.kind == "identifier" and item.text.startswith("kRTC"):
                        add_symbol(symbols, item.text[1:], "constant", path, item.line, "exported constant")
    return symbols


def local_objc_definitions(contents):
    """Owned primary classes/protocols; categories and external forwards excluded."""
    symbols = {}
    for path, source in sorted(contents.items()):
        ts = code_tokens(source)
        for n, token in enumerate(ts[:-2]):
            if token.text != "@" or ts[n + 1].text not in {"interface", "protocol"}:
                continue
            if ts[n + 2].kind != "identifier":
                continue
            name, end = argument_name(ts, n + 2)
            following = ts[end + 1].text if end + 1 < len(ts) else None
            if name.startswith("RTC") or following in {"(", ";", ","}:
                continue
            proof = {"path": path, "line": token.line, "declaration": "primary ObjC " + ts[n + 1].text}
            symbols.setdefault(name, {"kind": ts[n + 1].text, "output": "LK" + name, "proofs": []})["proofs"].append(proof)
    return symbols


def reject_native_cpp_name_collisions(contents, names):
    """Do not guess unqualified binding if a local ObjC name is also a C++ type."""
    for path, source in sorted(contents.items()):
        ts = code_tokens(source)
        for n, token in enumerate(ts[:-1]):
            if (token.text in {"class", "struct"} and ts[n + 1].text in names and
                    (not n or ts[n - 1].text != "@")):
                raise ValueError(f"Ambiguous native C++/ObjC class binding: {path}:{token.line}: {ts[n + 1].text}")


def fork_contents(root):
    actual = subprocess.check_output(["git", "rev-parse", FORK_SHA], cwd=root, text=True).strip()
    if actual != FORK_SHA:
        raise ValueError("Unexpected M150 revision")
    names = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", FORK_SHA, "sdk/objc"], cwd=root, text=True).splitlines()
    names = [name for name in names if Path(name).suffix in CODE_SUFFIXES]
    request = "".join(FORK_SHA + ":" + name + "\n" for name in names).encode()
    response = subprocess.check_output(["git", "cat-file", "--batch"], cwd=root, input=request)
    result, offset = {}, 0
    for name in names:
        end = response.index(b"\n", offset)
        header = response[offset:end].split()
        if len(header) != 3 or header[1] != b"blob":
            raise ValueError(f"Invalid M150 source blob: {name}")
        size = int(header[2])
        result[name] = response[end + 1:end + 1 + size].decode()
        offset = end + size + 2
    if offset != len(response):
        raise ValueError("Unexpected git batch trailing data")
    return result


def raw_mapping(symbols):
    result = {}
    for name, entry in symbols.items():
        key = "k" + name if entry["kind"] == "constant" else name
        result[key] = ("RTC_CONSTANT_TYPE" if entry["kind"] == "constant" else "RTC_OBJC_TYPE", name)
    return result


def raw_c_functions(contents):
    """Find unwrapped exported C function names in formal header declarations."""
    functions = {}
    for path, source in sorted(contents.items()):
        if not path.endswith(".h"):
            continue
        ts = code_tokens(source)
        for n, token in enumerate(ts):
            if token.text != "RTC_EXTERN":
                continue
            j = n + 1
            while j + 1 < len(ts) and ts[j].text not in {";", "@", "{"}:
                if (ts[j].kind == "identifier" and ts[j].text.startswith("RTC") and
                        ts[j + 1].text == "(" and ts[j].text not in WRAPPERS):
                    functions.setdefault(ts[j].text, []).append(
                        {"path": path, "line": ts[j].line, "declaration": "RTC_EXTERN function"})
                    break
                j += 1
    return functions


def qualified_binary_exports(path):
    """Read the caller-selected qualified M150 framework without copying it."""
    path = path.resolve(strict=True)
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    output = subprocess.check_output(["nm", "-gU", str(path)], text=True)
    names = {line.split()[-1][1:] for line in output.splitlines()
             if line.split() and line.split()[-1].startswith("_")}
    return names, {"path": str(path), "sha256": digest.hexdigest(),
                   "symbol_command": ["nm", "-gU"], "defined_global_symbols": len(names)}


def export_isolation(current, legacy, qualified, flavor, legacy_namespaced=()):
    """Keep legacy C ABI; namespace newly added guest functions in LiveKit."""
    added = set(current) - set(legacy) - set(legacy_namespaced)
    if flavor == "guest":
        return {}
    missing = sorted(set(legacy) - qualified)
    if missing:
        raise ValueError(f"Qualified M150 binary lacks legacy raw C exports: {missing}")
    collisions = sorted(added & qualified)
    if collisions:
        raise ValueError(f"Selected binary already contains guest-only raw exports: {collisions}")
    return {name: {"output": "LK" + name, "proofs": current[name],
                   "legacy_declaration_present": False, "qualified_raw_export_present": False}
            for name in sorted(added)}


def splices(source, changes):
    output, previous = [], 0
    for start, end, replacement in sorted(changes):
        if start < previous:
            raise ValueError("Overlapping lexical edits")
        output += [source[previous:start], replacement]
        previous = end
    return "".join(output) + source[previous:]


def cpp_qualified(tokens, index):
    """C++ scope syntax proves a name belongs to a native qualified name."""
    if [t.text for t in tokens[index + 1:index + 3]] == [":", ":"]:
        return True
    before = index - (1 if index and tokens[index - 1].text == "template" else 0)
    if before >= 3 and [t.text for t in tokens[before - 2:before]] == [":", ":"]:
        qualifier = tokens[before - 3]
        return qualifier.kind == "identifier" or qualifier.text in {">", ")", "]"}
    return False


def transform_code(source, mapping, flavor):
    ts, wrapped, edits = code_tokens(source), set(), []
    for n, token in enumerate(ts):
        if token.text in WRAPPERS and n + 1 < len(ts) and ts[n + 1].text == "(":
            wrapped.update(range(n + 2, matching(ts, n + 1)))
    for n, token in enumerate(ts):
        if token.kind != "identifier":
            continue
        if cpp_qualified(ts, n):
            continue
        # Deliberate product flavor, including arguments already wrapped.
        if flavor == "livekit" and token.text == "RTCConferenceYUVHelper":
            replacement = "RTCYUVHelper" if n in wrapped else "RTC_OBJC_TYPE(RTCYUVHelper)"
        elif n not in wrapped and token.text in mapping:
            macro, argument = mapping[token.text]
            replacement = macro + "(" + argument + ")" if macro else argument
        else:
            continue
        edits.append((token.start, token.end, replacement))
    return splices(source, edits), [{"line": source.count("\n", 0, a) + 1,
                                     "input": source[a:b], "output": out}
                                    for a, b, out in edits]


def macro_prefix(source, flavor):
    """Edit only the replacement list of the two formal prefix definitions."""
    replacements = {"RTC_OBJC_TYPE_PREFIX": "LK" if flavor == "livekit" else "",
                    "RTC_CONSTANT_TYPE_PREFIX": "kLK" if flavor == "livekit" else "k"}
    ts, edits = [t for t in lex(source) if t.kind not in {"space", "comment"}], []
    counts = dict.fromkeys(replacements, 0)
    for n in range(len(ts) - 2):
        if [ts[n].text, ts[n + 1].text] != ["#", "define"] or ts[n + 2].text not in replacements:
            continue
        token, end = ts[n + 2], source.find("\n", ts[n + 2].end)
        end = len(source) if end < 0 else end
        old = source[token.end:end].strip()
        if old not in {"", "k"}:
            raise ValueError("Source already has a namespace prefix")
        edits.append((token.end, end, " " + replacements[token.text] if replacements[token.text] else ""))
        counts[token.text] += 1
    if any(count != 1 for count in counts.values()):
        raise ValueError("Expected exactly one definition of each RTC prefix")
    return splices(source, edits)


def packaging(source, path):
    """Explicit module metadata edits; separate from identifier rewriting."""
    if path == "sdk/BUILD.gn":
        ts = [t for t in lex(source) if t.kind not in {"space", "comment"}]
        changes, counts = [], {"output_name": 0, "sources": 0}
        for n, token in enumerate(ts):
            if token.kind != "string":
                continue
            if n >= 2 and [ts[n - 2].text, ts[n - 1].text] == ["output_name", "="] and token.text == '"WebRTC"':
                changes.append((token.start, token.end, '"LiveKitWebRTC"'))
                counts["output_name"] += 1
            elif token.text == '"$root_build_dir/WebRTC.framework"':
                if n < 3 or [t.text for t in ts[n - 3:n]] != ["sources", "=", "["]:
                    raise ValueError("Unexpected framework bundle GN context")
                changes.append((token.start, token.end, '"$root_build_dir/LiveKitWebRTC.framework"'))
                counts["sources"] += 1
        if counts != {"output_name": 2, "sources": 2}:
            raise ValueError(f"Unexpected framework GN fields: {counts}")
        return splices(source, changes)
    if path.endswith("Info.plist"):
        values = plistlib.loads(source.encode())
        expected = {"CFBundleExecutable": "WebRTC", "CFBundleName": "WebRTC",
                    "CFBundleIdentifier": "org.webrtc.WebRTC"}
        if any(values.get(key) != value for key, value in expected.items()):
            raise ValueError("Unexpected framework plist identity")
        if source.count("<string>WebRTC</string>") != 2 or source.count("<string>org.webrtc.WebRTC</string>") != 1:
            raise ValueError("Unexpected framework plist serialization")
        return source.replace("<string>WebRTC</string>", "<string>LiveKitWebRTC</string>").replace(
            "<string>org.webrtc.WebRTC</string>", "<string>io.livekit.LiveKitWebRTC</string>")
    tree, edits = ast.parse(source), []
    if path.endswith("build_ios_libs.py"):
        desired = {"SDK_FRAMEWORK_NAME": ("WebRTC.framework", "LiveKitWebRTC.framework"),
                   "SDK_DSYM_NAME": ("WebRTC.dSYM", "LiveKitWebRTC.dSYM"),
                   "SDK_XCFRAMEWORK_NAME": ("WebRTC.xcframework", "LiveKitWebRTC.xcframework")}
        nodes = [(node.value, desired[node.targets[0].id]) for node in ast.walk(tree)
                 if isinstance(node, ast.Assign) and len(node.targets) == 1 and
                 isinstance(node.targets[0], ast.Name) and node.targets[0].id in desired]
        if len(nodes) != 3:
            raise ValueError("Missing iOS framework naming assignments")
    else:
        before = ("#import <WebRTC/{}>\n" if path.endswith("generate_umbrella_header.py")
                  else "%s#import <WebRTC/%sRTC%s.h>%s")
        nodes = [(node, (before, before.replace("<WebRTC/", "<LiveKitWebRTC/")))
                 for node in ast.walk(tree) if isinstance(node, ast.Constant) and node.value == before]
        if len(nodes) != 1:
            raise ValueError("Unexpected framework header generator literal")
    lines = source.splitlines(keepends=True)
    offsets, pos = [], 0
    for line in lines:
        offsets.append(pos)
        pos += len(line)
    for node, (before, after) in nodes:
        if not isinstance(node, ast.Constant) or node.value != before:
            raise ValueError("Unexpected framework Python value")
        start = offsets[node.lineno - 1] + node.col_offset
        end = offsets[node.end_lineno - 1] + node.end_col_offset
        literal = source[start:end]
        if literal.count("WebRTC") != 1:
            raise ValueError("Unexpected module literal spelling")
        edits.append((start, end, literal.replace("WebRTC", "LiveKitWebRTC")))
    return splices(source, edits)


def imported_header(token):
    """Read a literal include/import operand from a preprocessing token."""
    if token.kind != "directive":
        return None
    text = token.text[1:].lstrip()
    end = 0
    while end < len(text) and (text[end].isalnum() or text[end] == "_"):
        end += 1
    if text[:end] not in {"include", "import"}:
        return None
    operand = text[end:].lstrip()
    if not operand or operand[0] not in {'"', '<'}:
        return None
    closing = '"' if operand[0] == '"' else '>'
    return operand[1:operand.index(closing, 1)]


def native_consumer_paths(root):
    """Discover owned native ObjC translation units and formal SDK consumers."""
    result = set()
    markers = (b"#import", b"/objc/", b"RTCMacros.h", b"RTC_FWD_DECL_OBJC_CLASS",
               b"@class", b"@interface", b"@implementation", b"@protocol")
    for directory in NATIVE_ROOTS:
        for path in (root / directory).rglob("*"):
            if not path.is_file() or path.suffix not in CODE_SUFFIXES or "third_party" in path.parts:
                continue
            if path.suffix == ".mm":
                result.add(path.relative_to(root).as_posix())
                continue
            data = path.read_bytes()
            if not any(marker in data for marker in markers):
                continue
            source = data.decode("utf-8")
            imports = [imported_header(t) for t in lex(source)]
            if any(name and ("/objc/" in name or Path(name).name == "RTCMacros.h") for name in imports):
                result.add(path.relative_to(root).as_posix())
                continue
            ts = code_tokens(source)
            for n, token in enumerate(ts[:-1]):
                if ((token.text == "RTC_FWD_DECL_OBJC_CLASS" and ts[n + 1].text == "(") or
                        (token.text == "@" and ts[n + 1].text in {"class", "interface", "implementation", "protocol"})):
                    result.add(path.relative_to(root).as_posix())
                    break
    return result


def ensure_macro_import(source):
    """Give a header using prefix macros an explicit, self-contained dependency."""
    ts = lex(source)
    if not any(t.kind == "identifier" and t.text in WRAPPERS for t in ts):
        return source, False
    if any(name and Path(name).name == "RTCMacros.h" for name in map(imported_header, ts)):
        return source, False
    imports = [t for t in ts if imported_header(t)]
    if not imports:
        raise ValueError("Prefix macro header has no safe existing import insertion point")
    first = imports[0]
    newline = "\r\n" if "\r\n" in source else "\n"
    # The framework header copier rewrites #import operands, not #include.
    insertion = '#import "sdk/objc/base/RTCMacros.h"' + newline
    # Insert before the first existing import, after its copyright/guard prelude.
    return source[:first.start] + insertion + source[first.start:], True


def repair_header_macro_imports(contents, candidates):
    """Repair dependency headers first, avoiding redundant direct GN includes."""
    def imports(owner):
        result = []
        for token in lex(contents[owner]):
            operand = imported_header(token)
            if not operand:
                continue
            paths = (posixpath.join(posixpath.dirname(owner), operand), operand,
                     posixpath.join("sdk/objc", operand), posixpath.join("sdk/objc/base", operand))
            for path in paths:
                path = posixpath.normpath(path)
                if path in contents:
                    result.append((token.start, path))
                    break
        return result

    graph = {name: imports(name) for name in contents if Path(name).suffix in CODE_SUFFIXES}
    order, visited = [], set()

    def visit(name):
        if name in visited:
            return
        visited.add(name)
        for _, target in graph.get(name, []):
            visit(target)
        order.append(name)

    def reaches_macros(start):
        pending, seen = [start], set()
        while pending:
            name = pending.pop()
            if name == "sdk/objc/base/RTCMacros.h":
                return True
            if name not in seen:
                seen.add(name)
                pending.extend(target for _, target in graph.get(name, []))
        return False

    for name in sorted(candidates):
        visit(name)
    added = []
    for name in order:
        if name not in candidates or not name.endswith(".h"):
            continue
        uses = [t for t in code_tokens(contents[name]) if t.text in WRAPPERS]
        if not uses or any(reaches_macros(target) for position, target in graph[name] if position < uses[0].start):
            continue
        contents[name], inserted = ensure_macro_import(contents[name])
        if inserted:
            graph[name] = imports(name)
            added.append(name)
    return sorted(added)


def source_paths(root):
    paths = {p.relative_to(root).as_posix() for p in (root / "sdk/objc").rglob("*")
             if p.is_file() and p.suffix in CODE_SUFFIXES}
    return sorted(paths | set(PACKAGING) | native_consumer_paths(root))


def load_sources(root):
    result = {}
    for name in source_paths(root):
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError("Unsafe namespace source path")
        result[name] = path.read_bytes().decode("utf-8")
    return result


def generate_patch(before, after):
    result = []
    for name in sorted(after):
        if before[name] == after[name]:
            continue
        result.append(f"diff --git a/{name} b/{name}\n")
        result.extend(difflib.unified_diff(before[name].splitlines(keepends=True),
                                          after[name].splitlines(keepends=True),
                                          fromfile="a/" + name, tofile="b/" + name))
    return "".join(result)


def plan(root, old_root, flavor, qualified_binary=None):
    before, old_code = load_sources(root), fork_contents(old_root)
    legacy = inventory(old_code)
    code = {n: s for n, s in before.items() if Path(n).suffix in CODE_SUFFIXES}
    sdk_code = {n: s for n, s in code.items() if n.startswith("sdk/objc/")}
    native_code = {n: s for n, s in code.items() if n not in sdk_code}
    current, symbols = inventory(sdk_code), dict(legacy)
    # Native consumers can declare ObjC classes, but their C++ typedefs/enums
    # are outside the namespace catalog even if their names start with RTC.
    for name, entry in inventory(native_code, objc_only=True).items():
        for proof in entry["proofs"]:
            add_symbol(current, name, entry["kind"], proof["path"], proof["line"], proof["declaration"])
    functions, legacy_functions = raw_c_functions(code), raw_c_functions(old_code)
    qualified, binary_evidence = set(), None
    if flavor == "livekit":
        if qualified_binary is None:
            raise ValueError("LiveKit flavor requires --qualified-prefix-binary")
        qualified, binary_evidence = qualified_binary_exports(qualified_binary)
    isolated = export_isolation(functions, legacy_functions, qualified, flavor, raw_mapping(legacy))
    for name, entry in isolated.items():
        for proof in entry["proofs"]:
            add_symbol(symbols, name, "type", proof["path"], proof["line"], proof["declaration"])
    aliases = {}
    for name, entry in current.items():
        if name in symbols and symbols[name]["kind"] != entry["kind"]:
            if symbols[name]["kind"] == "type" and entry["kind"] == "constant":
                # Some M150 constants deliberately use RTC_OBJC_TYPE (no k),
                # while upstream M155 spells them kRTC*. Preserve M150's ABI.
                aliases["k" + name] = {"macro": "RTC_OBJC_TYPE", "argument": name,
                                       "legacy_proofs": symbols[name]["proofs"],
                                       "m155_proofs": entry["proofs"]}
                continue
            raise ValueError(f"Namespace catalog differs from M150: {name}")
        symbols.setdefault(name, entry)
    mapping, after, lexical_edits, native_qualified = raw_mapping(symbols), dict(before), {}, {}
    local_objc = local_objc_definitions(code)
    reject_native_cpp_name_collisions(code, local_objc)
    if flavor == "livekit":
        mapping.update({name: (None, entry["output"]) for name, entry in local_objc.items()})
    mapping.update({name: (entry["macro"], entry["argument"]) for name, entry in aliases.items()})
    for name, source in code.items():
        ts = code_tokens(source)
        preserved = [{"line": t.line, "identifier": t.text} for n, t in enumerate(ts)
                     if t.text in mapping and cpp_qualified(ts, n)]
        if preserved:
            native_qualified[name] = preserved
        after[name], edits = transform_code(source, mapping, flavor)
        if edits:
            lexical_edits[name] = edits
    macro_imports = repair_header_macro_imports(after, set(lexical_edits))
    macros = "sdk/objc/base/RTCMacros.h"
    after[macros] = macro_prefix(after[macros], flavor)
    if flavor == "livekit":
        for name in PACKAGING:
            after[name] = packaging(after[name], name)
    # Reject source drift while deriving the overlay rather than emit a mixed snapshot.
    if load_sources(root) != before:
        raise ValueError("Source changed during namespace inventory")
    unchanged_exports = sorted(name for name in functions if name not in mapping)
    audit = {"schema_version": 1, "flavor": flavor, "legacy_fork_sha": FORK_SHA,
             "module": "LiveKitWebRTC" if flavor == "livekit" else "WebRTC",
             "helper_class": "LKRTCYUVHelper" if flavor == "livekit" else "RTCConferenceYUVHelper",
             "symbols": symbols, "lexical_edits": lexical_edits,
             "local_objc_runtime_definitions": local_objc if flavor == "livekit" else {},
             "preserved_native_qualified_references": native_qualified,
             "explicit_macro_imports_added": macro_imports,
             "native_consumer_paths": [n for n in before if n not in PACKAGING and not n.startswith("sdk/objc/")],
             "legacy_constant_aliases": aliases,
             "unchanged_c_function_exports": unchanged_exports,
             "isolated_c_function_exports": isolated,
             "legacy_raw_c_function_exports": legacy_functions,
             "qualified_prefix_binary": binary_evidence,
             "inputs": {n: sha(s.encode()) for n, s in before.items()},
             "outputs": {n: sha(s.encode()) for n, s in after.items()},
             "packaging_paths": list(PACKAGING) if flavor == "livekit" else []}
    patch = generate_patch(before, after)
    audit["patch_sha256"] = sha(patch.encode())
    return audit, patch



def swift_namespace_audit(root, audit):
    """Read pinned Swift source bytes and match namespace identifiers only."""
    root = root.resolve(strict=True)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    dirty = subprocess.check_output(["git", "status", "--porcelain", "--", "Sources/LiveKit"], cwd=root)
    if revision != LIVEKIT_SHA or dirty:
        raise ValueError("LiveKit source must be clean at the pinned Swift revision")
    available = {("kLK" if entry["kind"] == "constant" else "LK") + name
                 for name, entry in audit["symbols"].items()}
    references, inputs = {}, {}
    for path in sorted((root / "Sources/LiveKit").rglob("*.swift")):
        name, data = path.relative_to(root).as_posix(), path.read_bytes()
        inputs[name] = sha(data)
        for token in lex(data.decode("utf-8")):
            if token.kind == "identifier" and token.text.startswith(("LKRTC", "kLKRTC")):
                references.setdefault(token.text, []).append({"path": name, "line": token.line})
    missing = sorted(set(references) - available)
    if missing:
        raise ValueError(f"Pinned Swift namespace references missing from overlay: {missing}")
    return {"revision": revision, "inputs": inputs, "references": references,
            "namespace_identifiers": len(references), "missing_namespace_identifiers": missing,
            "scope": "Identifier presence only; method signatures, Swift import and linkage require compilation."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--source", type=Path, required=True)
    p.add_argument("--old-fork", type=Path, required=True)
    p.add_argument("--flavor", choices=("guest", "livekit"), required=True)
    p.add_argument("--audit", type=Path, required=True)
    p.add_argument("--patch", type=Path, required=True)
    p.add_argument("--livekit-source", type=Path)
    p.add_argument("--qualified-prefix-binary", type=Path)
    p = sub.add_parser("verify")
    p.add_argument("--source", type=Path, required=True)
    p.add_argument("--audit", type=Path, required=True)
    p.add_argument("--stage", choices=("before", "after"), required=True)
    p.add_argument("--patch", type=Path, required=True)
    args = parser.parse_args()
    root = args.source.resolve(strict=True)
    if args.command == "plan":
        # Outputs must never be written inside either source checkout.
        outputs = [args.audit.resolve(), args.patch.resolve()]
        if len(set(outputs)) != 2 or args.audit.is_symlink() or args.patch.is_symlink():
            raise ValueError("Namespace artifacts must be distinct regular paths")
        protected = [root, args.old_fork.resolve(strict=True)]
        if any(out.is_relative_to(base) for out in outputs for base in protected):
            raise ValueError("Namespace artifacts must be outside source checkouts")
        audit, patch = plan(root, args.old_fork, args.flavor, args.qualified_prefix_binary)
        if args.livekit_source:
            audit["livekit_namespace_audit"] = swift_namespace_audit(args.livekit_source, audit)
        args.patch.write_text(patch)
        args.audit.write_text(json.dumps(audit, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"flavor": args.flavor, "patch_sha256": audit["patch_sha256"],
                          "source_files": len(audit["inputs"]), "changed_files": len(audit["lexical_edits"]),
                          "catalog_symbols": len(audit["symbols"]),
                          "unchanged_c_function_exports": audit["unchanged_c_function_exports"],
                          "isolated_c_function_exports": list(audit["isolated_c_function_exports"])}))
    else:
        audit = json.loads(args.audit.read_text())
        expected = audit["inputs" if args.stage == "before" else "outputs"]
        actual = {n: sha(s.encode()) for n, s in load_sources(root).items()}
        if (audit.get("schema_version") != 1 or audit.get("legacy_fork_sha") != FORK_SHA or
                audit.get("flavor") not in {"guest", "livekit"} or
                sha(args.patch.read_bytes()) != audit.get("patch_sha256")):
            raise ValueError("Namespace artifact identity mismatch")
        if actual != expected:
            changed = sorted(set(actual) ^ set(expected) | {n for n in set(actual) & set(expected) if actual[n] != expected[n]})
            raise ValueError(f"Namespace source identity mismatch: {changed[:10]}")
        print(json.dumps({"stage": args.stage, "verified_files": len(actual)}))


if __name__ == "__main__":
    main()
