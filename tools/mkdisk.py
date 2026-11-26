#!/usr/bin/env python3
"""Builds the PlanetOS boot disk (raw XFS image) from the compiled artifacts.

Usage:
    mkdisk.py <disk.img> [--add name=path]...
            <init.elf> <shell.elf> <planc.elf> <banner.elf>
              <worker.elf> <wc.elf> <cairo_demo.elf> <frag.spv> <spv_demo.elf>
              <gio_demo.elf> <utf8.vala> <class_basic.vala>
              <gobject_demo.elf> <gmodule_demo.elf> <mainloop_demo.elf> <compositor.elf> <pango_demo.elf> <jsmn_demo.elf> <c2vala.elf> <arith.c> <frag_pattern.spv>
              <gtk_demo.elf> <vk_demo.elf> <LiberationSans-Regular.ttf> <LiberationMono-Regular.ttf> <cursor.svg>
              <glib.dlib> <c2vala_sdk.vala> <sys_demo.elf>

Shared by run-qemu.sh and run-qemu.ps1 so both launchers produce the same
image layout. `c2vala_sdk.vala` is the concatenated SDK prelude built by
tools/make_sdk.py; in-guest translates of C code compile against it.
"""

import os
import struct
import sys

ROOT_ARG_COUNT = 37  # image + 36 root files


def blk(b):
    return (len(b) + 4095) // 4096


def write_dir_inode(img, fi, mode, parent_ino, dir_entries):
    struct.pack_into(">HH", img, fi, 0x494E, mode)
    img[fi + 4] = 2
    img[fi + 5] = 1
    struct.pack_into(">I", img, fi + 16, 2)  # nlink = 2
    df = fi + 100
    img[df + 0] = len(dir_entries)
    img[df + 1] = 0
    struct.pack_into(">I", img, df + 4, parent_ino)
    ent = df + 8
    for name, child_ino in dir_entries:
        img[ent] = len(name)
        struct.pack_into(">H", img, ent + 1, 0)
        img[ent + 3:ent + 3 + len(name)] = name
        struct.pack_into(">I", img, ent + 3 + len(name), child_ino)
        ent = ent + 3 + len(name) + 4


def write_file_inode(img, fi, data, sblk, mode):
    struct.pack_into(">HH", img, fi, 0x494E, mode)
    img[fi + 4] = 2
    img[fi + 5] = 2
    struct.pack_into(">Q", img, fi + 56, len(data))
    struct.pack_into(">I", img, fi + 76, 1)
    bc = blk(data)
    struct.pack_into(">QQ", img, fi + 100, 0, (sblk << 21) | bc)
    img[sblk * 4096:sblk * 4096 + len(data)] = data


def main():
    pos_args = []
    stdlib_paths = []
    lib_groups = {}
    extra_files = []
    i = 1
    while i < len(sys.argv):
        if sys.argv[i] == "--add":
            if i + 1 >= len(sys.argv) or "=" not in sys.argv[i + 1]:
                sys.stderr.write("mkdisk.py: --add requires name=path\n")
                return 2
            nm, ap = sys.argv[i + 1].split("=", 1)
            extra_files.append((nm.encode("utf-8"), ap))
            i += 2
        elif sys.argv[i] == "--stdlib":
            if i + 1 >= len(sys.argv):
                sys.stderr.write("mkdisk.py: --stdlib requires a path\n")
                return 2
            stdlib_paths.append(sys.argv[i + 1])
            i += 2
        elif sys.argv[i] == "--lib":
            if i + 1 >= len(sys.argv):
                sys.stderr.write("mkdisk.py: --lib requires a path\n")
                return 2
            p = sys.argv[i + 1]
            pkg = os.path.basename(os.path.dirname(p))
            lib_groups.setdefault(pkg, []).append(p)
            i += 2
        else:
            pos_args.append(sys.argv[i])
            i += 1

    if len(pos_args) != ROOT_ARG_COUNT:
        sys.stderr.write("mkdisk.py: expected %d positional arguments, got %d\n" % (ROOT_ARG_COUNT, len(pos_args)))
        return 2

    image_path = pos_args[0]
    root_specs = [
        (b"hello.txt", b"xfs:hello from PlanetOS disk!\n", 0x81A4),
        (b"init.elf", open(pos_args[1], "rb").read(), 0x81ED),
        (b"shell.elf", open(pos_args[2], "rb").read(), 0x81ED),
        (b"planc.elf", open(pos_args[3], "rb").read(), 0x81ED),
        (b"banner.elf", open(pos_args[4], "rb").read(), 0x81ED),
        (b"worker.elf", open(pos_args[5], "rb").read(), 0x81ED),
        (b"wc.elf", open(pos_args[6], "rb").read(), 0x81ED),
        (b"cairo_demo.elf", open(pos_args[7], "rb").read(), 0x81ED),
        (b"frag.spv", open(pos_args[8], "rb").read(), 0x81A4),
        (b"spv_demo.elf", open(pos_args[9], "rb").read(), 0x81ED),
        (b"gio_demo.elf", open(pos_args[10], "rb").read(), 0x81ED),
        (b"utf8.vala", open(pos_args[11], "rb").read(), 0x81A4),
        (b"class_basic.vala", open(pos_args[12], "rb").read(), 0x81A4),
        (b"gobject_demo.elf", open(pos_args[13], "rb").read(), 0x81ED),
        (b"gmodule_demo.elf", open(pos_args[14], "rb").read(), 0x81ED),
        (b"mainloop_demo.elf", open(pos_args[15], "rb").read(), 0x81ED),
        (b"compositor.elf", open(pos_args[16], "rb").read(), 0x81ED),
        (b"pango_demo.elf", open(pos_args[17], "rb").read(), 0x81ED),
        (b"vk_demo.elf", open(pos_args[18], "rb").read(), 0x81ED),
        (b"c2vala.elf", open(pos_args[19], "rb").read(), 0x81ED),
        (b"arith.c", open(pos_args[20], "rb").read(), 0x81A4),
        (b"frag_pattern.spv", open(pos_args[21], "rb").read(), 0x81A4),
        (b"Tahoma.ttf", open(pos_args[22], "rb").read(), 0x81A4),
        (b"Consolas-Regular.ttf", open(pos_args[23], "rb").read(), 0x81A4),
        (b"cursor.svg", open(pos_args[24], "rb").read(), 0x81A4),
        (b"pcm4.elf", open(pos_args[25], "rb").read(), 0x81ED),
        (b"mathlib.dlib", open(pos_args[26], "rb").read(), 0x81A4),
        (b"plan_demo.plan", open(pos_args[27], "rb").read(), 0x81ED),
        (b"vte_sh.elf", open(pos_args[28], "rb").read(), 0x81ED),
        (b"pluto.elf", open(pos_args[29], "rb").read(), 0x81ED),
        (b"saturn.elf", open(pos_args[30], "rb").read(), 0x81ED),
        (b"jsmn_demo.elf", open(pos_args[31], "rb").read(), 0x81ED),
        (b"c2vala_sdk.vala", open(pos_args[32], "rb").read(), 0x81A4),
        (b"sys_demo.elf", open(pos_args[33], "rb").read(), 0x81ED),
        (b"mercury.elf", open(pos_args[34], "rb").read(), 0x81ED),
        (b"curl.elf", open(pos_args[35], "rb").read(), 0x81ED),
        (b"winxp.jpg", open(pos_args[36], "rb").read(), 0x81A4),
    ]

    # `--add name=path`: extra root files (a port's binary and its data
    # files), so the launchers can put them in the image without editing
    # this list.
    for nm, ap in extra_files:
        mode = 0x81ED if nm.endswith(b".elf") else 0x81A4
        root_specs.append((nm, open(ap, "rb").read(), mode))

    stdlib_specs = []
    for p in stdlib_paths:
        stdlib_specs.append((os.path.basename(p).encode("utf-8"), open(p, "rb").read(), 0x81A4))

    cur_blk = 5
    root_entries = []
    for name, data, mode in root_specs:
        root_entries.append((name, data, cur_blk, mode))
        cur_blk += blk(data)

    stdlib_entries = []
    for name, data, mode in stdlib_specs:
        stdlib_entries.append((name, data, cur_blk, mode))
        cur_blk += blk(data)

    lib_entries = {}
    for pkg, paths in lib_groups.items():
        lst = []
        for p in paths:
            data = open(p, "rb").read()
            lst.append((os.path.basename(p).encode("utf-8"), data, cur_blk, 0x81A4))
            cur_blk += blk(data)
        lib_entries[pkg.encode("utf-8")] = lst

    INO_BLK = max(1000, cur_blk + 4)
    total_blocks = INO_BLK + 264  # 8 inode blocks (128 inodes) + 256 free data blocks (1 MiB)
    img = bytearray(total_blocks * 4096)

    struct.pack_into(">II", img, 0, 0x58465342, 4096)
    struct.pack_into(">Q", img, 8, total_blocks)
    struct.pack_into(">Q", img, 56, 64)
    struct.pack_into(">I", img, 84, total_blocks)
    struct.pack_into(">H", img, 104, 256)
    img[123] = 4
    img[124] = max(10, (total_blocks - 1).bit_length())

    root_dir_list = []
    for i, (name, data, sblk, mode) in enumerate(root_entries):
        child = INO_BLK * 16 + i
        root_dir_list.append((name, child))
        write_file_inode(img, INO_BLK * 4096 + i * 256, data, sblk, mode)

    next_ino_blk = INO_BLK + 3
    if stdlib_entries:
        stdlib_ino = next_ino_blk * 16
        root_dir_list.append((b"stdlib", stdlib_ino))
        stdlib_dir_list = []
        for i, (name, data, sblk, mode) in enumerate(stdlib_entries):
            child = (next_ino_blk + 1) * 16 + i
            stdlib_dir_list.append((name, child))
            write_file_inode(img, (next_ino_blk + 1) * 4096 + i * 256, data, sblk, mode)
        write_dir_inode(img, next_ino_blk * 4096, 0x41ED, 64, stdlib_dir_list)
        next_ino_blk += 1 + (len(stdlib_entries) + 15) // 16

    if lib_entries:
        library_ino = next_ino_blk * 16
        root_dir_list.append((b"library", library_ino))
        pkg_blk = next_ino_blk + 1
        file_blk = pkg_blk + (len(lib_entries) + 15) // 16
        library_dir_list = []
        file_idx = 0
        for pkg_idx, (pkg_name, files) in enumerate(lib_entries.items()):
            pkg_ino = pkg_blk * 16 + pkg_idx
            library_dir_list.append((pkg_name, pkg_ino))
            pkg_dir_list = []
            for fname, data, sblk, mode in files:
                f_ino = file_blk * 16 + file_idx
                pkg_dir_list.append((fname, f_ino))
                write_file_inode(img, file_blk * 4096 + file_idx * 256, data, sblk, mode)
                file_idx += 1
            write_dir_inode(img, pkg_blk * 4096 + pkg_idx * 256, 0x41ED, library_ino, pkg_dir_list)
        write_dir_inode(img, next_ino_blk * 4096, 0x41ED, 64, library_dir_list)

    write_dir_inode(img, 4 * 4096, 0x41ED, 64, root_dir_list)

    with open(image_path, "wb") as out:
        out.write(img)
    return 0


if __name__ == "__main__":
    sys.exit(main())
