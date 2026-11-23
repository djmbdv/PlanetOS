#!/bin/sh
# Build c2vala for the *host* (Windows .exe / Linux .so) with valac.
#
# tools/c2vala/build.sh builds the same sources with planc for the guest, which
# emits ELF; that binary cannot run on Windows. This build swaps the two host
# primitives (Planc.Host and Planc.StrBuilder) for GLib implementations and
# leaves every other file untouched, so the translator can be tested natively.
#
# Needs MSYS2 (valac + glib-2.0), not QEMU.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT="${1:-$HERE/build/c2vala.exe}"

mkdir -p "$(dirname "$OUT")"

valac --pkg=glib-2.0 -o "$OUT" \
    "$HERE/host_glib.vala" \
    "$HERE/ast.vala" \
    "$HERE/preproc.vala" \
    "$HERE/lexer.vala" \
    "$HERE/parser.vala" \
    "$HERE/ptr_analyzer.vala" \
    "$HERE/translator.vala" \
    "$HERE/main.vala"

echo "built: $OUT"
