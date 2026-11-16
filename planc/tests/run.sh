#!/bin/sh
# Slice 0 test suite.
#
# Every valid case must compile, run with the expected stdout and exit status,
# and satisfy the invariants the slice exists to prove:
#   I2   the binary has no undefined symbols (it links nothing)
#   KR-03 no segment is writable and executable at the same time
# Every invalid case must be rejected with a positioned diagnostic and exit 1.
#
# Usage: ./run.sh            run the suite
#        KEEP=1 ./run.sh     keep the build directory
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PLANC=${PLANC:-$HERE/../build/planc}
WORK=${WORK:-$(mktemp -d)}
PASS=0
FAIL=0

cleanup () {
    [ "${KEEP:-0}" = "1" ] || rm -rf "$WORK"
}
trap cleanup EXIT

if [ ! -x "$PLANC" ]; then
    echo "run.sh: no planc at $PLANC (run ../build.sh)" >&2
    exit 2
fi

ok () {
    PASS=$((PASS + 1))
    echo "PASS $1"
}

ko () {
    FAIL=$((FAIL + 1))
    echo "FAIL $1: $2"
}

check_elf () {
    name=$1
    binary=$2

    if ! readelf -h "$binary" | grep -q 'Type:.*EXEC'; then
        ko "$name" "not ET_EXEC"
        return 1
    fi
    if [ "$(readelf -lW "$binary" | grep -c '^  LOAD')" != "3" ]; then
        ko "$name" "expected exactly 3 PT_LOAD segments"
        return 1
    fi
    if readelf -lW "$binary" | grep '^  LOAD' | grep -q 'RWE'; then
        ko "$name" "segment is RWX"
        return 1
    fi
    if [ -n "$(nm -u "$binary" 2>/dev/null)" ]; then
        ko "$name" "undefined symbols present"
        return 1
    fi
    return 0
}

echo "== valid =="
for src in "$HERE"/valid/*.vala; do
    name=$(basename "$src" .vala)
    binary="$WORK/$name"

    if ! "$PLANC" "$src" -o "$binary" 2>"$WORK/$name.err"; then
        ko "$name" "compile failed: $(cat "$WORK/$name.err")"
        continue
    fi

    if ! check_elf "$name" "$binary"; then
        continue
    fi

    "$binary" >"$WORK/$name.stdout" 2>&1
    actual_code=$?

    expected_code=0
    [ -f "$HERE/valid/$name.code" ] && expected_code=$(cat "$HERE/valid/$name.code")

    if [ "$actual_code" != "$expected_code" ]; then
        ko "$name" "exit $actual_code, expected $expected_code"
        continue
    fi

    if [ -f "$HERE/valid/$name.out" ]; then
        if ! cmp -s "$WORK/$name.stdout" "$HERE/valid/$name.out"; then
            ko "$name" "stdout differs from $name.out"
            continue
        fi
    elif [ -s "$WORK/$name.stdout" ]; then
        ko "$name" "expected no output"
        continue
    fi

    ok "$name"
done

echo "== invalid =="
for src in "$HERE"/invalid/*.vala; do
    name=$(basename "$src" .vala)
    binary="$WORK/reject_$name"

    "$PLANC" "$src" -o "$binary" 2>"$WORK/$name.err"
    code=$?

    if [ "$code" != "1" ]; then
        ko "$name" "exit $code, expected 1"
        continue
    fi
    if [ -e "$binary" ]; then
        ko "$name" "wrote an output file for a rejected program"
        continue
    fi
    if ! grep -q '^planc: ' "$WORK/$name.err"; then
        ko "$name" "diagnostic does not start with 'planc: '"
        continue
    fi
    # Every diagnostic must carry a position, except whole-program ones.
    case $name in
        no_main) ;;
        *)
            if ! grep -qE '[0-9]+:[0-9]+' "$WORK/$name.err"; then
                ko "$name" "diagnostic has no line:column"
                continue
            fi
            ;;
    esac

    ok "$name"
done

echo "== bounds =="
for src in "$HERE"/bounds/*.vala; do
    name=$(basename "$src" .vala)
    binary="$WORK/bounds_$name"

    if ! "$PLANC" "$src" -o "$binary" 2>"$WORK/$name.err"; then
        ko "$name" "compile failed: $(cat "$WORK/$name.err")"
        continue
    fi
    if ! check_elf "$name" "$binary"; then
        continue
    fi

    "$binary" >"$WORK/$name.stdout" 2>"$WORK/$name.runerr"
    code=$?
    if [ "$code" != "134" ]; then
        ko "$name" "exit $code, expected 134"
        continue
    fi
    if ! grep -q '^planc: panic: index out of bounds$' "$WORK/$name.runerr"; then
        ko "$name" "missing panic diagnostic on stderr"
        continue
    fi
    ok "$name"
done

if [ -f "$HERE/valid/string_index.vala" ]; then
    nb_bin="$WORK/string_index_nobc"
    if ! "$PLANC" --no-bounds-check "$HERE/valid/string_index.vala" -o "$nb_bin" 2>"$WORK/nobc.err"; then
        ko "no_bounds_check" "compile failed: $(cat "$WORK/nobc.err")"
    elif ! check_elf "no_bounds_check" "$nb_bin"; then
        :
    elif nm "$nb_bin" | grep -q '__planc_bounds_panic'; then
        ko "no_bounds_check" "__planc_bounds_panic still emitted"
    else
        "$nb_bin" >"$WORK/nobc.stdout" 2>&1
        code=$?
        expected_code=$(cat "$HERE/valid/string_index.code")
        if [ "$code" != "$expected_code" ]; then
            ko "no_bounds_check" "exit $code, expected $expected_code"
        elif ! cmp -s "$WORK/nobc.stdout" "$HERE/valid/string_index.out"; then
            ko "no_bounds_check" "stdout differs"
        else
            ok "no_bounds_check"
        fi
    fi
fi

echo "== check_leaks =="
for base_name in array_int array_string string_concat template_value refcount_loop class_basic class_inheritance class_dtor_arc nullable_narrowing; do
    src="$HERE/valid/$base_name.vala"
    bin="$WORK/leaks_$base_name"
    case_name="check_leaks_$base_name"

    if ! "$PLANC" --check-leaks "$src" -o "$bin" 2>"$WORK/$case_name.err"; then
        ko "$case_name" "compile failed: $(cat "$WORK/$case_name.err")"
        continue
    fi
    if ! check_elf "$case_name" "$bin"; then
        continue
    fi

    "$bin" >"$WORK/$case_name.stdout" 2>"$WORK/$case_name.runerr"
    code=$?
    expected_code=0
    [ -f "$HERE/valid/$base_name.code" ] && expected_code=$(cat "$HERE/valid/$base_name.code")

    if [ "$code" != "$expected_code" ]; then
        ko "$case_name" "exit $code, expected $expected_code ($(cat "$WORK/$case_name.runerr"))"
        continue
    fi

    if [ -f "$HERE/valid/$base_name.out" ]; then
        if ! cmp -s "$WORK/$case_name.stdout" "$HERE/valid/$base_name.out"; then
            ko "$case_name" "stdout differs from $base_name.out"
            continue
        fi
    elif [ -s "$WORK/$case_name.stdout" ]; then
        ko "$case_name" "expected no output"
        continue
    fi

    if [ -s "$WORK/$case_name.runerr" ]; then
        ko "$case_name" "unexpected stderr: $(cat "$WORK/$case_name.runerr")"
        continue
    fi

    ok "$case_name"
done

echo "== null_and_cast =="
cat >"$WORK/null_deref.vala" <<'EOF'
class Box {
    public int x;
}
int main() {
    Box? b = null;
    return b.x;
}
EOF
if ! "$PLANC" "$WORK/null_deref.vala" -o "$WORK/null_deref" 2>"$WORK/null_deref.err"; then
    ko "null_deref_panic" "compile failed: $(cat "$WORK/null_deref.err")"
elif ! check_elf "null_deref_panic" "$WORK/null_deref"; then
    :
else
    "$WORK/null_deref" >"$WORK/null_deref.stdout" 2>"$WORK/null_deref.runerr"
    code=$?
    if [ "$code" != "134" ]; then
        ko "null_deref_panic" "exit $code, expected 134"
    elif ! grep -q '^planc: panic: null pointer dereference$' "$WORK/null_deref.runerr"; then
        ko "null_deref_panic" "missing panic diagnostic: $(cat "$WORK/null_deref.runerr")"
    else
        ok "null_deref_panic"
    fi
fi

if ! "$PLANC" --no-null-check "$WORK/null_deref.vala" -o "$WORK/null_deref_nnc" 2>"$WORK/nnc.err"; then
    ko "no_null_check" "compile failed: $(cat "$WORK/nnc.err")"
elif ! check_elf "no_null_check" "$WORK/null_deref_nnc"; then
    :
elif nm "$WORK/null_deref_nnc" | grep -q '__planc_null_panic'; then
    ko "no_null_check" "__planc_null_panic still emitted"
else
    ok "no_null_check"
fi

cat >"$WORK/bad_cast.vala" <<'EOF'
abstract class Base {
    public abstract int kind();
}
class A : Base {
    public override int kind() { return 1; }
}
class B : Base {
    public override int kind() { return 2; }
}
int main() {
    Base x = new A();
    B b = (B) x;
    return b.kind();
}
EOF
if ! "$PLANC" "$WORK/bad_cast.vala" -o "$WORK/bad_cast" 2>"$WORK/bad_cast.err"; then
    ko "bad_cast_panic" "compile failed: $(cat "$WORK/bad_cast.err")"
elif ! check_elf "bad_cast_panic" "$WORK/bad_cast"; then
    :
else
    "$WORK/bad_cast" >"$WORK/bad_cast.stdout" 2>"$WORK/bad_cast.runerr"
    code=$?
    if [ "$code" != "134" ]; then
        ko "bad_cast_panic" "exit $code, expected 134"
    elif ! grep -q '^planc: panic: invalid class cast$' "$WORK/bad_cast.runerr"; then
        ko "bad_cast_panic" "missing panic diagnostic: $(cat "$WORK/bad_cast.runerr")"
    else
        ok "bad_cast_panic"
    fi
fi

echo
echo "SUMMARY: $((PASS + FAIL)) cases, $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
