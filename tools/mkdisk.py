#!/usr/bin/env python3
"""Builds the PlanetOS boot disk (raw XFS image) from the compiled artifacts.

Usage:
    mkdisk.py <disk.img> <init.elf> <shell.elf> <planc.elf> <banner.elf>
              <worker.elf> <wc.elf> <cairo_demo.elf> <frag.spv> <spv_demo.elf>
              <gio_demo.elf> <utf8.vala> <class_basic.vala>
              <gobject_demo.elf> <gmodule_demo.elf> <mainloop_demo.elf> <compositor.elf> <pango_demo.elf> <jsmn_demo.elf> <c2vala.elf> <arith.c> <frag_pattern.spv>

Shared by run-qemu.sh and run-qemu.ps1 so both launchers produce the same
image layout.
"""

import struct
import sys

ARG_COUNT = 26  # image + 25 files


def blk(b):
    return (len(b) + 4095) // 4096


def main():
    if len(sys.argv) != ARG_COUNT:
        sys.stderr.write("mkdisk.py: expected %d arguments, got %d\n" % (ARG_COUNT, len(sys.argv)))
        return 2

    image_path = sys.argv[1]
    init_b = open(sys.argv[2], "rb").read()
    sh_b = open(sys.argv[3], "rb").read()
    pl_b = open(sys.argv[4], "rb").read()
    bn_b = open(sys.argv[5], "rb").read()
    wk_b = open(sys.argv[6], "rb").read()
    wc_b = open(sys.argv[7], "rb").read()
    cd_b = open(sys.argv[8], "rb").read()
    sp_b = open(sys.argv[9], "rb").read()
    sd_b = open(sys.argv[10], "rb").read()
    gd_b = open(sys.argv[11], "rb").read()
    t1_b = open(sys.argv[12], "rb").read()
    t2_b = open(sys.argv[13], "rb").read()
    go_b = open(sys.argv[14], "rb").read()
    gm_b = open(sys.argv[15], "rb").read()
    ml_b = open(sys.argv[16], "rb").read()
    cp_b = open(sys.argv[17], "rb").read()
    pg_b = open(sys.argv[18], "rb").read()
    jm_b = open(sys.argv[19], "rb").read()
    c2_b = open(sys.argv[20], "rb").read()
    ac_b = open(sys.argv[21], "rb").read()
    fp_b = open(sys.argv[22], "rb").read()
    gt_b = open(sys.argv[23], "rb").read()
    vk_b = open(sys.argv[24], "rb").read()
    ttf_b = open(sys.argv[25], "rb").read()

    b_hello = 5
    b_init = 6
    b_shell = b_init + blk(init_b)
    b_planc = b_shell + blk(sh_b)
    b_ban = b_planc + blk(pl_b)
    b_wk = b_ban + blk(bn_b)
    b_wc = b_wk + blk(wk_b)
    b_cd = b_wc + blk(wc_b)
    b_sp = b_cd + blk(cd_b)
    b_sd = b_sp + blk(sp_b)
    b_gd = b_sd + blk(sd_b)
    b_t1 = b_gd + blk(gd_b)
    b_t2 = b_t1 + blk(t1_b)
    b_go = b_t2 + blk(t2_b)
    b_gm = b_go + blk(go_b)
    b_ml = b_gm + blk(gm_b)
    b_cp = b_ml + blk(ml_b)
    b_pg = b_cp + blk(cp_b)
    b_jm = b_pg + blk(pg_b)
    b_c2 = b_jm + blk(jm_b)
    b_ac = b_c2 + blk(c2_b)
    b_fp = b_ac + blk(ac_b)
    b_gt = b_fp + blk(fp_b)
    b_vk = b_gt + blk(gt_b)
    b_ttf = b_vk + blk(vk_b)
    INO_BLK = max(1000, b_ttf + blk(ttf_b) + 4)
    total_blocks = max(1024, INO_BLK + 4)
    img = bytearray(total_blocks * 4096)

    struct.pack_into(">II", img, 0, 0x58465342, 4096)
    struct.pack_into(">Q", img, 56, 64)
    struct.pack_into(">I", img, 84, total_blocks)
    struct.pack_into(">H", img, 104, 256)
    img[123] = 4
    img[124] = 10

    r = 4 * 4096
    struct.pack_into(">HH", img, r, 0x494E, 0x41ED)
    img[r + 4] = 2
    img[r + 5] = 1
    df = r + 100
    # Child inodes get a block of their own: the shortform directory payload is
    # written right after the root inode core, so keeping them in block 4 would
    # let it overwrite inode 65 (hello.txt) once the listing grows past a few
    # entries.
    entries = [
        (b"hello.txt", b"xfs:hello from PlanetOS disk!\n", b_hello, 0x81A4),
        (b"init.elf", init_b, b_init, 0x81ED),
        (b"shell.elf", sh_b, b_shell, 0x81ED),
        (b"planc.elf", pl_b, b_planc, 0x81ED),
        (b"banner.elf", bn_b, b_ban, 0x81ED),
        (b"worker.elf", wk_b, b_wk, 0x81ED),
        (b"wc.elf", wc_b, b_wc, 0x81ED),
        (b"cairo_demo.elf", cd_b, b_cd, 0x81ED),
        (b"frag.spv", sp_b, b_sp, 0x81A4),
        (b"spv_demo.elf", sd_b, b_sd, 0x81ED),
        (b"gio_demo.elf", gd_b, b_gd, 0x81ED),
        (b"utf8.vala", t1_b, b_t1, 0x81A4),
        (b"class_basic.vala", t2_b, b_t2, 0x81A4),
        (b"gobject_demo.elf", go_b, b_go, 0x81ED),
        (b"gmodule_demo.elf", gm_b, b_gm, 0x81ED),
        (b"mainloop_demo.elf", ml_b, b_ml, 0x81ED),
        (b"compositor.elf", cp_b, b_cp, 0x81ED),
        (b"pango_demo.elf", pg_b, b_pg, 0x81ED),
        (b"jsmn_demo.elf", jm_b, b_jm, 0x81ED),
        (b"c2vala.elf", c2_b, b_c2, 0x81ED),
        (b"arith.c", ac_b, b_ac, 0x81A4),
        (b"frag_pattern.spv", fp_b, b_fp, 0x81A4),
        (b"gtk_demo.elf", gt_b, b_gt, 0x81ED),
        (b"vk_demo.elf", vk_b, b_vk, 0x81ED),
        (b"Ubuntu-Regular.ttf", ttf_b, b_ttf, 0x81A4),
    ]
    img[df + 0] = len(entries)
    img[df + 1] = 0
    struct.pack_into(">I", img, df + 4, 64)
    ent = df + 8
    for i, (name, data, sblk, mode) in enumerate(entries):
        child = INO_BLK * 16 + i
        img[ent] = len(name)
        struct.pack_into(">H", img, ent + 1, 0)
        img[ent + 3:ent + 3 + len(name)] = name
        struct.pack_into(">I", img, ent + 3 + len(name), child)
        ent = ent + 3 + len(name) + 4
        fi = INO_BLK * 4096 + i * 256
        struct.pack_into(">HH", img, fi, 0x494E, mode)
        img[fi + 4] = 2
        img[fi + 5] = 2
        struct.pack_into(">Q", img, fi + 56, len(data))
        struct.pack_into(">I", img, fi + 76, 1)
        bc = blk(data)
        struct.pack_into(">QQ", img, fi + 100, 0, (sblk << 21) | bc)
        img[sblk * 4096:sblk * 4096 + len(data)] = data

    with open(image_path, "wb") as out:
        out.write(img)
    return 0


if __name__ == "__main__":
    sys.exit(main())
