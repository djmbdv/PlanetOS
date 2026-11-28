#!/usr/bin/env python3
"""Automatic non-overlapping image-base allocator and verifier for PlanetOS .dlib files.

Reads PLAN v1 section headers from compiled .dlib files in <libdir> to compute
exact virtual memory spans [min_va, max_end) and pack all shared libraries
inside the kernel's reserved dlib window [0x1800000, 0x2000000).
"""
import os
import struct
import sys

WINDOW_START = 0x1800000
WINDOW_END = 0x2000000
ALIGN = 0x10000  # 64 KiB alignment between libraries
HEADROOM = 0x10000  # 64 KiB growth headroom when packing from previous build

LIBS = [
    ("glib", 0x180000),
    ("unsafe", 0x40000),
    ("gee", 0x40000),
    ("cairo", 0x40000),
    ("spirv", 0x40000),
    ("venus", 0x40000),
    ("gobject", 0x40000),
    ("gio", 0x100000),
    ("gdk", 0x40000),
    ("pango", 0x60000),
    ("gmodule", 0x40000),
    ("gsk", 0x60000),
    ("gtk", 0xC0000),
]


def align_up(v: int, a: int) -> int:
    return (v + a - 1) & ~(a - 1)


def read_dlib_span(path: str):
    with open(path, "rb") as f:
        data = f.read(4096)
    if len(data) < 64 or data[:4] != b"PLAN":
        raise ValueError(f"{path}: not a PLAN dlib")
    sec_count = struct.unpack_from("<I", data, 24)[0]
    if 64 + sec_count * 32 > len(data):
        with open(path, "rb") as f:
            data = f.read(64 + sec_count * 32)
    min_va = None
    max_end = 0
    for i in range(sec_count):
        va, _off, _fsz, msz = struct.unpack_from("<QQQQ", data, 64 + i * 32)
        if va == 0 and msz == 0:
            continue
        end = va + (msz if msz > 0 else 1)
        if min_va is None or va < min_va:
            min_va = va
        if end > max_end:
            max_end = end
    if min_va is None:
        raise ValueError(f"{path}: empty section table")
    base = min_va & ~0xFFF
    return base, max_end


def cmd_plan(libdir: str, fmt: str) -> int:
    cursor = WINDOW_START
    assignments = []
    for name, default_span in LIBS:
        dlib_path = os.path.join(libdir, name, f"{name}.dlib")
        span = default_span
        if os.path.isfile(dlib_path):
            try:
                base, end = read_dlib_span(dlib_path)
                span = align_up((end - base) + HEADROOM, ALIGN)
            except Exception:
                pass
        if cursor + span > WINDOW_END:
            print(
                f"dlib_layout: {name} ({cursor:#x}+{span:#x}) exceeds {WINDOW_END:#x}",
                file=sys.stderr,
            )
            return 1
        assignments.append((name, cursor))
        cursor = align_up(cursor + span, ALIGN)

    for name, base in assignments:
        if fmt == "--shell":
            print(f"BASE_{name}={base:#x}")
        elif fmt == "--ps1":
            print(f"{name}={base:#x}")
        else:
            print(f"{name} {base:#x}")
    return 0


def cmd_verify(libdir: str) -> int:
    ranges = []
    for name, _ in LIBS:
        dlib_path = os.path.join(libdir, name, f"{name}.dlib")
        if not os.path.isfile(dlib_path):
            continue
        base, end = read_dlib_span(dlib_path)
        if base < WINDOW_START or end > WINDOW_END:
            print(
                f"dlib_layout: {name} [{base:#x}, {end:#x}) outside [{WINDOW_START:#x}, {WINDOW_END:#x})",
                file=sys.stderr,
            )
            return 1
        ranges.append((base, end, name))

    ranges.sort()
    for i in range(len(ranges) - 1):
        b1, e1, n1 = ranges[i]
        b2, e2, n2 = ranges[i + 1]
        if e1 > b2:
            print(
                f"dlib_layout: overlap {n1} [{b1:#x}, {e1:#x}) with {n2} [{b2:#x}, {e2:#x})",
                file=sys.stderr,
            )
            return 1
    total_end = ranges[-1][1] if ranges else WINDOW_START
    print(f"dlib_layout: {len(ranges)} dlibs packed in [{WINDOW_START:#x}, {total_end:#x}) (limit {WINDOW_END:#x})")
    return 0


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: dlib_layout.py <plan|verify> <libdir> [--shell|--ps1]", file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    libdir = sys.argv[2]
    fmt = sys.argv[3] if len(sys.argv) > 3 else ""
    if cmd == "plan":
        return cmd_plan(libdir, fmt)
    if cmd == "verify":
        return cmd_verify(libdir)
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
