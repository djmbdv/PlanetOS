#!/usr/bin/env python3
"""Builds the in-guest SDK prelude (`c2vala_sdk.vala`) shipped in the boot image.

`planc` type-checks every declaration it compiles, so a C program translated by
`c2vala` needs the GLib layer *sources* next to `c2vala_rt.vala`: the shared
`glib.dlib` exports symbol addresses, not types. The guest shell line buffer is
480 bytes, so the c2vala regression test cannot spell them out, and this packs
the subset `c2vala_rt.vala` needs into one file.

Usage: make_sdk.py <out.vala>
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Only what c2vala_rt.vala actually references: Sys (planet_sys), StringChunk
# (core), FileStream (filestream), Memory (memory), Thread/Mutex/Cond (thread,
# which now builds its futex path on AtomicPointer) and get_real_time (time).
# Adding the rest of GLIB_SRCS only grows the AST the guest compiler has to
# build.
SOURCES = [
    "stdlib/planet_sys.vala",
    "stdlib/glib/core.vala",
    "stdlib/glib/filestream.vala",
    "stdlib/glib/memory.vala",
    "stdlib/glib/atomic.vala",
    "stdlib/glib/thread.vala",
    "stdlib/glib/queue.vala",
    "stdlib/glib/time.vala",
    "tools/c2vala_rt.vala",
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