#!/bin/sh
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PLANC="${PLANC:-$ROOT/planc/build/planc}"
OUT="${1:-$HERE/build/c2vala}"

mkdir -p "$(dirname "$OUT")"

"$PLANC" \
    "$ROOT/planc/src/buffer.vala" \
    "$ROOT/planc/src/host_native.vala" \
    "$HERE/ast.vala" \
    "$HERE/preproc.vala" \
    "$HERE/lexer.vala" \
    "$HERE/parser.vala" \
    "$HERE/ptr_analyzer.vala" \
    "$HERE/translator.vala" \
    "$HERE/main.vala" \
    -o "$OUT"

echo "built: $OUT"
