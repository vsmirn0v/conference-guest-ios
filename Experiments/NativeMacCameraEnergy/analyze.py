#!/usr/bin/env python3
"""Summarize CameraEnergyProbe windows: per-profile median CPU and delivered format."""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

CAMERA_SERVICES = ("appleh16camerad", "appleh13camerad", "cameracaptured", "VDCAssistant",
                   "avconferenced", "mediaserverd", "WindowServer", "CameraEnergyProbe")

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if '"window"' in line]
groups = defaultdict(list)
for row in rows:
    groups[row["phase"]].append(row)
print(f"{'phase':28} {'n':>2} {'delivered':>11} {'fps':>6} {'BG':>3} {'probe%':>7} {'system%':>8}  top services")
for phase, items in groups.items():
    services = defaultdict(list)
    for item in items:
        totals = defaultdict(float)
        for entry in item["topProcesses"]:
            name = entry["process"].split(" ", 1)[1]
            if name.startswith(CAMERA_SERVICES):
                totals[name] += entry["cpuPercent"]
        for name, value in totals.items():
            services[name].append(value)
    first = items[0]
    detail = ", ".join(f"{n} {statistics.median(v):.1f}" for n, v in sorted(services.items(), key=lambda x: -statistics.median(x[1])))
    print(f"{phase:28} {len(items):>2} {first.get('delivered', '-'):>11} {statistics.median(i.get('deliveredFPS', 0) for i in items):6.2f} "
          f"{'y' if first.get('backgroundActive') else 'n':>3} {statistics.median(i['probeCPUPercent'] for i in items):7.1f} "
          f"{statistics.median(i['systemCPUPercent'] for i in items):8.1f}  {detail}")
