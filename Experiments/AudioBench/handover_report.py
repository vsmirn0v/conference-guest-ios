#!/usr/bin/env python3
"""Summarise microphone moves between meetings from diagnostics logs.

Each move logs one `talk-handover` event (Rock'N'Roll for Mac 0.3.0 build 58+):
release (previous meeting lets go), assume (this meeting takes the talk role),
total (click to confirmed unmute), and the target engine's steps: permission,
activation (device and voice processing), then the service step
(`unmuteConfirmation` for Guest, `renegotiation` for Telemost/TrueConf).

Give it exported diagnostics archives (.zip), folders or log files:

    python3 Experiments/AudioBench/handover_report.py ~/Downloads/RockNRoll-diagnostics-*.zip
"""
import json
import pathlib
import statistics
import sys
import zipfile


def lines(path):
    path = pathlib.Path(path).expanduser()
    if path.is_dir():
        for child in sorted(path.rglob("*")):
            if child.is_file():
                yield from lines(child)
    elif path.suffix == ".zip":
        with zipfile.ZipFile(path) as archive:
            for name in archive.namelist():
                if not name.endswith("/"):
                    yield from archive.read(name).decode("utf-8", "replace").splitlines()
    elif path.is_file():
        yield from path.read_text(encoding="utf-8", errors="replace").splitlines()


def events(paths):
    seen = set()
    for path in paths:
        for line in lines(path):
            if "talk-handover" not in line or "{" not in line:
                continue
            try:
                event = json.loads(line[line.index("{"):])
            except ValueError:
                continue
            key = (event.get("uptime"), event.get("totalMs"))
            if event.get("event") == "talk-handover" and key not in seen:
                seen.add(key)
                yield event


def summary(values):
    values = [v for v in values if isinstance(v, (int, float))]
    if not values:
        return "-"
    values.sort()
    p90 = values[min(len(values) - 1, int(round(0.9 * (len(values) - 1))))]
    return f"{statistics.median(values):7.0f} / {p90:7.0f}"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    groups = {}
    for event in events(sys.argv[1:]):
        key = (event.get("from", "none"), event.get("to", "?"), bool(event.get("keptWarm")))
        groups.setdefault(key, []).append(event)
    if not groups:
        sys.exit("No talk-handover events found.")
    print("median / p90 in milliseconds\n")
    header = f"{'from → to':24} {'warm':5} {'n':>3}  {'total':>15}  {'release':>15}  {'activation':>15}  {'service':>15}  failed"
    print(header); print("-" * len(header))
    for (source, target, warm), items in sorted(groups.items()):
        service = [e.get("steps", {}).get("unmuteConfirmation", e.get("steps", {}).get("renegotiation")) for e in items]
        failed = sum(1 for e in items if not e.get("live"))
        print(f"{source + ' → ' + target:24} {'yes' if warm else 'no':5} {len(items):3}  {summary([e.get('totalMs') for e in items]):>15}  "
              f"{summary([e.get('releaseMs') for e in items]):>15}  "
              f"{summary([e.get('steps', {}).get('activation') for e in items]):>15}  {summary(service):>15}  {failed}")
    print("\nThe largest column is what to attack: activation is the device and voice processing;"
          "\nservice is the Guest server confirmation or the Telemost/TrueConf renegotiation.")


if __name__ == "__main__":
    main()
