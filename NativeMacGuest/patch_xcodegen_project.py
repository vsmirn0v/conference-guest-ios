#!/usr/bin/env python3
"""Post-process an XcodeGen-generated pbxproj to remove duplicate group membership.

xcodegen 2.46.0 emits folder groups (e.g. Attention, Data, Engines) both as
children of the root mainGroup and as children of the group whose path is "."
(the target source root). Xcode rejects a group being a member of more than
one group. This script removes from the mainGroup any child that is also a
child of a group with path ".".

Usage: patch_xcodegen_project.py <path-to-project.pbxproj>
Idempotent: running it twice is a no-op the second time.
"""
import re
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        text = f.read()

    # Map group ID -> block body for every PBXGroup definition.
    groups = {}
    for m in re.finditer(
        r"^\t\t([0-9A-F]{24})(?: /\* .*? \*/)? = \{\n\t\t\tisa = PBXGroup;\n(.*?)\n\t\t\};",
        text,
        re.M | re.S,
    ):
        groups[m.group(1)] = m.group(2)

    def children_of(body: str):
        cm = re.search(r"children = \(\n(.*?)\n\t\t\t\);", body, re.S)
        if not cm:
            return []
        return re.findall(r"^\t\t\t\t([0-9A-F]{24}) /\* .*? \*/,$", cm.group(1), re.M)

    # Root mainGroup id.
    mm = re.search(r"mainGroup = ([0-9A-F]{24});", text)
    if not mm:
        print("mainGroup not found", file=sys.stderr)
        return 1
    main_id = mm.group(1)
    main_children = children_of(groups[main_id])

    # Children of every group whose path is "." (source root groups).
    dot_children = set()
    for gid, body in groups.items():
        if re.search(r'path = \.;', body):
            dot_children.update(children_of(body))

    dupes = [c for c in main_children if c in dot_children]
    if not dupes:
        print("no duplicate group membership found; nothing to do")
        return 0

    # Remove dupe child lines from the mainGroup children list.
    main_block = groups[main_id]
    cm = re.search(
        r"(children = \(\n)(.*?)(\n\t\t\t\);)", main_block, re.S
    )
    kept = []
    for line in cm.group(2).splitlines(keepends=True):
        cid = re.match(r"\t\t\t\t([0-9A-F]{24}) /\*", line)
        if cid and cid.group(1) in dupes:
            continue
        kept.append(line)
    new_block = main_block[: cm.start(2)] + "".join(kept) + main_block[cm.end(2):]
    text = text.replace(main_block, new_block, 1)

    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    names = [
        re.search(re.escape(c) + r" /\* (.*?) \*/", text).group(1) for c in dupes
    ]
    print(f"removed duplicate mainGroup children: {', '.join(names)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
