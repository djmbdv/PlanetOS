#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PLANC="$ROOT/planc/build/planc"
# valac names the stage-0 binary planc.exe when built on Windows/MSYS2.
if [ ! -x "$PLANC" ] && [ -x "$PLANC.exe" ]; then
    PLANC="$PLANC.exe"
fi
OUT="/tmp/planetos-qemu"
mkdir -p "$OUT"

if [ ! -x "$PLANC" ]; then
    "$ROOT/planc/build.sh"
    if [ ! -x "$PLANC" ] && [ -x "$PLANC.exe" ]; then
        PLANC="$PLANC.exe"
    fi
fi

echo "Building PlanetOS kernel and userland..."
"$PLANC" --target=planetos "$ROOT/user/init.vala" -o "$OUT/init.elf"
"$PLANC" --target=planetos --image-base=0x900000 "$ROOT/user/worker.vala" -o "$OUT/worker.elf"
"$PLANC" --target=planetos "$ROOT/user/banner.vala" -o "$OUT/banner.elf"
"$PLANC" --target=planetos "$ROOT/stdlib/glib_compat.vala" "$ROOT/user/wc.vala" -o "$OUT/wc.elf"
"$PLANC" --target=planetos "$ROOT/stdlib/glib_compat.vala" "$ROOT/stdlib/gio_compat.vala" "$ROOT/user/gio_demo.vala" -o "$OUT/gio_demo.elf"
"$PLANC" --target=planetos "$ROOT/stdlib/cairo_gdk_compat.vala" "$ROOT/user/cairo_demo.vala" -o "$OUT/cairo_demo.elf"
"$PLANC" --target=spirv "$ROOT/user/frag_planet.vala" -o "$OUT/frag.spv"
"$PLANC" --target=planetos "$ROOT/stdlib/cairo_gdk_compat.vala" "$ROOT/user/spv_demo.vala" -o "$OUT/spv_demo.elf"
"$PLANC" --target=planetos --image-base=0xA00000 "$ROOT/stdlib/glib_compat.vala" "$ROOT/user/shell.vala" -o "$OUT/shell.elf"
"$PLANC" --target=planetos --image-base=0xC00000 \
    "$ROOT/planc/src/buffer.vala" \
    "$ROOT/planc/src/host_planetos.vala" \
    "$ROOT/planc/src/ast.vala" \
    "$ROOT/planc/src/lexer.vala" \
    "$ROOT/planc/src/parser.vala" \
    "$ROOT/planc/src/asm.vala" \
    "$ROOT/planc/src/emitter.vala" \
    "$ROOT/planc/src/elf.vala" \
    "$ROOT/planc/src/dwarf.vala" \
    "$ROOT/planc/src/spirv.vala" \
    "$ROOT/planc/src/codegen.vala" \
    "$ROOT/planc/src/main.vala" \
    -o "$OUT/planc.elf"

"$PLANC" --freestanding \
    "$ROOT/planetrt/boot_mb2.vala" \
    "$ROOT/planetrt/serial.vala" \
    "$ROOT/kernel/cpu.vala" \
    "$ROOT/kernel/vga.vala" \
    "$ROOT/kernel/fb.vala" \
    "$ROOT/kernel/pmm.vala" \
    "$ROOT/kernel/ramfs.vala" \
    "$ROOT/kernel/keyboard.vala" \
    "$ROOT/kernel/mouse.vala" \
    "$ROOT/kernel/ata.vala" \
    "$ROOT/kernel/xfs.vala" \
    "$ROOT/kernel/syscall.vala" \
    "$ROOT/kernel/elf_loader.vala" \
    "$ROOT/kernel/sched.vala" \
    "$ROOT/kernel/main.vala" \
    -o "$OUT/planet-kernel"

python3 - "$OUT/disk.img" "$OUT/init.elf" "$OUT/shell.elf" "$OUT/planc.elf" "$OUT/banner.elf" "$OUT/worker.elf" "$OUT/wc.elf" "$OUT/cairo_demo.elf" "$OUT/frag.spv" "$OUT/spv_demo.elf" "$OUT/gio_demo.elf" \
    "$ROOT/planc/tests/valid/utf8.vala" "$ROOT/planc/tests/valid/class_basic.vala" << 'PYEOF'
import struct, sys

def blk(b): return (len(b) + 4095) // 4096

init_b = open(sys.argv[2], "rb").read()
sh_b   = open(sys.argv[3], "rb").read()
pl_b   = open(sys.argv[4], "rb").read()
bn_b   = open(sys.argv[5], "rb").read()
wk_b   = open(sys.argv[6], "rb").read()
wc_b   = open(sys.argv[7], "rb").read()
cd_b   = open(sys.argv[8], "rb").read()
sp_b   = open(sys.argv[9], "rb").read()
sd_b   = open(sys.argv[10], "rb").read()
gd_b   = open(sys.argv[11], "rb").read()
t1_b   = open(sys.argv[12], "rb").read()
t2_b   = open(sys.argv[13], "rb").read()

b_hello = 5
b_init  = 6
b_shell = b_init + blk(init_b)
b_planc = b_shell + blk(sh_b)
b_ban   = b_planc + blk(pl_b)
b_wk    = b_ban + blk(bn_b)
b_wc    = b_wk + blk(wk_b)
b_cd    = b_wc + blk(wc_b)
b_sp    = b_cd + blk(cd_b)
b_sd    = b_sp + blk(sp_b)
b_gd    = b_sd + blk(sd_b)
b_t1    = b_gd + blk(gd_b)
b_t2    = b_t1 + blk(t1_b)
INO_BLK = 1000
total_blocks = max(1024, b_t2 + blk(t2_b), INO_BLK + 1)
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
# written right after the root inode core, so keeping them in block 4 would let
# it overwrite inode 65 (hello.txt) once the listing grows past a few entries.
entries = [
    (b"hello.txt",        b"xfs:hello from PlanetOS disk!\n", b_hello, 0x81A4),
    (b"init.elf",         init_b, b_init,  0x81ED),
    (b"shell.elf",        sh_b,   b_shell, 0x81ED),
    (b"planc.elf",        pl_b,   b_planc, 0x81ED),
    (b"banner.elf",       bn_b,   b_ban,   0x81ED),
    (b"worker.elf",       wk_b,   b_wk,    0x81ED),
    (b"wc.elf",           wc_b,   b_wc,    0x81ED),
    (b"cairo_demo.elf",   cd_b,   b_cd,    0x81ED),
    (b"frag.spv",         sp_b,   b_sp,    0x81A4),
    (b"spv_demo.elf",     sd_b,   b_sd,    0x81ED),
    (b"gio_demo.elf",     gd_b,   b_gd,    0x81ED),
    (b"utf8.vala",        t1_b,   b_t1,    0x81A4),
    (b"class_basic.vala", t2_b,   b_t2,    0x81A4),
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

open(sys.argv[1], "wb").write(img)
PYEOF

# --headless forces the serial-only mode; --display forces a window. Without a
# flag: window when a display server exists, headless otherwise. Windows/MSYS2
# always has one even though $DISPLAY is unset.
DISPLAY_MODE="window"
case "${1:-}" in
    --headless) DISPLAY_MODE="none" ;;
    --display)  DISPLAY_MODE="gtk" ;;
esac
if [ "$DISPLAY_MODE" = "window" ] \
    && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${MSYSTEM:-}" ]; then
    DISPLAY_MODE="none"
fi
DISP_ARGS=()
SER_ARGS=()
if [ "$DISPLAY_MODE" = "none" ]; then
    DISP_ARGS=(-display none)
    SER_ARGS=(-serial mon:stdio)
else
    # Keep the serial console out of the terminal: QEMU's stdio backend is
    # unreliable under mintty, and the guest already draws to the VGA window.
    SER_LOG="$OUT/serial.log"
    if command -v cygpath >/dev/null 2>&1; then
        SER_LOG="$(cygpath -m "$SER_LOG")"
    fi
    SER_ARGS=(-serial "file:$SER_LOG")
    echo "Serial log: $SER_LOG"
fi

echo "Booting PlanetOS in QEMU (type 'exit' in the guest shell to quit)..."
exec qemu-system-x86_64 \
    -kernel "$OUT/planet-kernel" \
    -drive file="$OUT/disk.img",format=raw,if=ide \
    -vga std \
    "${DISP_ARGS[@]}" \
    "${SER_ARGS[@]}" \
    -no-reboot \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
