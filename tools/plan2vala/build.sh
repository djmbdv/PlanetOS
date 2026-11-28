#!/bin/sh
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT="${1:-$HERE/build/plan2vala.exe}"
mkdir -p "$(dirname "$OUT")"

valac \
    --pkg=glib-2.0 \
    --target-glib=2.56 \
    -X -O2 \
    "$ROOT/planc/src/buffer.vala" \
    "$ROOT/planc/src/diag.vala" \
    "$ROOT/planc/src/preproc.vala" \
    "$ROOT/planc/src/lexer.vala" \
    "$ROOT/planc/stage0/host_stage0.vala" \
    "$HERE/translator.vala" \
    "$HERE/main.vala" \
    -o "$OUT"

echo "built: $OUT"
