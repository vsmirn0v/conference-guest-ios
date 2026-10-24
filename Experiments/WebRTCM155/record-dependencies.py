#!/usr/bin/env python3
"""Record dependency tooling and actual checkout identities without syncing."""
import argparse
import ast
import json
import os
from pathlib import Path
import subprocess
import sys

from source_tools import digest, load_lock, verify


def record(workspace, depot_tools, output, lock_path=None):
    workspace, depot_tools = Path(workspace).resolve(strict=True), Path(depot_tools).resolve(strict=True)
    output = Path(output)
    if output.exists() or output.is_symlink():
        raise ValueError(f"Dependency record already exists: {output}")
    lock, _, _, _, _, _ = load_lock(lock_path)
    source = verify(workspace / "src", lock_path)
    for name, key in (("DEPS", "deps"), (".gclient", "gclient")):
        if digest(workspace / name) != lock["dependencies"][key]["sha256"]:
            raise ValueError(f"Workspace dependency identity mismatch: {name}")
    gclient = depot_tools / "gclient"
    env = dict(os.environ, DEPOT_TOOLS_UPDATE="0")

    def command(*args):
        return subprocess.check_output(args, cwd=workspace, env=env, text=True).strip()

    # Read recorded dependency declarations as data. Do not invoke revinfo:
    # this depot_tools revision performs package reconciliation while parsing
    # recursive M155 DEPS, which is unsuitable for a read-only recorder.
    entries_path = workspace / ".gclient_entries"
    syntax = ast.parse(entries_path.read_text())
    if (len(syntax.body) != 1 or not isinstance(syntax.body[0], ast.Assign) or
            len(syntax.body[0].targets) != 1 or
            not isinstance(syntax.body[0].targets[0], ast.Name) or
            syntax.body[0].targets[0].id != "entries"):
        raise ValueError("Unexpected gclient entries data syntax")
    entries = ast.literal_eval(syntax.body[0].value)
    git_revisions = {}
    package_entries = {}
    for name, url in sorted(entries.items()):
        if not isinstance(name, str) or not isinstance(url, str):
            raise ValueError("Invalid dependency entry")
        if ":" in name:
            package_entries[name] = url
            continue
        path = (workspace / name).resolve()
        if not path.is_relative_to(workspace):
            raise ValueError("Dependency path escapes workspace")
        if not (path / ".git").exists():
            git_revisions[name] = {"declared": url, "available": False}
            continue
        actual = command("git", "-C", str(path), "rev-parse", "HEAD")
        expected = url.rsplit("@", 1)[-1] if "@" in url else None
        git_revisions[name] = {"declared": url, "available": True, "actual_revision": actual,
            "matches_declared_revision": actual == expected if expected else None,
            "tracked_changes": command("git", "-C", str(path), "status", "--porcelain", "--untracked-files=no")}

    result = {"source": source, "dependency_deps_sha256": digest(workspace / "DEPS"),
              "gclient_configuration_sha256": digest(workspace / ".gclient"),
              "depot_tools_path": str(depot_tools),
              "depot_tools_revision": command("git", "-C", str(depot_tools), "rev-parse", "HEAD"),
              "depot_tools_tracked_changes": command("git", "-C", str(depot_tools), "status", "--porcelain", "--untracked-files=no"),
              "gclient_launcher_sha256": digest(gclient),
              "gclient_python_sha256": digest(depot_tools / "gclient.py"),
              "python_executable": sys.executable,
              "gclient_revinfo": "Not invoked; actual Git revisions are read independently",
              "gclient_entries_sha256": digest(entries_path),
              "git_checkouts": git_revisions,
              "declared_non_git_packages_not_independently_verified": package_entries,
              "scope": "Read-only identity record; does not sync, build, or certify dependency file contents"}
    with output.open("x") as stream:
        stream.write(json.dumps(result, indent=2) + "\n")
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace")
    parser.add_argument("depot_tools")
    parser.add_argument("output")
    parser.add_argument("--lock")
    args = parser.parse_args()
    print(record(args.workspace, args.depot_tools, args.output, args.lock))
