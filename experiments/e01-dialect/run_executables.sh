#!/bin/sh
# Compiles and runs the cases with observable output, on the host.
set -u
. "$(cd "$(dirname "$0")/../oracle" && pwd)/env.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
for f in "$HERE"/cases/*.vala; do
    n=$(basename "$f" .vala)
    case "$n" in
        15_constructors|15b_constructors|17_errordomain|19_*|20_*|06_*|09_*|10*|11_*|13_*|34_*) continue ;;
    esac
    if ! valac "$f" -o "$WORK/$n" >"$WORK/$n.build" 2>&1; then
        printf '=== %s === (does not compile)\n' "$n"; continue
    fi
    printf '=== %s ===\n' "$n"
    "$WORK/$n" 2>&1 | head -12
    echo
done
