#!/usr/bin/env python3
"""Builds the in-guest SDK prelude (`c2plan_sdk.plan`) shipped in the boot image.

`planc` type-checks every declaration it compiles, so a C program translated by
`c2plan` needs the GLib layer *sources* next to `c2plan_rt.plan`: the shared
`glib.dlib` exports symbol addresses, not types. The guest shell line buffer is
480 bytes, so the c2plan regression test cannot spell them out, and this packs
the subset `c2plan_rt.plan` needs into one file.

Usage: make_sdk.py <out.plan>
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# `glib.hlib` is now loaded implicitly by `planc --target=planetos` from
# `/library/glib/`, so `c2plan_sdk.plan` only needs `c2plan_rt.plan`.
SOURCES = [
    "tools/c2plan_rt.plan",
]


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("make_sdk.py: usage: make_sdk.py <out.vala>\n")
        return 2
    out_path = sys.argv[1]
    parts = []
    for rel in SOURCES:
        with open(os.path.join(ROOT, rel), "r", encoding="utf-8-sig") as handle:
            text = handle.read()
        parts.append("// ---- %s ----\n" % os.path.basename(rel))
        parts.append(text.rstrip("\n") + "\n")
    with open(out_path, "w", encoding="utf-8", newline="\n") as out:
        out.write("\n".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())