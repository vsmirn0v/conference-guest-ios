#!/usr/bin/env python3
"""Prepare pinned, patched M155 source into a new workspace; never fetch/build."""
import argparse
from source_tools import prepare

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", help="Locally available pristine M155 source.tar.gz")
    parser.add_argument("output", help="New workspace; existing paths are rejected")
    parser.add_argument("--lock", help="Defaults to this experiment's m155-lock.json")
    args = parser.parse_args()
    print(prepare(args.archive, args.output, args.lock))
