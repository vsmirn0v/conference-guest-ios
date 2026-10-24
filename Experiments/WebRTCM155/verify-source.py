#!/usr/bin/env python3
"""Reject any M155 source state except the complete locked patched tree."""
import argparse
import json
from source_tools import verify

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("--lock", help="Defaults to this experiment's m155-lock.json")
    args = parser.parse_args()
    print(json.dumps(verify(args.source, args.lock), indent=2))
