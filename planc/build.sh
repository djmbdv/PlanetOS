#!/bin/sh
# Builds planc. Bootstrap stage 0: valac compiles it, and valac is only needed
# for development. The binary planc produces depends on nothing.
set -eu
. "$(cd "$(dirname "$0")/../experiments/oracle" && pwd)/env.sh"

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT="${1:-$HERE/build/planc}"
mkdir -p "$(dirname "$OUT")"

PLAN2VALA="$ROOT/tools/plan2vala/build/plan2vala.exe"
STAGE0_RT="$ROOT/tools/plan2vala/plan_stage0_rt.vala"

SRCS="
$HERE/src/buffer.vala
$HERE/src/diag.vala
$HERE/src/preproc.vala
$HERE/src/lexer.vala
$HERE/src/ast.vala
$HERE/src/parser.vala
$HERE/src/emitter.vala
$HERE/src/asm.vala
$HERE/src/dwarf.plan
$HERE/src/elf.vala
$HERE/src/spirv.vala
$HERE/src/opt.vala
$HERE/src/pe.plan
$HERE/src/elem_layout.plan
$HERE/src/effects.plan
$HERE/src/puzzle_ra.vala
$HERE/src/codegen.vala
$HERE/src/main.vala
$HERE/stage0/host_stage0.vala
"

STAGE0_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE0_DIR" "$HERE"/src/*.vala.c "$HERE"/stage0/*.vala.c' EXIT

VALA_SRCS=""
HAS_PLAN=0
for s in $SRCS; do
    case "$s" in
        *.plan)
            if [ "$HAS_PLAN" = "0" ]; then
                if [ ! -x "$PLAN2VALA" ] || [ "$ROOT/tools/plan2vala/translator.vala" -nt "$PLAN2VALA" ]; then
                    sh "$ROOT/tools/plan2vala/build.sh" "$PLAN2VALA" >/dev/null
                fi
                VALA_SRCS="$VALA_SRCS $STAGE0_RT"
                HAS_PLAN=1
            fi
            base=$(basename "$s" .plan)
            out_s="$STAGE0_DIR/$base.stage0.vala"
            "$PLAN2VALA" "$s" -o "$out_s"
            VALA_SRCS="$VALA_SRCS $out_s"
            ;;
        *)
            VALA_SRCS="$VALA_SRCS $s"
            ;;
    esac
done

valac \
    --pkg=glib-2.0 \
    --target-glib=2.56 \
    -X -O2 -X -Wall -X -Wextra \
    $VALA_SRCS \
    -o "$OUT"

echo "built: $OUT"
