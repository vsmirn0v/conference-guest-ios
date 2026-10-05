#!/usr/bin/env python3
"""Overlap-weighted system power estimates from sanitized Instruments/phase CSVs."""
import argparse
import csv
import math
import sys


def summarize(samples, phases):
    for phase in phases:
        start, end = float(phase["wall_start_s"]), float(phase["wall_end_s"])
        if not math.isfinite(start + end) or end <= start:
            raise ValueError("Invalid phase interval")
        covered = power = brightness = 0.0
        for sample in samples:
            t, duration = float(sample["wall_start_s"]), float(sample["duration_s"])
            overlap = max(0, min(end, t + duration) - max(start, t))
            covered += overlap
            power += overlap * float(sample["system_percent_per_hour"])
            brightness += overlap * float(sample["brightness_percent"])
        if covered < (end - start) * 0.95:
            raise ValueError("Insufficient power samples for a phase")
        yield dict(profile=phase["profile"], wall_start_s=start, wall_end_s=end,
                   covered_s=covered, system_percent_per_hour=power / covered,
                   mean_brightness_percent=brightness / covered)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("samples", help="Sanitized SystemPowerLevel CSV")
    parser.add_argument("phases", help="Phase CSV with wall start/end times")
    args = parser.parse_args()
    with open(args.samples) as f:
        samples = list(csv.DictReader(f))
    with open(args.phases) as f:
        rows = list(summarize(samples, csv.DictReader(f)))
    if not rows:
        raise ValueError("No phases")
    writer = csv.DictWriter(sys.stdout, fieldnames=rows[0].keys())
    writer.writeheader()
    writer.writerows(rows)
