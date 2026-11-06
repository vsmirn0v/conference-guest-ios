#!/usr/bin/env python3
"""Writes VoiceModels.json: the VoxCPM2 Neural Engine bundle for every Apple chip, pinned.

Each chip family has its own compiled bundle under macos27/<architecture>/ in the converted
repository. Every file is pinned to the repository commit and a SHA-256: large files carry it
in the Hub's LFS metadata; small files are downloaded once here and hashed. The app downloads
only the files listed for its own chip and checks each hash, as it does for listen models.

Usage: python3 -I voice-model-catalog.py [--commit SHA] [--out VoiceModels.json]
Standard library only.
"""

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.parse
import urllib.request

REPO = "wegotomars/VoxCPM2-LUT8-CoreAI-ANE"
# v2.2.0 of the converted bundle; the runtime port checks model.json's source revisions.
COMMIT = "65ebf2867f518c0fe59ca1cf470c9302aa1f194c"
API = "https://huggingface.co/api/models"
AGENT = "RockNRoll-voice-catalog/1"


def fetch(url, attempts=4):
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": AGENT})
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.read()
        except Exception:
            if attempt == attempts - 1:
                raise
            time.sleep(2 * (attempt + 1))


def tree(commit, path):
    entries, url = [], f"{API}/{REPO}/tree/{commit}/{urllib.parse.quote(path)}?recursive=1"
    while url:
        request = urllib.request.Request(url, headers={"User-Agent": AGENT})
        with urllib.request.urlopen(request, timeout=120) as response:
            entries += json.loads(response.read())
            links = response.headers.get("Link", "")
        url = None
        for part in links.split(","):
            if 'rel="next"' in part:
                url = part[part.index("<") + 1:part.index(">")]
    return entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--commit", default=COMMIT)
    parser.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "VoiceModels.json"))
    args = parser.parse_args()

    listing = json.loads(fetch(f"{API}/{REPO}/tree/{args.commit}/macos27"))
    architectures = sorted(entry["path"].split("/")[1] for entry in listing
                           if entry["type"] == "directory" and entry["path"].count("/") == 1)
    if not architectures:
        sys.exit("no architectures found")
    result = {}
    for architecture in architectures:
        prefix = f"macos27/{architecture}/"
        files = []
        for entry in tree(args.commit, prefix.rstrip("/")):
            if entry["type"] != "file":
                continue
            name = entry["path"][len(prefix):]
            if entry.get("lfs"):
                digest = entry["lfs"]["oid"]
            else:
                data = fetch(f"https://huggingface.co/{REPO}/resolve/{args.commit}/{urllib.parse.quote(entry['path'])}")
                if len(data) != entry["size"]:
                    sys.exit(f"{entry['path']}: size {len(data)} differs from {entry['size']}")
                # The Hub's oid of a small file is its git blob hash: confirm the bytes before pinning them.
                blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
                if blob != entry["oid"]:
                    sys.exit(f"{entry['path']}: git blob hash differs")
                digest = hashlib.sha256(data).hexdigest()
            files.append({"name": name, "size": entry["size"], "sha256": digest})
        names = {item["name"] for item in files}
        if "model.json" not in names or "checkpoint/model.safetensors" not in names:
            print(f"skipping {architecture}: incomplete bundle", file=sys.stderr)
            continue
        files.sort(key=lambda item: item["name"])
        result[architecture] = files
        print(f"{architecture}: {len(files)} files, {sum(f['size'] for f in files) / 1e9:.2f} GB", file=sys.stderr)

    catalog = {
        "schemaVersion": 1,
        "id": "voxcpm2-lut8",
        "title": "VoxCPM2 (Neural Engine)",
        "licence": "Apache-2.0 (OpenBMB VoxCPM2; Core AI conversion by tinkerbox-ane)",
        "source": f"https://huggingface.co/{REPO}",
        "repo": REPO,
        "commit": args.commit,
        "architectures": result,
    }
    with open(args.out, "w", encoding="utf-8") as stream:
        json.dump(catalog, stream, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        stream.write("\n")
    print(f"wrote {args.out}: {len(result)} architectures", file=sys.stderr)


if __name__ == "__main__":
    main()
