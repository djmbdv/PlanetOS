#!/bin/sh
# 3-stage self-hosting bootstrap verification for planc (TC-05, TC-09):
#   Stage 0 (valac)   -> planc1
#   Stage 1 (planc1)  -> planc2 (native static ELF64, no libc/GLib)
#   Stage 2 (planc2)  -> planc3
#   Fixed point check -> sha256(planc2) == sha256(planc3)
#   Full regression   -> PLANC=planc2 ./tests/run.sh
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$(mktemp -d)}

cleanup () {
    [ "${KEEP:-0}" = "1" ] || rm -rf "$WORK"
}
trap cleanup EXIT

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
$HERE/src/elem_layout.plan $HERE/src/effects.plan $HERE/src/puzzle_ra.vala
$HERE/src/codegen.vala
$HERE/src/main.vala
$HERE/src/host_native.vala
"

echo "== stage 1: building planc1 via valac =="
"$HERE/build.sh" "$WORK/planc1"

echo "== stage 2: building planc2 via planc1 =="
"$WORK/planc1" $SRCS -o "$WORK/planc2"

echo "== checking planc2 ELF invariants =="
readelf -h "$WORK/planc2" | grep -q 'Type:.*EXEC' || { echo "FAIL: planc2 not ET_EXEC" >&2; exit 1; }
load_cnt=$(readelf -lW "$WORK/planc2" | grep -c '^  LOAD')
[ "$load_cnt" = "3" ] || { echo "FAIL: planc2 expected 3 PT_LOAD segments, got $load_cnt" >&2; exit 1; }
if readelf -lW "$WORK/planc2" | grep '^  LOAD' | grep -q 'RWE'; then
    echo "FAIL: planc2 has RWX segment" >&2
    exit 1
fi
if [ -n "$(nm -u "$WORK/planc2" 2>/dev/null)" ]; then
    echo "FAIL: planc2 has undefined external symbols" >&2
    exit 1
fi

echo "== stage 3: building planc3 via planc2 =="
"$WORK/planc2" $SRCS -o "$WORK/planc3"

h2=$(sha256sum "$WORK/planc2" | awk '{print $1}')
h3=$(sha256sum "$WORK/planc3" | awk '{print $1}')
s2=$(stat -c%s "$WORK/planc2")
s3=$(stat -c%s "$WORK/planc3")
echo "planc2: $h2 ($s2 bytes)"
echo "planc3: $h3 ($s3 bytes)"
readelf -lW "$WORK/planc2"

if [ "$h2" != "$h3" ]; then
    echo "FAIL: bootstrap mismatch between planc2 and planc3!" >&2
    exit 1
fi
echo "PASS fixed-point bootstrap: sha256(planc2) == sha256(planc3)"

echo "== stage 4: running full test suite with planc2 =="
PLANC="$WORK/planc2" "$HERE/tests/run.sh"
