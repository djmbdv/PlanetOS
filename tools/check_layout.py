#!/usr/bin/env python3
"""Fails the build when the kernel's fixed low-memory window is broken.

The kernel keeps byte buffers that the compiler cannot place (planc has no
arrays, only scalar globals) at fixed physical addresses: page tables, the
multiboot pointer, the PS/2 rings, the fd table, the PMM bitmap, the RAMFS
table, the TCB and FXSAVE areas. kernel/layout.vala declares all of them as one
region table; this gate is the build-time half of the check and
KernelLayout.verify is the boot-time half.

It stops the build when:
  1. the regions are not ascending, overlap, or leave the window;
  2. the window reaches the boot stack, the PMM range or the image base;
  3. the produced image (PT_LOAD vaddr + memsz, so .bss counts) touches the
     window or the boot stack;
  4. an address that only exists as a literal inside an asm body drifts away
     from the constant it is supposed to mirror.

Usage: check_layout.py <kernel-image>
"""

import ast
import operator
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAYOUT = os.path.join(ROOT, "kernel", "layout.vala")

# Region table, in the same order as KernelLayout.verify (): label, base, size.
REGIONS = [
    ("page tables", "PAGE_TABLES", "PAGE_TABLES_SIZE"),
    ("GDT/TSS", "GDT", "GDT_TSS_SIZE"),
    ("IDT", "IDT", "IDT_SIZE"),
    ("cpu variables", "TICK", "CPU_VARS_SIZE"),
    ("multiboot pointer", "MB_INFO", "MB_INFO_SIZE"),
    ("keyboard ring", "KB_RING", "KB_RING_SIZE"),
    ("keyboard cursors", "KB_HEAD", "KB_POS_SIZE"),
    ("exec slots", "EXEC_SLOTS", "EXEC_SLOTS_SIZE"),
    ("mouse ring", "MOUSE_RING", "MOUSE_RING_SIZE"),
    ("mouse cursors", "MOUSE_HEAD", "MOUSE_POS_SIZE"),
    ("syscall scratch", "SYSCALL_SCRATCH", "SYSCALL_SCRATCH_SIZE"),
    ("fd table", "FD_TABLE", "FD_TABLE_SIZE"),
    ("guarded copy variables", "COPY_VARS", "COPY_VARS_SIZE"),
    ("kernel log ring", "KLOG_RING", "KLOG_RING_SIZE"),
    ("io scratch", "IO_SCRATCH", "IO_SCRATCH_SIZE"),
    ("ramfs table", "RAMFS_TABLE", "RAMFS_TABLE_SIZE"),
    ("scheduler variables", "SCHED_CUR", "SCHED_VARS_SIZE"),
    ("TCB table", "TCB_TABLE", "TCB_TABLE_SIZE"),
    ("FXSAVE area", "FXSAVE_AREA", "FXSAVE_AREA_SIZE"),
    ("alloc table", "ALLOC_TABLE", "ALLOC_TABLE_SIZE"),
    ("grant acl", "GRANT_ACL", "GRANT_ACL_SIZE"),
    ("pmm bitmap", "PMM_BITMAP", "PMM_BITMAP_SIZE"),
]

# Addresses that only exist as literals inside asm bodies, which cannot use the
# Vala constants. mask is the page-flag mask the literal ORs into the address.
ASM_REFS = [
    ("planetrt/boot_mb2.vala", "MB_INFO", 0),
    ("planetrt/boot_mb2.vala", "PAGE_TABLES", 0),
    ("planetrt/boot_mb2.vala", "PDPT", 0xFFF),
    ("planetrt/boot_mb2.vala", "PD", 0xFFF),
    ("planetrt/boot_mb2.vala", "GDT", 0),
    ("planetrt/boot_mb2.vala", "STACK_TOP", 0),
    ("planetrt/boot_mb2.vala", "IMAGE_BASE", 0),
    ("kernel/cpu.vala", "TICK", 0),
    ("kernel/elf_loader.vala", "TSS_RSP0", 0),
    ("kernel/keyboard.vala", "KB_RING", 0),
    ("kernel/keyboard.vala", "KB_HEAD", 0),
    ("kernel/syscall.vala", "COPY_VARS", 0),
    ("kernel/mouse.vala", "MOUSE_RING", 0),
    ("kernel/mouse.vala", "MOUSE_HEAD", 0),
]

CONST_RE = re.compile(r"public const int (\w+)\s*=\s*([^;]+?)\s*;")
HEX_RE = re.compile(r"0x[0-9A-Fa-f]+")

_BIN_OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.FloorDiv: operator.floordiv,
    ast.Div: operator.floordiv,
    ast.Mod: operator.mod,
    ast.LShift: operator.lshift,
    ast.RShift: operator.rshift,
    ast.BitOr: operator.or_,
    ast.BitAnd: operator.and_,
    ast.BitXor: operator.xor,
}
_UNARY_OPS = {
    ast.UAdd: operator.pos,
    ast.USub: operator.neg,
    ast.Invert: operator.invert,
}


def _eval_const(node, consts):
    if isinstance(node, ast.Expression):
        return _eval_const(node.body, consts)
    if isinstance(node, ast.Constant) and isinstance(node.value, int):
        return node.value
    if isinstance(node, ast.Name) and node.id in consts:
        return consts[node.id]
    if isinstance(node, ast.BinOp) and type(node.op) in _BIN_OPS:
        return _BIN_OPS[type(node.op)](_eval_const(node.left, consts), _eval_const(node.right, consts))
    if isinstance(node, ast.UnaryOp) and type(node.op) in _UNARY_OPS:
        return _UNARY_OPS[type(node.op)](_eval_const(node.operand, consts))
    raise ValueError(f"unsupported const expr: {ast.dump(node)}")


def read_consts():
    text = open(LAYOUT, "r", encoding="utf-8").read()
    consts = {}
    for name, value in CONST_RE.findall(text):
        consts[name] = _eval_const(ast.parse(value.strip(), mode="eval"), consts)
    return consts


def check_regions(consts):
    if "WINDOW_BASE" not in consts or "WINDOW_END" not in consts:
        return "kernel/layout.vala does not declare WINDOW_BASE/WINDOW_END"
    window_end = consts["WINDOW_END"]
    cursor = consts["WINDOW_BASE"]
    for label, base_name, size_name in REGIONS:
        if base_name not in consts or size_name not in consts:
            return "kernel/layout.vala does not declare %s/%s" % (base_name, size_name)
        base = consts[base_name]
        size = consts[size_name]
        if size <= 0:
            return "%s (%s) has size 0x%x" % (label, base_name, size)
        if base < cursor:
            return ("%s (%s at 0x%x) starts below 0x%x, so it overlaps the "
                    "previous region" % (label, base_name, base, cursor))
        end = base + size
        if end > window_end:
            return ("%s (%s) ends at 0x%x, past the window end 0x%x"
                    % (label, base_name, end, window_end))
        cursor = end

    if window_end > consts["STACK_LIMIT"]:
        return ("the window ends at 0x%x, inside the boot stack (limit 0x%x)"
                % (window_end, consts["STACK_LIMIT"]))
    if consts["RESERVED_END"] < window_end:
        return ("Pmm hands out frames from 0x%x, inside a window that ends at 0x%x"
                % (consts["RESERVED_END"], window_end))
    if consts["IMAGE_BASE"] < window_end:
        return ("the image is loaded at 0x%x, inside a window that ends at 0x%x"
                % (consts["IMAGE_BASE"], window_end))
    if not (consts["STACK_LIMIT"] <= consts["LEGACY_STACK"] < consts["LEGACY_ARGV"]
            < consts["STACK_TOP"]):
        return ("LEGACY_STACK/LEGACY_ARGV (0x%x/0x%x) are not inside the boot "
                "stack [0x%x, 0x%x)" % (consts["LEGACY_STACK"], consts["LEGACY_ARGV"],
                                        consts["STACK_LIMIT"], consts["STACK_TOP"]))
    return None


def check_asm_literals(consts):
    for relpath, const_name, mask in ASM_REFS:
        path = os.path.join(ROOT, relpath.replace("/", os.sep))
        if not os.path.isfile(path):
            return "missing %s" % relpath
        want = consts[const_name]
        text = open(path, "r", encoding="utf-8").read()
        for literal in HEX_RE.findall(text):
            if int(literal, 16) & ~mask == want:
                break
        else:
            return ("%s no longer carries the literal for %s (0x%x): the asm "
                    "body and kernel/layout.vala have drifted apart"
                    % (relpath, const_name, want))
    return None


def check_image(path, consts):
    image = open(path, "rb").read()
    if image[:4] != b"\x7fELF" or image[4] != 2:
        return None, "%s is not an ELF64 image" % path
    phoff = struct.unpack_from("<Q", image, 0x20)[0]
    phentsize = struct.unpack_from("<H", image, 0x36)[0]
    phnum = struct.unpack_from("<H", image, 0x38)[0]
    spans = []
    for i in range(phnum):
        off = phoff + i * phentsize
        if struct.unpack_from("<I", image, off)[0] != 1:  # PT_LOAD
            continue
        vaddr = struct.unpack_from("<Q", image, off + 0x10)[0]
        memsz = struct.unpack_from("<Q", image, off + 0x28)[0]
        if memsz:
            spans.append((vaddr, vaddr + memsz))
    if not spans:
        return None, "%s has no loadable segment" % path
    low = min(start for start, _ in spans)
    high = max(end for _, end in spans)
    window = (consts["WINDOW_BASE"], consts["STACK_TOP"])
    for start, end in spans:
        if start < window[1] and end > window[0]:
            return None, ("the image spans 0x%x..0x%x, which overlaps the fixed "
                          "kernel window [0x%x, 0x%x)"
                          % (start, end, window[0], window[1]))
    return (low, high), None


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("check_layout.py: usage: check_layout.py <kernel-image>\n")
        return 2
    consts = read_consts()

    problem = check_regions(consts)
    if problem is None:
        problem = check_asm_literals(consts)
    known = None
    if problem is None:
        known, problem = check_image(sys.argv[1], consts)
    if problem is not None:
        sys.stderr.write("layout: %s\n" % problem)
        return 1

    print("layout: %d regions inside [0x%x, 0x%x), image 0x%x..0x%x clear of it"
          % (len(REGIONS), consts["WINDOW_BASE"], consts["WINDOW_END"],
             known[0], known[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
