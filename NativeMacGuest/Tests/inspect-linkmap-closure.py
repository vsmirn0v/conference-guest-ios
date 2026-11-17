#!/usr/bin/env python3
"""Audit Xcode arm64 LinkMap object files for approved static/dynamic dependency closure.

Rejects prohibited third-party conference SDKs (Jazz/TrueConf/Telemost SDKs), duplicate
or alternate WebRTC libraries, and any unclassified linked object/archive.
"""
import argparse
import hashlib
import json
import pathlib
import re


PROHIBITED_PATTERNS = (
    re.compile(r"(?<![A-Za-z])(JazzSDK|JazzCore|SaluteJazz|TrueConfSDK|TelemostSDK|YandexTelemostSDK)(?![A-Za-z])", re.I),
)

LIVEKIT_PRODUCTS = {
    "CLiveKitProto.o",
    "LKObjCHelpers.o",
    "LiveKit.o",
    "LiveKitFFI.o",
    "LiveKitNanopb.o",
    "LiveKitUniFFI.o",
}

SHERPA_PRODUCTS = {"SherpaOnnxKit.o", "libCSherpaOnnx.a"}

MLX_VOICE_PRODUCTS = {
    "Cmlx.o",
    "ComplexModule.o",
    "Crypto.o",
    "EventSource.o",
    "Generation.o",
    "Hub.o",
    "HuggingFace.o",
    "InternalCollectionsUtilities.o",
    "Jinja.o",
    "MLX.o",
    "MLXAudioCore.o",
    "MLXAudioTTS.o",
    "MLXFast.o",
    "MLXNN.o",
    "MLXRandom.o",
    "Models.o",
    "Numerics.o",
    "OrderedCollections.o",
    "RealModule.o",
    "Tokenizers.o",
    "_NumericsShims.o",
    "yyjson.o",
}


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_object_files(linkmap_path: pathlib.Path) -> list[str]:
    entries = []
    in_objects = False
    for raw in linkmap_path.read_text(errors="replace").splitlines():
        if raw.startswith("# Object files:"):
            in_objects = True
            continue
        if raw.startswith("# Sections:"):
            break
        if in_objects and "]" in raw:
            entries.append(raw.split("]", 1)[1].strip())
    return entries


def sanitize_name(entry: str) -> str:
    if entry == "linker synthesized":
        return entry
    if "/Products/" in entry:
        return entry.split("/Products/", 1)[1]
    if "/Objects-normal/" in entry:
        return entry.split("/Objects-normal/", 1)[1]
    if "/Intermediates.noindex/" in entry:
        return entry.split("/Intermediates.noindex/", 1)[1]
    if ".framework/" in entry:
        return entry.rsplit("/", 2)[-2] + "/" + entry.rsplit("/", 1)[-1]
    return pathlib.PurePosixPath(entry).name


def classify_entry(entry: str) -> tuple[str, str]:
    sanitized = sanitize_name(entry)
    for pattern in PROHIBITED_PATTERNS:
        if pattern.search(sanitized):
            return ("prohibited-sdk", sanitized)

    if entry == "linker synthesized":
        return ("app-target", sanitized)

    if ".framework/Versions/" in entry or ".framework/" in entry:
        fw_name = entry.split(".framework/", 1)[0].rsplit("/", 1)[-1]
        if fw_name == "LiveKitWebRTC":
            return ("LiveKitWebRTC", sanitized)
        if fw_name in {"RustLiveKitFFI", "RustLiveKitUniFFI"}:
            return (fw_name, sanitized)
        if fw_name == "Sparkle":
            return ("Sparkle", sanitized)
        if "/System/Library/" in entry or "/MacOSX.platform/" in entry:
            return ("apple-sdk", sanitized)
        return ("unknown", sanitized)

    if "/Platforms/MacOSX.platform/" in entry or "/XcodeDefault.xctoolchain/" in entry:
        if entry.endswith(".tbd") or ".a(" in entry:
            return ("apple-sdk", sanitized)
        return ("unknown", sanitized)

    if "/Intermediates.noindex/RockNativeGuest.build/" in entry and "/Objects-normal/" in entry:
        return ("app-target", sanitized)

    if "/Products/Release/" in entry or "/Products/Debug/" in entry:
        tail = entry.split("/Products/", 1)[1].split("/", 1)[1]
        product = tail.split("(", 1)[0]
        if product == "ConferenceCore.o":
            return ("ConferenceCore", sanitized)
        if product in LIVEKIT_PRODUCTS:
            return ("LiveKit-Swift-SDK", sanitized)
        if product in SHERPA_PRODUCTS:
            return ("SherpaOnnx", sanitized)
        if product in MLX_VOICE_PRODUCTS:
            return ("MLXAudioVoice-Dependencies", sanitized)

    return ("unknown", sanitized)


def inspect_linkmap(path: pathlib.Path) -> dict:
    entries = parse_object_files(path)
    if not entries:
        raise ValueError(f"LinkMap contains no # Object files section: {path}")
    buckets: dict[str, list[str]] = {}
    webrtc_frameworks = set()
    for entry in entries:
        bucket, item = classify_entry(entry)
        buckets.setdefault(bucket, []).append(item)
        if "webrtc" in item.lower():
            webrtc_frameworks.add((bucket, item))

    counts = {k: len(v) for k, v in sorted(buckets.items())}
    unknown = sorted(set(buckets.get("unknown", [])))
    prohibited = sorted(set(buckets.get("prohibited-sdk", [])))
    webrtc_entries = sorted(set(buckets.get("LiveKitWebRTC", [])))
    extra_webrtc = sorted(
        f"{b}:{i}" for b, i in webrtc_frameworks if b != "LiveKitWebRTC"
    )

    passed = (
        not unknown
        and not prohibited
        and not extra_webrtc
        and len(webrtc_entries) <= 1
    )
    return {
        "linkmapName": path.name,
        "linkmapSHA256": sha256_file(path),
        "totalObjectEntries": len(entries),
        "bucketCounts": counts,
        "webrtcEntries": webrtc_entries,
        "unexpectedWebRTCEntries": extra_webrtc,
        "prohibitedEntries": prohibited,
        "unknownEntries": unknown,
        "status": "pass" if passed else "fail",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--linkmap", type=pathlib.Path, action="append", required=True)
    parser.add_argument("--label", default="unspecified")
    parser.add_argument("--source-revision", default="unknown")
    parser.add_argument("--notes", default="")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()

    results = [inspect_linkmap(p.resolve(strict=True)) for p in args.linkmap]
    all_passed = all(r["status"] == "pass" for r in results)
    payload = {
        "schemaVersion": 1,
        "label": args.label,
        "sourceRevision": args.source_revision,
        "notes": args.notes,
        "status": "pass" if all_passed else "fail",
        "linkmaps": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"Audited {len(results)} LinkMap(s); status={payload['status']}")
    for r in results:
        print(f"  {r['linkmapName']}: total={r['totalObjectEntries']} status={r['status']} counts={r['bucketCounts']}")
        if r["unknownEntries"] or r["prohibitedEntries"] or r["unexpectedWebRTCEntries"]:
            print(f"    violations: unknown={r['unknownEntries']} prohibited={r['prohibitedEntries']} extraWebRTC={r['unexpectedWebRTCEntries']}")
    if not all_passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
