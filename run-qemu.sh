#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PLANC="$ROOT/planc/build/planc"
OUT="/tmp/planetos-qemu"
mkdir -p "$OUT"

if [ ! -x "$PLANC" ]; then
    "$ROOT/planc/build.sh"
fi

echo "Building PlanetOS kernel and userland..."
"$PLANC" --target=planetos "$ROOT/user/init.vala" -o "$OUT/init.elf"
"$PLANC" --target=planetos --image-base=0xA00000 "$ROOT/user/shell.vala" -o "$OUT/shell.elf"
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
    "$ROOT/planc/src/codegen.vala" \
    "$ROOT/planc/src/main.vala" \
    -o "$OUT/planc.elf"

"$PLANC" --freestanding \
    "$ROOT/planetrt/boot_mb2.vala" \
    "$ROOT/planetrt/serial.vala" \
    "$ROOT/kernel/cpu.vala" \
    "$ROOT/kernel/vga.vala" \
    "$ROOT/kernel/pmm.vala" \
    "$ROOT/kernel/ramfs.vala" \
    "$ROOT/kernel/keyboard.vala" \
    "$ROOT/kernel/ata.vala" \
    "$ROOT/kernel/xfs.vala" \
    "$ROOT/kernel/syscall.vala" \
    "$ROOT/kernel/elf_loader.vala" \
    "$ROOT/kernel/main.vala" \
    -o "$OUT/planet-kernel"

python3 - "$OUT/disk.img" "$OUT/init.elf" "$OUT/shell.elf" "$OUT/planc.elf" \
    "$ROOT/planc/tests/valid/utf8.vala" "$ROOT/planc/tests/valid/class_basic.vala" << 'PYEOF'
import struct, sys

def blk(b): return (len(b) + 4095) // 4096

init_b = open(sys.argv[2], "rb").read()
sh_b   = open(sys.argv[3], "rb").read()
pl_b   = open(sys.argv[4], "rb").read()
t1_b   = open(sys.argv[5], "rb").read()
t2_b   = open(sys.argv[6], "rb").read()

b_hello = 5
b_init  = 6
b_shell = b_init + blk(init_b)
b_planc = b_shell + blk(sh_b)
b_t1    = b_planc + blk(pl_b)
b_t2    = b_t1 + blk(t1_b)
total_blocks = max(1024, b_t2 + blk(t2_b))
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
entries = [
    (b"hello.txt",        65, b"xfs:hello from PlanetOS disk!\n", b_hello, 0x81A4),
    (b"init.elf",         66, init_b, b_init,  0x81ED),
    (b"shell.elf",        67, sh_b,   b_shell, 0x81ED),
    (b"planc.elf",        68, pl_b,   b_planc, 0x81ED),
    (b"utf8.vala",        69, t1_b,   b_t1,    0x81A4),
    (b"class_basic.vala", 70, t2_b,   b_t2,    0x81A4),
]
img[df + 0] = len(entries)
img[df + 1] = 0
struct.pack_into(">I", img, df + 4, 64)
ent = df + 8
for name, child, data, sblk, mode in entries:
    img[ent] = len(name)
    struct.pack_into(">H", img, ent + 1, 0)
    img[ent + 3:ent + 3 + len(name)] = name
    struct.pack_into(">I", img, ent + 3 + len(name), child)
    ent = ent + 3 + len(name) + 4
    fi = r + (child - 64) * 256
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

DISP_ARGS=()
if [ "${1:-}" = "--headless" ] || { [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; }; then
    DISP_ARGS=(-display none)
fi

echo "Booting PlanetOS in QEMU (type 'exit' to quit)..."
exec qemu-system-x86_64 \
    -kernel "$OUT/planet-kernel" \
    -drive file="$OUT/disk.img",format=raw,if=ide \
    "${DISP_ARGS[@]}" \
    -serial mon:stdio \
    -no-reboot \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
