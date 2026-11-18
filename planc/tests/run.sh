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

if "$PLANC" --strict-null "$WORK/null_deref.vala" -o "$WORK/null_deref_sn" 2>"$WORK/sn.err"; then
    ko "strict_null_reject" "expected compile error for unguarded T?"
elif ! grep -q "cannot dereference nullable" "$WORK/sn.err"; then
    ko "strict_null_reject" "unexpected error: $(cat "$WORK/sn.err")"
else
    ok "strict_null_reject"
fi

cat >"$WORK/strict_null_ok.vala" <<'EOF'
class Box { public int x = 7; }
int main () {
    Box? b = new Box ();
    if (b != null)
        return b.x == 7 ? 0 : 1;
    return 1;
}
EOF
if ! "$PLANC" --strict-null "$WORK/strict_null_ok.vala" -o "$WORK/strict_null_ok" 2>"$WORK/sn_ok.err"; then
    ko "strict_null_narrowed" "compile failed: $(cat "$WORK/sn_ok.err")"
elif ! "$WORK/strict_null_ok"; then
    ko "strict_null_narrowed" "non-zero exit"
else
    ok "strict_null_narrowed"
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
    u_bin="$WORK/init.elf"
    w_bin="$WORK/worker.elf"
    wc_bin="$WORK/wc.elf"
    cd_bin="$WORK/cairo_demo.elf"
    sp_bin="$WORK/frag.spv"
    sd_bin="$WORK/spv_demo.elf"
    s_bin="$WORK/shell.elf"
    k_ser="$WORK/qemu_serial.log"
    k_disk="$WORK/planet_disk.img"
    if ! "$PLANC" --target=planetos "$ROOT/user/init.vala" -o "$u_bin" 2>"$WORK/u.err"; then
        ko "freestanding_qemu" "user init compile failed: $(cat "$WORK/u.err")"
    elif ! "$PLANC" --target=planetos --image-base=0x900000 "$ROOT/stdlib/planet_sys.vala" "$ROOT/user/worker.vala" -o "$w_bin" 2>"$WORK/w.err"; then
        ko "freestanding_qemu" "user worker compile failed: $(cat "$WORK/w.err")"
    elif ! "$PLANC" --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/glib_compat.vala" "$ROOT/user/wc.vala" -o "$wc_bin" 2>"$WORK/wc.err"; then
        ko "freestanding_qemu" "user wc compile failed: $(cat "$WORK/wc.err")"
    elif ! "$PLANC" --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/cairo_compat.vala" "$ROOT/stdlib/gdk_compat.vala" "$ROOT/user/cairo_demo.vala" -o "$cd_bin" 2>"$WORK/cd.err"; then
        ko "freestanding_qemu" "user cairo_demo compile failed: $(cat "$WORK/cd.err")"
    elif ! "$PLANC" --target=spirv "$ROOT/user/frag_planet.vala" -o "$sp_bin" 2>"$WORK/sp.err"; then
        ko "freestanding_qemu" "frag_planet.vala compile failed: $(cat "$WORK/sp.err")"
    elif ! "$PLANC" --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/spirv_compat.vala" "$ROOT/stdlib/cairo_compat.vala" "$ROOT/stdlib/gdk_compat.vala" "$ROOT/user/spv_demo.vala" -o "$sd_bin" 2>"$WORK/sd.err"; then
        ko "freestanding_qemu" "user spv_demo compile failed: $(cat "$WORK/sd.err")"
    elif ! "$PLANC" --target=planetos --image-base=0xA00000 "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/glib_compat.vala" "$ROOT/user/shell.vala" -o "$s_bin" 2>"$WORK/s.err"; then
        ko "freestanding_qemu" "user shell compile failed: $(cat "$WORK/s.err")"
    else
    python3 - "$k_disk" "$u_bin" "$s_bin" "$w_bin" "$wc_bin" "$cd_bin" "$sp_bin" "$sd_bin" << 'PYEOF'
import struct, sys
elf_bytes = open(sys.argv[2], "rb").read()
sh_bytes = open(sys.argv[3], "rb").read()
wk_bytes = open(sys.argv[4], "rb").read()
wc_bytes = open(sys.argv[5], "rb").read()
cd_bytes = open(sys.argv[6], "rb").read()
sp_bytes = open(sys.argv[7], "rb").read()
sd_bytes = open(sys.argv[8], "rb").read()
elf_blocks = (len(elf_bytes) + 4095) // 4096
sh_blocks = (len(sh_bytes) + 4095) // 4096
wk_blocks = (len(wk_bytes) + 4095) // 4096
wc_blocks = (len(wc_bytes) + 4095) // 4096
cd_blocks = (len(cd_bytes) + 4095) // 4096
sp_blocks = (len(sp_bytes) + 4095) // 4096
sd_blocks = (len(sd_bytes) + 4095) // 4096
sh_start = 6 + elf_blocks
wk_start = sh_start + sh_blocks
wc_start = wk_start + wk_blocks
cd_start = wc_start + wc_blocks
sp_start = cd_start + cd_blocks
sd_start = sp_start + sp_blocks
img = bytearray(max(131072, (sd_start + sd_blocks) * 4096))
# XFS v4 superblock at block 0 (offset 0)
struct.pack_into(">II", img, 0, 0x58465342, 4096) # magic "XFSB", blocksize=4096
struct.pack_into(">Q", img, 56, 64)               # rootino = 64 (block 4, index 0)
struct.pack_into(">I", img, 84, 128)              # agblocks = 128
struct.pack_into(">H", img, 104, 256)             # inodesize = 256
img[123] = 4                                      # inopblog = 4 (16 inodes/block)
img[124] = 7                                      # agblklog = 7

# Inode 64 (root dir, shortform) at block 4 (offset 16384)
r = 4 * 4096
struct.pack_into(">HH", img, r, 0x494E, 0x41ED)   # magic "IN", mode dir
img[r + 4] = 2                                    # version 2
img[r + 5] = 1                                    # format = 1 (local/shortform)
df = r + 100
img[df + 0] = 8                                   # count = 8
img[df + 1] = 0                                   # i8count = 0
struct.pack_into(">I", img, df + 4, 64)           # parent ino = 64
ent = df + 8
for name, child in [(b"hello.txt", 65), (b"init.elf", 66), (b"shell.elf", 67), (b"worker.elf", 68), (b"wc.elf", 69), (b"cairo_demo.elf", 70), (b"frag.spv", 71), (b"spv_demo.elf", 72)]:
    img[ent] = len(name)
    struct.pack_into(">H", img, ent + 1, 0)
    img[ent + 3:ent + 3 + len(name)] = name
    struct.pack_into(">I", img, ent + 3 + len(name), child)
    ent = ent + 3 + len(name) + 4

# Inode 65 (hello.txt, extent in block 5) at block 4 + 256
f = r + 256
payload = b"xfs:hello from PlanetOS disk!\n"
struct.pack_into(">HH", img, f, 0x494E, 0x81A4)   # magic "IN", mode file
img[f + 4] = 2                                    # version 2
img[f + 5] = 2                                    # format = 2 (extents)
struct.pack_into(">Q", img, f + 56, len(payload)) # di_size
struct.pack_into(">I", img, f + 76, 1)            # di_nextents = 1
struct.pack_into(">QQ", img, f + 100, 0, (5 << 21) | 1)
img[5 * 4096:5 * 4096 + len(payload)] = payload

# Inode 66 (init.elf, extent starting at block 6) at block 4 + 512
f2 = r + 512
struct.pack_into(">HH", img, f2, 0x494E, 0x81ED)  # magic "IN", mode file+x
img[f2 + 4] = 2
img[f2 + 5] = 2
struct.pack_into(">Q", img, f2 + 56, len(elf_bytes))
struct.pack_into(">I", img, f2 + 76, 1)
struct.pack_into(">QQ", img, f2 + 100, 0, (6 << 21) | elf_blocks)
img[6 * 4096:6 * 4096 + len(elf_bytes)] = elf_bytes

# Inode 67 (shell.elf, extent starting at sh_start) at block 4 + 768
f3 = r + 768
struct.pack_into(">HH", img, f3, 0x494E, 0x81ED)
img[f3 + 4] = 2
img[f3 + 5] = 2
struct.pack_into(">Q", img, f3 + 56, len(sh_bytes))
struct.pack_into(">I", img, f3 + 76, 1)
struct.pack_into(">QQ", img, f3 + 100, 0, (sh_start << 21) | sh_blocks)
img[sh_start * 4096:sh_start * 4096 + len(sh_bytes)] = sh_bytes

# Inode 68 (worker.elf, extent starting at wk_start) at block 4 + 1024
f4 = r + 1024
struct.pack_into(">HH", img, f4, 0x494E, 0x81ED)
img[f4 + 4] = 2
img[f4 + 5] = 2
struct.pack_into(">Q", img, f4 + 56, len(wk_bytes))
struct.pack_into(">I", img, f4 + 76, 1)
struct.pack_into(">QQ", img, f4 + 100, 0, (wk_start << 21) | wk_blocks)
img[wk_start * 4096:wk_start * 4096 + len(wk_bytes)] = wk_bytes

# Inode 69 (wc.elf, extent starting at wc_start) at block 4 + 1280
f5 = r + 1280
struct.pack_into(">HH", img, f5, 0x494E, 0x81ED)
img[f5 + 4] = 2
img[f5 + 5] = 2
struct.pack_into(">Q", img, f5 + 56, len(wc_bytes))
struct.pack_into(">I", img, f5 + 76, 1)
struct.pack_into(">QQ", img, f5 + 100, 0, (wc_start << 21) | wc_blocks)
img[wc_start * 4096:wc_start * 4096 + len(wc_bytes)] = wc_bytes

# Inode 70 (cairo_demo.elf, extent starting at cd_start) at block 4 + 1536
f6 = r + 1536
struct.pack_into(">HH", img, f6, 0x494E, 0x81ED)
img[f6 + 4] = 2
img[f6 + 5] = 2
struct.pack_into(">Q", img, f6 + 56, len(cd_bytes))
struct.pack_into(">I", img, f6 + 76, 1)
struct.pack_into(">QQ", img, f6 + 100, 0, (cd_start << 21) | cd_blocks)
img[cd_start * 4096:cd_start * 4096 + len(cd_bytes)] = cd_bytes

# Inode 71 (frag.spv) at block 4 + 1792
f7 = r + 1792
struct.pack_into(">HH", img, f7, 0x494E, 0x81A4)
img[f7 + 4] = 2; img[f7 + 5] = 2
struct.pack_into(">Q", img, f7 + 56, len(sp_bytes))
struct.pack_into(">I", img, f7 + 76, 1)
struct.pack_into(">QQ", img, f7 + 100, 0, (sp_start << 21) | sp_blocks)
img[sp_start * 4096:sp_start * 4096 + len(sp_bytes)] = sp_bytes

# Inode 72 (spv_demo.elf) at block 4 + 2048
f8 = r + 2048
struct.pack_into(">HH", img, f8, 0x494E, 0x81ED)
img[f8 + 4] = 2; img[f8 + 5] = 2
struct.pack_into(">Q", img, f8 + 56, len(sd_bytes))
struct.pack_into(">I", img, f8 + 76, 1)
struct.pack_into(">QQ", img, f8 + 100, 0, (sd_start << 21) | sd_blocks)
img[sd_start * 4096:sd_start * 4096 + len(sd_bytes)] = sd_bytes

open(sys.argv[1], "wb").write(img)
PYEOF
    if ! "$PLANC" --freestanding "$ROOT/planetrt/boot_mb2.vala" "$ROOT/planetrt/serial.vala" "$ROOT/kernel/layout.vala" "$ROOT/kernel/klog.vala" "$ROOT/kernel/cpu.vala" "$ROOT/kernel/vga.vala" "$ROOT/kernel/fb.vala" "$ROOT/kernel/pmm.vala" "$ROOT/kernel/vmm.vala" "$ROOT/kernel/console_font.vala" "$ROOT/kernel/virtio_gpu.vala" "$ROOT/kernel/env.vala" "$ROOT/kernel/ramfs.vala" "$ROOT/kernel/keyboard.vala" "$ROOT/kernel/rtc.vala" "$ROOT/kernel/mouse.vala" "$ROOT/kernel/ata.vala" "$ROOT/kernel/xfs.vala" "$ROOT/kernel/vfs.vala" "$ROOT/kernel/syscall.vala" "$ROOT/kernel/elf_loader.vala" "$ROOT/kernel/sched.vala" "$ROOT/kernel/main.vala" -o "$k_bin" 2>"$WORK/k.err"; then
        ko "freestanding_qemu" "compile failed: $(cat "$WORK/k.err")"
    else
        printf '\nhelp\nls\ncat hello.txt\nwrite nota.txt hola ñ €\ncat nota.txt\nFOO=planet; echo "var=$FOO" > r.txt; cat < r.txt\ntrue && echo ok-and\nfalse || echo ok-or\nls | cat\nexec wc.elf hello.txt\nexec cairo_demo.elf --once\nexec spv_demo.elf --once\nexec worker.elf &\nps\nexec init.elf\nwait 1\nticks\nexit\n' | timeout 6 qemu-system-x86_64 -kernel "$k_bin" -drive file="$k_disk",format=raw,if=ide -display none -serial stdio -no-reboot -device isa-debug-exit,iobase=0xf4,iosize=0x04 >"$k_ser" 2>/dev/null
        qcode=$?
        if [ "$qcode" != "1" ]; then
            ko "freestanding_qemu" "qemu exit $qcode, expected 1"
        elif ! grep -q "PlanetOS v0.1 booted in x86-64 Long Mode" "$k_ser" || ! grep -q "PlanetOS Shell v0.2" "$k_ser" || ! grep -q "PlanetOS dash" "$k_ser" || ! grep -q "shell.elf" "$k_ser" || ! grep -q "hola ñ €" "$k_ser" || ! grep -q "var=planet" "$k_ser" || ! grep -q "ok-and" "$k_ser" || ! grep -q "ok-or" "$k_ser" || ! grep -q "hello.txt: lines=1 words=4 bytes=30 chars=30 \[has PlanetOS\]" "$k_ser" || ! grep -q "cairo_demo: done" "$k_ser" || ! grep -q "spv_demo: frag.spv" "$k_ser" || ! grep -q "rgb=(56,188,247)" "$k_ser" || ! grep -q "spawn: tid=1" "$k_ser" || ! grep -q "worker: completed after" "$k_ser" || ! grep -q "wait: tid=1 exit=7" "$k_ser" || ! grep -q "user/init.elf: hello from --target=planetos!" "$k_ser" || ! grep -q "user/init.elf: Counter.next() = 42" "$k_ser" || ! grep -q "user/init.elf: utf8 'ñandú' chars=5 valid=1" "$k_ser" || ! grep -q "exec: exit=0" "$k_ser" || ! grep -q "ticks: " "$k_ser"; then
            ko "freestanding_qemu" "unexpected serial: $(cat "$k_ser")"
        else
            ok "freestanding_qemu"
        fi
    fi
    fi

    echo "== planetos_planc_qemu =="
    p_elf="$WORK/planc.elf"
    p_disk="$WORK/planet_planc_disk.img"
    p_ser="$WORK/qemu_planc_serial.log"
    if ! "$PLANC" --target=planetos --image-base=0xC00000 "$ROOT/stdlib/planet_sys.vala" "$ROOT/planc/src/buffer.vala" "$ROOT/planc/src/host_planetos.vala" "$ROOT/planc/src/ast.vala" "$ROOT/planc/src/lexer.vala" "$ROOT/planc/src/parser.vala" "$ROOT/planc/src/asm.vala" "$ROOT/planc/src/emitter.vala" "$ROOT/planc/src/elf.vala" "$ROOT/planc/src/dwarf.vala" "$ROOT/planc/src/spirv.vala" "$ROOT/planc/src/opt.vala" "$ROOT/planc/src/codegen.vala" "$ROOT/planc/src/main.vala" -o "$p_elf" 2>"$WORK/p_elf.err"; then
        ko "planetos_planc_qemu" "planc.elf compile failed: $(cat "$WORK/p_elf.err")"
    else
    python3 - "$p_disk" "$s_bin" "$p_elf" "$HERE/valid/utf8.vala" "$HERE/valid/class_basic.vala" << 'PYEOF'
import struct, sys
sh_bytes = open(sys.argv[2], "rb").read()
pl_bytes = open(sys.argv[3], "rb").read()
t1_bytes = open(sys.argv[4], "rb").read()
t2_bytes = open(sys.argv[5], "rb").read()

def blk(b): return (len(b) + 4095) // 4096
b_hello = 5
b_shell = 6
b_planc = b_shell + blk(sh_bytes)
b_t1 = b_planc + blk(pl_bytes)
b_t2 = b_t1 + blk(t1_bytes)
total_blocks = max(1024, b_t2 + blk(t2_bytes))
img = bytearray(total_blocks * 4096)

struct.pack_into(">II", img, 0, 0x58465342, 4096)
struct.pack_into(">Q", img, 56, 64)
struct.pack_into(">I", img, 84, total_blocks)
struct.pack_into(">H", img, 104, 256)
img[123] = 4; img[124] = 10

r = 4 * 4096
struct.pack_into(">HH", img, r, 0x494E, 0x41ED)
img[r + 4] = 2; img[r + 5] = 1
df = r + 100
entries = [
    (b"hello.txt", 65, b"xfs:hello\n", b_hello, 0x81A4),
    (b"shell.elf", 66, sh_bytes, b_shell, 0x81ED),
    (b"planc.elf", 67, pl_bytes, b_planc, 0x81ED),
    (b"utf8.vala", 68, t1_bytes, b_t1, 0x81A4),
    (b"class_basic.vala", 69, t2_bytes, b_t2, 0x81A4),
]
img[df + 0] = len(entries); img[df + 1] = 0
struct.pack_into(">I", img, df + 4, 64)
ent = df + 8
for name, child, data, sblk, mode in entries:
    img[ent] = len(name); struct.pack_into(">H", img, ent + 1, 0)
    img[ent + 3:ent + 3 + len(name)] = name
    struct.pack_into(">I", img, ent + 3 + len(name), child)
    ent = ent + 3 + len(name) + 4
    fi = r + (child - 64) * 256
    struct.pack_into(">HH", img, fi, 0x494E, mode)
    img[fi + 4] = 2; img[fi + 5] = 2
    struct.pack_into(">Q", img, fi + 56, len(data))
    struct.pack_into(">I", img, fi + 76, 1)
    bc = blk(data)
    struct.pack_into(">QQ", img, fi + 100, 0, (sblk << 21) | bc)
    img[sblk * 4096:sblk * 4096 + len(data)] = data

open(sys.argv[1], "wb").write(img)
PYEOF
    printf '\nexec planc.elf --target=planetos utf8.vala -o utf8.elf\nexec utf8.elf\nexec planc.elf --target=planetos class_basic.vala -o cls.elf\nexec cls.elf\nexit 0\n' | timeout 15 qemu-system-x86_64 -kernel "$k_bin" -drive file="$p_disk",format=raw,if=ide -display none -serial stdio -no-reboot -device isa-debug-exit,iobase=0xf4,iosize=0x04 >"$p_ser" 2>/dev/null
    qcode=$?
    if [ "$qcode" != "1" ]; then
        ko "planetos_planc_qemu" "qemu exit $qcode, expected 1 ($(tail -n 10 "$p_ser"))"
    elif ! grep -q "chars=5 valid=1" "$p_ser" || ! grep -q "cp0=0xF1 cp1=0x20AC cp2=0x1F680" "$p_ser" || ! grep -q "exec: exit=0" "$p_ser"; then
        ko "planetos_planc_qemu" "unexpected serial: $(cat "$p_ser")"
    else
        ok "planetos_planc_qemu"
    fi
    fi

    echo "== spirv =="
    cat >"$WORK/frag_planet.vala" <<'EOF'
void main () {
    float r = 0.22;
    float g = 0.74;
    float b = 0.97;
    float a = 1.0;
    frag_color (r * 1.0, g + 0.0, b, a);
}
EOF
    cat >"$WORK/bad_shader.vala" <<'EOF'
void main () {
    print ("nope\n");
}
EOF
    if ! "$PLANC" --target=spirv "$WORK/frag_planet.vala" -o "$WORK/frag1.spv" 2>"$WORK/spv.err"; then
        ko "spirv_shader" "compile failed: $(cat "$WORK/spv.err")"
    elif ! "$PLANC" --target=spirv "$WORK/frag_planet.vala" -o "$WORK/frag2.spv" 2>/dev/null; then
        ko "spirv_shader" "second compile failed"
    elif ! cmp -s "$WORK/frag1.spv" "$WORK/frag2.spv"; then
        ko "spirv_shader" "non-deterministic .spv output"
    elif ! python3 - "$WORK/frag1.spv" <<'PYEOF'
import struct, sys
b = open(sys.argv[1], "rb").read()
assert len(b) >= 20 and len(b) % 4 == 0
words = struct.unpack("<" + "I" * (len(b) // 4), b)
assert words[0] == 0x07230203, f"bad magic {hex(words[0])}"
assert words[1] == 0x00010000, f"bad version {hex(words[1])}"
assert words[3] > 5
PYEOF
    then
        ko "spirv_shader" "invalid SPIR-V header"
    elif "$PLANC" --target=spirv "$WORK/bad_shader.vala" -o "$WORK/bad.spv" 2>/dev/null; then
        ko "spirv_shader" "expected GX-04 rejection of print() in shader"
    else
        ok "spirv_shader"
    fi
fi

echo
echo "== -O1 optimization =="
if ! "$PLANC" -O1 "$HERE/valid/opt_o1.vala" -o "$WORK/opt_o1_bin" 2>"$WORK/opt_o1.err"; then
    ko "opt_o1_flag" "compile failed: $(cat "$WORK/opt_o1.err")"
elif ! "$WORK/opt_o1_bin" >"$WORK/opt_o1.stdout" 2>&1; then
    ko "opt_o1_flag" "non-zero exit"
elif ! cmp -s "$WORK/opt_o1.stdout" "$HERE/valid/opt_o1.out"; then
    ko "opt_o1_flag" "stdout differs from opt_o1.out"
else
    ok "opt_o1_flag"
fi

if ! "$PLANC" -O2 "$HERE/valid/opt_o2.vala" -o "$WORK/opt_o2_bin" 2>"$WORK/opt_o2.err"; then
    ko "opt_o2_flag" "compile failed: $(cat "$WORK/opt_o2.err")"
elif ! "$WORK/opt_o2_bin" >"$WORK/opt_o2.stdout" 2>&1; then
    ko "opt_o2_flag" "non-zero exit"
elif ! cmp -s "$WORK/opt_o2.stdout" "$HERE/valid/opt_o2.out"; then
    ko "opt_o2_flag" "stdout differs from opt_o2.out"
else
    ok "opt_o2_flag"
fi

echo
echo "SUMMARY: $((PASS + FAIL)) cases, $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
