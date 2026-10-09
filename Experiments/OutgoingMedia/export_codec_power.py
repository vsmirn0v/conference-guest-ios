#!/usr/bin/env python3
"""Sanitize Instruments system samples and weight them over decoder phases."""
import argparse
import csv
from datetime import datetime
import json
from pathlib import Path
import xml.etree.ElementTree as ET
from summarize_system_power import summarize

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
args = parser.parse_args()
start = datetime.fromisoformat(ET.parse(args.directory / "toc.xml").findtext(".//start-date")).timestamp()
root = ET.parse(args.directory / "system.xml").getroot()
references = {node.attrib["id"]: node for node in root.iter() if "id" in node.attrib}


def value(node):
    while "ref" in node.attrib:
        node = references[node.attrib["ref"]]
    return float(node.text)


samples = []
for row in root.iter("row"):
    columns = list(row)
    samples.append(dict(wall_start_s=start + value(columns[0]) / 1e9, duration_s=value(columns[1]) / 1e9,
                        system_percent_per_hour=value(columns[2]), brightness_percent=value(columns[3])))
phases = []
for line in (args.directory / "test.log").read_text(errors="replace").splitlines():
    if "CODEC_MEASURE_END " in line:
        row = json.loads(line.split("CODEC_MEASURE_END ", 1)[1])
        phases.append(dict(profile=row["mode"], wall_start_s=row["wall_start_s"], wall_end_s=row["wall_end_s"]))
results = list(summarize(samples, phases))
for filename, rows in [("system-samples.csv", samples), ("phase-power.csv", results)]:
    with (args.directory / filename).open("w") as stream:
        writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
        writer.writeheader(); writer.writerows(rows)
print(json.dumps(results, indent=2))
