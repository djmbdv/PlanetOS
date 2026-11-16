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
for base_name in array_int array_string string_concat template_value refcount_loop class_basic class_inheritance class_dtor_arc nullable_narrowing foreach_array switch_stmt ternary_coalesce string_slice_literals error_handling properties_and_initializers out_ref_params namespaces_and_forward_types generics_and_array interfaces delegates_and_lambdas named_ctors_defaults_args byte_arrays_and_stdlib float_double asm_body async_goroutines signals channels_and_mutex; do
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

echo "== multifile =="
cat >"$WORK/multi_a.vala" <<'EOF'
using Models;

void describe(User u, out string summary) {
    summary = @"$(u.name):$(u.level)";
}

int main() {
    try {
        var u = new User("alice") { level = 7 };
        string s = "";
        describe(u, out s);
        print(@"$s\n");
        var bad = new User("");
        return bad.level;
    } catch (AuthError e) {
        print(@"auth:$(e.message)\n");
    }
    return 0;
}
EOF
cat >"$WORK/multi_b.vala" <<'EOF'
namespace Models {
    public errordomain AuthError {
        EMPTY_NAME
    }

    public class User {
        public string name { get; set; default = "anon"; }
        public int level { get; set; default = 1; }

        public User(string name) throws AuthError {
            if (name.length == 0) {
                throw new AuthError.EMPTY_NAME("empty user");
            }
            this.name = name;
        }
    }
}
EOF
if ! "$PLANC" --check-leaks "$WORK/multi_a.vala" "$WORK/multi_b.vala" -o "$WORK/multifile_bin" 2>"$WORK/multifile.err"; then
    ko "multifile" "compile failed: $(cat "$WORK/multifile.err")"
elif ! check_elf "multifile" "$WORK/multifile_bin"; then
    :
else
    "$WORK/multifile_bin" >"$WORK/multifile.stdout" 2>"$WORK/multifile.runerr"
    code=$?
    printf 'alice:7\nauth:empty user\n' >"$WORK/multifile.expected"
    if [ "$code" != "0" ]; then
        ko "multifile" "exit $code, expected 0 ($(cat "$WORK/multifile.runerr"))"
    elif ! cmp -s "$WORK/multifile.stdout" "$WORK/multifile.expected"; then
        ko "multifile" "unexpected stdout: $(cat "$WORK/multifile.stdout")"
    else
        ok "multifile"
    fi
fi

echo "== dwarf =="
if command -v readelf >/dev/null 2>&1; then
    dw_bin="$WORK/dwarf_rec"
    if ! "$PLANC" "$HERE/valid/recursion.vala" -o "$dw_bin" 2>"$WORK/dw.err"; then
        ko "dwarf_info" "compile failed: $(cat "$WORK/dw.err")"
    elif ! readelf --debug-dump=decodedline "$dw_bin" 2>/dev/null | grep -q "recursion.vala" \
         || ! readelf --debug-dump=info "$dw_bin" 2>/dev/null | grep -q "DW_TAG_subprogram"; then
        ko "dwarf_info" "missing DWARF line/subprogram entries"
    else
        ok "dwarf_info"
    fi
fi

echo "== freestanding_qemu =="
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    ROOT=$(cd "$HERE/../.." && pwd)
    k_bin="$WORK/planet-kernel"
    k_ser="$WORK/qemu_serial.log"
    k_disk="$WORK/planet_disk.img"
    python3 - "$k_disk" << 'PYEOF'
import struct, sys
img = bytearray(65536)
# XFS v4 superblock at block 0 (offset 0)
struct.pack_into(">II", img, 0, 0x58465342, 4096) # magic "XFSB", blocksize=4096
struct.pack_into(">Q", img, 56, 64)               # rootino = 64 (block 4, index 0)
struct.pack_into(">I", img, 84, 16)               # agblocks = 16
struct.pack_into(">H", img, 104, 256)             # inodesize = 256
img[123] = 4                                      # inopblog = 4 (16 inodes/block)
img[124] = 4                                      # agblklog = 4

# Inode 64 (root dir, shortform) at block 4 (offset 16384)
r = 4 * 4096
struct.pack_into(">HH", img, r, 0x494E, 0x41ED)   # magic "IN", mode dir
img[r + 4] = 2                                    # version 2
img[r + 5] = 1                                    # format = 1 (local/shortform)
df = r + 100
img[df + 0] = 1                                   # count = 1
img[df + 1] = 0                                   # i8count = 0
struct.pack_into(">I", img, df + 4, 64)           # parent ino = 64
ent = df + 8
name = b"hello.txt"
img[ent] = len(name)
struct.pack_into(">H", img, ent + 1, 0)
img[ent + 3:ent + 3 + len(name)] = name
struct.pack_into(">I", img, ent + 3 + len(name), 65) # child ino = 65

# Inode 65 (hello.txt, extent in block 5) at block 4 + 256
f = r + 256
payload = b"xfs:hello from PlanetOS disk!\n"
struct.pack_into(">HH", img, f, 0x494E, 0x81A4)   # magic "IN", mode file
img[f + 4] = 2                                    # version 2
img[f + 5] = 2                                    # format = 2 (extents)
struct.pack_into(">Q", img, f + 56, len(payload)) # di_size
struct.pack_into(">I", img, f + 76, 1)            # di_nextents = 1
# bmbt_rec: startblock = 5, blockcount = 1 -> w0 = 0, w1 = (5 << 21) | 1
struct.pack_into(">QQ", img, f + 100, 0, (5 << 21) | 1)

# Block 5 (offset 20480): file data
img[5 * 4096:5 * 4096 + len(payload)] = payload
open(sys.argv[1], "wb").write(img)
PYEOF
    if ! "$PLANC" --freestanding "$ROOT/planetrt/boot_mb2.vala" "$ROOT/planetrt/serial.vala" "$ROOT/kernel/cpu.vala" "$ROOT/kernel/pmm.vala" "$ROOT/kernel/keyboard.vala" "$ROOT/kernel/ata.vala" "$ROOT/kernel/xfs.vala" "$ROOT/kernel/syscall.vala" "$ROOT/kernel/main.vala" -o "$k_bin" 2>"$WORK/k.err"; then
        ko "freestanding_qemu" "compile failed: $(cat "$WORK/k.err")"
    else
        timeout 4 qemu-system-x86_64 -kernel "$k_bin" -drive file="$k_disk",format=raw,if=ide -display none -serial file:"$k_ser" -no-reboot -device isa-debug-exit,iobase=0xf4,iosize=0x04 >/dev/null 2>&1
        qcode=$?
        if [ "$qcode" != "1" ]; then
            ko "freestanding_qemu" "qemu exit $qcode, expected 1"
        elif ! grep -q "PlanetOS v0.1 booted in x86-64 Long Mode" "$k_ser" || ! grep -q "pmm:restored=1" "$k_ser" || ! grep -q "irq0 tick=" "$k_ser" || ! grep -q "sys:ticks=" "$k_ser" || ! grep -q "kb:ok=1" "$k_ser" || ! grep -q "xfs:mounted=1" "$k_ser" || ! grep -q "xfs:hello from PlanetOS disk!" "$k_ser" || ! grep -q "kernel:ok" "$k_ser"; then
            ko "freestanding_qemu" "unexpected serial: $(cat "$k_ser")"
        else
            ok "freestanding_qemu"
        fi
    fi
fi

echo
echo "SUMMARY: $((PASS + FAIL)) cases, $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
