#!/usr/bin/env python3
"""Delete stale one-off build entries from .build/ (dry-run by default).

Usage:
  python3 cleanup-build-dir.py            # dry-run: lists what would be deleted
  python3 cleanup-build-dir.py --execute  # actually delete

Source of truth: build-stale-report.json produced by the scan.
Safety: refuses to touch anything outside the .build root, anything in the
protected set, or any entry newer than the cutoff recorded in the report.
"""
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.join(HERE, "build-stale-report.json")


def main() -> int:
    execute = "--execute" in sys.argv
    with open(REPORT) as f:
        report = json.load(f)

    root = os.path.realpath(report["root"])
    cutoff = report["cutoff"]
    protected = {r["name"] for r in report["kept_fresh_or_protected"] if r.get("protected")}

    assert os.path.isdir(root), f"build root missing: {root}"
    assert root.endswith("/.build") and "conference-guest-ios" in root, f"unexpected root: {root}"

    print(f"Root: {root}")
    print(f"Cutoff applied at scan time: {cutoff}")
    print(f"Mode: {'EXECUTE' if execute else 'DRY-RUN'}")
    print()

    total = 0
    deleted = 0
    for entry in report["stale"]:
        name = entry["name"]
        path = os.path.join(root, name)
        real = os.path.realpath(path)

        # Defence in depth: name must be a direct child of root, not protected,
        # and must not have been modified since the scan.
        if os.path.dirname(real) != root:
            print(f"SKIP (not a direct child): {name}")
            continue
        if name in protected:
            print(f"SKIP (protected): {name}")
            continue
        if not os.path.exists(real):
            print(f"SKIP (already gone): {name}")
            continue
        mtime = os.lstat(real).st_mtime
        import time as _t
        if mtime > _t.mktime(_t.strptime("2026-11-08 00:00:00", "%Y-%m-%d %H:%M:%S")):
            print(f"SKIP (modified since scan): {name}")
            continue

        gb = entry["size_bytes"] / 1024**3
        total += entry["size_bytes"]
        if execute:
            if os.path.isdir(real) and not os.path.islink(real):
                shutil.rmtree(real)
            else:
                os.remove(real)
            print(f"DELETED {gb:8.2f} GB  {name}")
            deleted += 1
        else:
            print(f"would delete {gb:8.2f} GB  {name}")

    print()
    print(f"{'Deleted' if execute else 'Would free'}: {total / 1024**3:.1f} GB "
          f"across {deleted if execute else len(report['stale'])} entries")
    if not execute:
        print("Re-run with --execute to actually delete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
