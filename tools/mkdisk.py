#!/usr/bin/env python3
"""Builds the PlanetOS boot disk (raw XFS image) from the compiled artifacts.

Usage:
    mkdisk.py <disk.img> <init.elf> <shell.elf> <planc.elf> <banner.elf>
              <worker.elf> <wc.elf> <cairo_demo.elf> <frag.spv> <spv_demo.elf>
              <gio_demo.elf> <utf8.vala> <class_basic.vala>
              <gobject_demo.elf> <gmodule_demo.elf> <mainloop_demo.elf> <compositor.elf> <pango_demo.elf> <jsmn_demo.elf> <c2vala.elf> <arith.c> <frag_pattern.spv>
              <gtk_demo.elf> <vk_demo.elf> <LiberationSans-Regular.ttf> <LiberationMono-Regular.ttf> <cursor.svg>
              <glib.dlib> <c2vala_sdk.vala> <sys_demo.elf>

Shared by run-qemu.sh and run-qemu.ps1 so both launchers produce the same
image layout. `c2vala_sdk.vala` is the concatenated SDK prelude built by
tools/make_sdk.py; in-guest translates of C code compile against it.
"""

import struct
import sys

ARG_COUNT = 37  # image + 36 files


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
    vk_b = open(sys.argv[19], "rb").read()
    c2_b = open(sys.argv[20], "rb").read()
    ac_b = open(sys.argv[21], "rb").read()
    fp_b = open(sys.argv[22], "rb").read()
    lsans_b = open(sys.argv[23], "rb").read()
    lmono_b = open(sys.argv[24], "rb").read()
    cur_b = open(sys.argv[25], "rb").read()
    pm_b = open(sys.argv[26], "rb").read()
    dl_b = open(sys.argv[27], "rb").read()
    pd_b = open(sys.argv[28], "rb").read()
    vsh_b = open(sys.argv[29], "rb").read()
    plu_b = open(sys.argv[30], "rb").read()
    sat_b = open(sys.argv[31], "rb").read()
    jm_b = open(sys.argv[32], "rb").read()
    gl_b = open(sys.argv[33], "rb").read()
    sdk_b = open(sys.argv[34], "rb").read()
    sysd_b = open(sys.argv[35], "rb").read()
    pango_b = open(sys.argv[36], "rb").read()

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
    b_vk = b_pg + blk(pg_b)
    b_c2 = b_vk + blk(vk_b)
    b_ac = b_c2 + blk(c2_b)
    b_fp = b_ac + blk(ac_b)
    b_lsans = b_fp + blk(fp_b)
    b_lmono = b_lsans + blk(lsans_b)
    b_cur = b_lmono + blk(lmono_b)
    b_pm = b_cur + blk(cur_b)
    b_dl = b_pm + blk(pm_b)
    b_pd = b_dl + blk(dl_b)
    b_vsh = b_pd + blk(pd_b)
    b_plu = b_vsh + blk(vsh_b)
    b_sat = b_plu + blk(plu_b)
    b_jm = b_sat + blk(sat_b)
    b_gl = b_jm + blk(jm_b)
    b_sdk = b_gl + blk(gl_b)
    b_sysd = b_sdk + blk(sdk_b)
    b_pango = b_sysd + blk(sysd_b)
    INO_BLK = max(1000, b_pango + blk(pango_b) + 4)
    total_blocks = INO_BLK + 264 # 8 inode blocks (128 inodes) + 256 free data blocks (1 MiB)
    img = bytearray(total_blocks * 4096)

    struct.pack_into(">II", img, 0, 0x58465342, 4096)
    struct.pack_into(">Q", img, 8, total_blocks)
    struct.pack_into(">Q", img, 56, 64)
    struct.pack_into(">I", img, 84, total_blocks)
    struct.pack_into(">H", img, 104, 256)
    img[123] = 4
    img[124] = max(10, (total_blocks - 1).bit_length())

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
        (b"vk_demo.elf", vk_b, b_vk, 0x81ED),
        (b"c2vala.elf", c2_b, b_c2, 0x81ED),
        (b"arith.c", ac_b, b_ac, 0x81A4),
        (b"frag_pattern.spv", fp_b, b_fp, 0x81A4),
        (b"LiberationSans-Regular.ttf", lsans_b, b_lsans, 0x81A4),
        (b"LiberationMono-Regular.ttf", lmono_b, b_lmono, 0x81A4),
        (b"cursor.svg", cur_b, b_cur, 0x81A4),
        (b"pcm4.elf", pm_b, b_pm, 0x81ED),
        (b"mathlib.dlib", dl_b, b_dl, 0x81A4),
        (b"plan_demo.plan", pd_b, b_pd, 0x81ED),
        (b"vte_sh.elf", vsh_b, b_vsh, 0x81ED),
        (b"pluto.elf", plu_b, b_plu, 0x81ED),
        (b"saturn.elf", sat_b, b_sat, 0x81ED),
        (b"jsmn_demo.elf", jm_b, b_jm, 0x81ED),
        (b"glib.dlib", gl_b, b_gl, 0x81A4),
        (b"c2vala_sdk.vala", sdk_b, b_sdk, 0x81A4),
        (b"sys_demo.elf", sysd_b, b_sysd, 0x81ED),
        (b"pango.dlib", pango_b, b_pango, 0x81A4),
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
