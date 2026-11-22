#!/bin/sh
# Rebuild the stage-0 planc with the MSYS2 UCRT64 valac (host toolchain).
set -eu
export PATH=/ucrt64/bin:/usr/bin:$PATH
cd "$(dirname "$0")/../planc"
valac --pkg=glib-2.0 --target-glib=2.56 -X -Wall \
    src/buffer.vala src/diag.vala src/preproc.vala src/lexer.vala src/ast.vala src/parser.vala \
    src/emitter.vala src/asm.vala src/dwarf.vala src/elf.vala \
    src/spirv.vala src/opt.vala src/codegen.vala src/main.vala stage0/host_stage0.vala \
    -o build/planc.exe
rm -f src/*.vala.c stage0/*.vala.c
echo "planc rebuilt: $(ls -l build/planc.exe)"
