#!/bin/sh
# Builds planc. Bootstrap stage 0: valac compiles it, and valac is only needed
# for development. The binary planc produces depends on nothing.
set -eu
. "$(cd "$(dirname "$0")/../experiments/oracle" && pwd)/env.sh"

HERE=$(cd "$(dirname "$0")" && pwd)
OUT="${1:-$HERE/build/planc}"
mkdir -p "$(dirname "$OUT")"

# Intermediate .vala.c files land next to the sources; drop them afterwards so
# the tree stays clean.
valac \
    --pkg=glib-2.0 \
    --target-glib=2.56 \
    -X -Wall -X -Wextra \
    "$HERE"/src/buffer.vala \
    "$HERE"/src/lexer.vala \
    "$HERE"/src/ast.vala \
    "$HERE"/src/parser.vala \
    "$HERE"/src/emitter.vala \
    "$HERE"/src/asm.vala \
    "$HERE"/src/elf.vala \
    "$HERE"/src/codegen.vala \
    "$HERE"/src/main.vala \
    "$HERE"/stage0/host_stage0.vala \
    -o "$OUT"
rm -f "$HERE"/src/*.vala.c "$HERE"/stage0/*.vala.c

echo "built: $OUT"
