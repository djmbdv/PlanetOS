#!/bin/sh
# E-01: which constructs valac 0.56 actually accepts.
# Compiles every case with -C (frontend and semantic analysis only) and records
# the result.
set -u
. "$(cd "$(dirname "$0")/../oracle" && pwd)/env.sh"
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
TOTAL=0; PASSED=0; REJECTED=0
printf '%-34s %-7s %s\n' "CASE" "VALAC" "NOTE"
for f in "$HERE"/cases/*.vala; do
    n=$(basename "$f" .vala)
    TOTAL=$((TOTAL + 1))
    if err=$(valac -C --directory="$OUT" "$f" 2>&1); then
        PASSED=$((PASSED + 1)); printf '%-34s %-7s %s\n' "$n" "OK" ""
    else
        REJECTED=$((REJECTED + 1)); printf '%-34s %-7s %s\n' "$n" "REJECT" "$(printf '%s' "$err" | head -1)"
    fi
done
echo "SUMMARY: $TOTAL cases, $PASSED accepted, $REJECTED rejected"
echo "--- generated C in: $OUT"
