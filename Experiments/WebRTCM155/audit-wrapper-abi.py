#!/usr/bin/env python3
"""Read-only arm64 simulator symbol and Objective-C metadata comparison."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


VENDOR_COMMIT = "6d5f92869690fa22bb489a9089aa554d733c6936"
WRAPPERS = ("JazzSDK", "JazzCore", "LibSberCast", "JazzScreenShareImpl", "SDSoup")


def run(*command):
    return subprocess.check_output(command, text=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def symbols(binary, flags):
    # Archive member headings are not symbols; retain only Mach-O identifiers.
    return {s for s in run("xcrun", "nm", "-arch", "arm64", flags,
                           str(binary)).splitlines() if s.startswith("_")}


def rtc_symbol(symbol):
    return symbol.startswith((
        "_RTC", "_kRTC", "_WebRTC", "_$s6WebRTC",
        "_OBJC_CLASS_$_RTC", "_OBJC_METACLASS_$_RTC", "_OBJC_IVAR_$_RTC",
        "_OBJC_CLASS_$_WebRTC", "_OBJC_METACLASS_$_WebRTC",
    ))


def methods(binary, output, label):
    """Join otool type encodings to dyld_info method identities by IMP + selector.

    This supports stripped absolute and current relative method lists, includes
    categories, and rejects undecoded or conflicting records instead of silently
    treating them as compatible.
    """
    raw = run("xcrun", "otool", "-arch", "arm64", "-ov", str(binary))
    (output / f"{label}-objc.txt").write_text(raw)
    records = {}
    selector = encoding = None
    for line in raw.splitlines():
        name = re.match(
            r"\s+name\s+0x[0-9a-f]+(?: \(0x[0-9a-f]+\))? (\S+)$", line)
        types = re.match(
            r"\s+types\s+0x[0-9a-f]+(?: \(0x[0-9a-f]+\))? (.*)$", line)
        imp = re.match(
            r"\s+imp\s+0x([0-9a-f]+)(?: \(0x([0-9a-f]+)\))?", line)
        if name:
            selector, encoding = name[1], None
        if types:
            encoding = types[1]
        if imp and selector is not None and encoding is not None:
            key = (int(imp[2] or imp[1], 16), selector)
            if key[0] == 0:  # Protocol declarations have no implementation.
                selector = encoding = None
                continue
            if key in records and records[key] != encoding:
                raise ValueError(f"Conflicting method encodings: {label} {key}")
            records[key] = encoding
            selector = encoding = None

    identities = run("xcrun", "dyld_info", "-arch", "arm64", "-objc", str(binary))
    (output / f"{label}-methods.txt").write_text(identities)
    result = {}
    for address, sign, owner, selector in re.findall(
            r"0x([0-9A-Fa-f]+)\s+([-+])\[([^ ]+) ([^]]+)\]", identities):
        owner = owner.split("(")[0]  # Categories add methods to their owner.
        key = f"{sign}[{owner} {selector}]"
        encoding = records[(int(address, 16), selector)]
        if key in result and result[key] != encoding:
            raise ValueError(f"Conflicting category encoding: {label} {key}")
        result[key] = encoding
    if not result:
        raise ValueError(f"No Objective-C methods decoded: {binary}")
    return result


def selectors(binary, output, name):
    kind = run("file", "-b", str(binary))
    if "current ar archive" in kind:
        # dyld_info does not decode object-file relocations in static archives.
        # Method-name strings form a conservative superset of selector refs.
        raw = run("xcrun", "otool", "-arch", "arm64", "-v", "-s",
                  "__TEXT", "__objc_methname", str(binary))
        values = re.findall(r"^[0-9a-fA-F]{16}\s+(\S+)\s*$", raw, re.M)
        mode = "__objc_methname superset (static archive)"
    else:
        raw = run("xcrun", "dyld_info", "-arch", "arm64", "-section",
                  "__DATA", "__objc_selrefs", str(binary))
        values = re.findall(r'^0x[0-9A-Fa-f]+\s+"([^"]+)"$', raw, re.M)
        mode = "__objc_selrefs"
        if not values:
            raise ValueError(f"No selector references decoded: {binary}")
    (output / f"{name}-selectors.txt").write_text(raw)
    return set(values), mode, kind.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor", type=Path, required=True)
    parser.add_argument("--framework", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    vendor, framework, output = (p.resolve() for p in
                                 (args.vendor, args.framework, args.output))
    commit = run("git", "-C", str(vendor), "rev-parse", "HEAD").strip()
    if commit != VENDOR_COMMIT:
        raise ValueError(f"Unexpected vendor commit: {commit}")
    status = run("git", "-C", str(vendor), "status", "--porcelain",
                 "--untracked-files=no")
    if status:
        raise ValueError("Pinned vendor has tracked modifications")
    output.mkdir(parents=True, exist_ok=True)
    paths = {n: vendor / f"Sources/{n}.xcframework/ios-arm64_x86_64-simulator/"
                        f"{n}.framework/{n}" for n in (*WRAPPERS, "WebRTC")}
    paths["candidate"] = framework / "WebRTC"
    identities = {n: {"path": str(p), "sha256": digest(p)}
                  for n, p in paths.items()}
    exported = {n: symbols(p, "-gUj") for n, p in paths.items()}
    undefined = {n: symbols(paths[n], "-uj") for n in WRAPPERS}
    imported = {n: {s for s in undefined[n] if rtc_symbol(s)} for n in WRAPPERS}
    unclassified = {n: sorted(s for s in undefined[n] - imported[n]
                             if "RTC" in s or "webrtc" in s) for n in WRAPPERS}
    if any(unclassified.values()):
        raise ValueError(f"Unclassified RTC-like imports: {unclassified}")
    vendor_exports = set().union(*(exported[n] for n in WRAPPERS))
    rtc_imports = set().union(*imported.values())
    candidate_exports = exported["candidate"]
    reference_sets, wrappers = {}, {}
    for name in WRAPPERS:
        references, mode, kind = selectors(paths[name], output, name)
        reference_sets[name] = references
        wrappers[name] = identities[name] | {
            "file_type": kind, "imports": sorted(imported[name]),
            "missing_imports": sorted(imported[name] - candidate_exports - vendor_exports),
            "resolved_in_vendor": {
                symbol: [n for n in WRAPPERS if symbol in exported[n]]
                for symbol in sorted(imported[name] & vendor_exports)},
            "selector_collection": mode, "selector_count": len(references),
        }

    old = methods(paths["WebRTC"], output, "vendor-webRTC")
    new = methods(paths["candidate"], output, "candidate-webRTC")
    exported_classes = {s.split("$_")[1] for s in exported["WebRTC"]
                        if s.startswith("_OBJC_CLASS_$_RTC")}
    imported_classes = {s.split("$_")[1] for s in rtc_imports
                        if s.startswith("_OBJC_CLASS_$_RTC")}
    legacy = {k: v for k, v in old.items()
              if k[2:].split(" ")[0] in exported_classes}
    differences = {}
    for key, encoding in legacy.items():
        if new.get(key) == encoding:
            continue
        selector = key.split(" ", 1)[1][:-1]
        differences[key] = {
            "vendor_encoding": encoding, "candidate_encoding": new.get(key),
            "selector_seen_in": [n for n, refs in reference_sets.items()
                                 if selector in refs],
        }
    for name, path in paths.items():
        if digest(path) != identities[name]["sha256"]:
            raise ValueError(f"Input changed during audit: {path}")
    missing = sorted(rtc_imports - candidate_exports - vendor_exports)
    collisions = sorted(s for s in candidate_exports & vendor_exports if rtc_symbol(s))
    referenced_differences = {k: v for k, v in differences.items()
                              if v["selector_seen_in"]}
    report = {
        "schema_version": 1, "architecture": "arm64", "vendor_commit": commit,
        "audit_tool_sha256": digest(Path(__file__)),
        "candidate": identities["candidate"], "vendor_framework": identities["WebRTC"],
        "candidate_platform": run("xcrun", "dyld_info", "-arch", "arm64",
                                  "-platform", str(paths["candidate"])),
        "wrappers": wrappers, "rtc_imports": sorted(rtc_imports),
        "missing_imports": missing, "duplicate_rtc_exports": collisions,
        "candidate_yuv_exports": sorted(s for s in candidate_exports if "YUVHelper" in s),
        "legacy_exported_class_count": len(exported_classes),
        "legacy_exported_class_method_count": len(legacy),
        "legacy_imported_class_method_count": sum(
            k[2:].split(" ")[0] in imported_classes for k in old),
        "legacy_method_differences": differences,
        "referenced_legacy_method_differences": referenced_differences,
        "limits": [
            "Only the candidate arm64 iOS simulator slice is audited.",
            "Selector references do not identify receiver classes or dynamically constructed selectors.",
            "Static archive method-name strings conservatively overapproximate selector references.",
            "Type encodings and symbols do not prove C++ layout, ARC ownership, behavior, or runtime compatibility.",
        ],
    }
    (output / "wrapper-abi-audit.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"rtc_imports": len(rtc_imports), "missing_imports": missing,
                      "duplicate_rtc_exports": collisions,
                      "referenced_method_differences": len(referenced_differences),
                      "report": str(output / "wrapper-abi-audit.json")}, indent=2))
    return int(bool(missing or collisions or referenced_differences))


if __name__ == "__main__":
    raise SystemExit(main())
