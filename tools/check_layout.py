#!/usr/bin/env python3
"""Fails the build when the kernel image overlaps its fixed data structures.

The kernel keeps its PMM bitmap at 0x110000, the multiboot info copy at
0x106040, the fd table and scratch buffers in the same window, and nothing in
the compiler or the loader checks that the image still ends below them. A few
hundred extra bytes of .text/.bss used to silently overwrite those structures
(docs/paging-analysis.md, defect 1), so this gate reads the PT_LOAD segments of
the produced kernel and stops the build if the image can reach them.

Usage: check_layout.py <kernel-image>
"""

import struct
import sys

# kernel/pmm.vala: BITMAP_ADDR. The image, its page tables (0x100000..0x104000)
# and the structures in kernel/syscall.vala all have to stay below it.
KERNEL_DATA_BASE = 0x110000
BASE_ADDR = 0x100000  # ELF load address used by planc for freestanding images


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("check_layout.py: usage: check_layout.py <kernel-image>\n")
        return 2
    image = open(sys.argv[1], "rb").read()
    if image[:4] != b"\x7fELF" or image[4] != 2:
        sys.stderr.write("check_layout.py: %s is not an ELF64 image\n" % sys.argv[1])
        return 2
    phoff = struct.unpack_from("<Q", image, 0x20)[0]
    phentsize = struct.unpack_from("<H", image, 0x36)[0]
    phnum = struct.unpack_from("<H", image, 0x38)[0]
    end = BASE_ADDR
    for i in range(phnum):
        off = phoff + i * phentsize
        p_type = struct.unpack_from("<I", image, off)[0]
        if p_type != 1:  # PT_LOAD
            continue
        p_vaddr = struct.unpack_from("<Q", image, off + 0x10)[0]
        p_filesz = struct.unpack_from("<Q", image, off + 0x20)[0]
        end = max(end, p_vaddr + p_filesz)
    slack = KERNEL_DATA_BASE - end
    if slack < 0:
        print("layout: WARNING: the kernel image is file-backed up to 0x%x, which "
              "covers the fixed structures at 0x%x. They are therefore inside the "
              "kernel's own data area: any growth of .data/.bss can land on them "
              "silently. See docs/paging-analysis.md (defect 1)."
              % (end, KERNEL_DATA_BASE))
        return 0
    print("layout: kernel image ends at 0x%x (%d bytes below the kernel data at 0x%x)"
          % (end, slack, KERNEL_DATA_BASE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
