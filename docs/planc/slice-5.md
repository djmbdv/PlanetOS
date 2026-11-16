# planc, slice 5: safe heap allocator, automatic reference counting, `T[]`, `s1 + s2`, and value `@"..."`

Slice 4 gave `planc` a 16-byte `string` ABI header, bounds-checked indexing,
`bool`, `for`/`break`/`continue`, `enum`, and value `struct`s. Slice 5 adds a
standalone heap runtime with zero C/GLib dependencies (**I1**, **I2**, **I3**):
a guarded arena + segregated size-class slab allocator, automatic atomic
reference counting (**RT-03**), dynamic arrays `T[]`, string concatenation (`+`),
value-producing `@"..."` string templates, and deterministic leak checking via
`--check-leaks` (**RT-04**).

Requirements demonstrated: **I1**, **I2**, **I3**, **TC-02**, **TC-05**,
**TC-08**, **KR-03**, **RT-03**, **RT-04**, **VL-11**.

---

## 1. Safe heap allocator (`__planc_alloc`, `__planc_ref`, `__planc_unref`)

No `g_malloc`/`g_free` or libc wrapper exists. Programs that do not perform
heap operations emit zero allocator code and zero `.bss` overhead. When a
program uses `T[]`, `+` on `string`, or value `@"..."` templates, `Codegen`
reserves a 96-byte control block (`0x60` bytes) in `.bss` and emits the
allocator intrinsics on demand:

```
.bss control block (96 bytes):
  +0   alloc_count   u64   (lock incq on allocation)
  +8   free_count    u64   (lock incq when refcount hits 0)
  +16  arena_cur     u64   bump pointer within current arena
  +24  arena_end     u64   exclusive usable bound (before guard page)
  +32  free_lists[8] u64[] LIFO intrusive free-lists for classes 0..7
```

- **8 segregated size classes (`32 B` .. `4096 B`):** requests up to `4096`
  bytes total (`16 + payload`) map to classes `0..7` (`32 << class`). Freed
  blocks push onto `free_lists[class]` using header offset `+8` as the intrusive
  `next` link, and pop in $O(1)$ time with `rep stosq` zero-clearing on reuse.
- **Guarded `mmap` arenas (`SYS_MMAP=9`, `SYS_MPROTECT=10`):** when a bump
  allocation needs fresh memory, `__planc_alloc` maps `0x11000` bytes (68 KiB)
  anonymous RW and immediately calls `mprotect(base + 0x10000, 4096, PROT_NONE)`
  to place a 4 KiB unmapped hardware guard page behind every 64 KiB usable
  arena. Requests exceeding `4096` bytes round up to a 4 KiB multiple plus a
  trailing `4096`-byte `PROT_NONE` guard page (`size_class = 0xff`).
- **Temporal & metadata safety checks:**
  - `.rodata` string literals carry `refcount = 0` (`magic = 0`), so
    `__planc_ref` and `__planc_unref` treat `ptr == null` or `refcount == 0`
    as immutable no-ops.
  - Heap blocks initialize `magic = 0x504C` (`'PL'`) and `refcount = 1`.
  - Both `__planc_ref` and `__planc_unref` check `refcount != 0xDEADDEAD` and
    `magic == 0x504C`, aborting through `__planc_mem_panic` (exit `134`,
    diagnostic `planc: panic: memory safety violation (use-after-free or corrupt header)`)
    on double-free, use-after-free, or header corruption.
  - When atomic `lock dec dword ptr [rdi]` hits `0`, `__planc_unref` immediately
    writes `0xDEADDEAD` into `[rdi]`, recursively unrefs every array element
    if `elem_ref != 0`, and increments `free_count`.

```
+0    u32   refcount     (0 = immutable .rodata; >=1 = live heap; 0xDEADDEAD = freed)
+4    u8    elem_ref     (1 if elements are refcounted pointers, e.g. string[])
+5    u8    size_class   (0..7 = slab 32B..4096B; 0xff = large mmap block)
+6    u16   magic        (0x504C 'PL' on heap; 0 in .rodata)
+8    u64   length       (byte count for string, element count for T[])
+16   ...                UTF-8 payload + NUL (string) or elements (T[])
```

- **Leak detection (`--check-leaks`):** opt-in flag (`planc --check-leaks`)
  that compares `alloc_count` against `free_count` in `_start` after cleanup of
  globals and exits with `134` (`planc: panic: memory leak detected`) if any
  heap object remained live.

---

## 2. Automatic ownership & Vala language additions

```
type        := ('int' | 'bool' | 'string' | 'void' | IDENT) ('[]')*
expr        := ... -> primary
primary     := ... | 'new' type '[' expr ']' | '{' expr (',' expr)* '}'
simple_stmt := ... | IDENT '[' expr ']' ('=' | '+=' | '-=' | '++' | '--') expr?
```

- **Compiler-inserted ARC:** `Codegen` tracks managed local slots, managed
  fields inside value `struct`s, global variables, and temporary reference
  expression slots (`ref_temp_slot`). Ownership is maintained automatically on:
  - Variable initialization and reassignment (retaining RHS, unref'ing prior
    slot value).
  - Return values (`consume_ref_expr` transfers temporary ownership out to the
    caller, while remaining locals/temporaries are unref'd before `ret`).
  - Block exit, `for`/`while` body exit, `break`, and `continue` (unref'ing
    every inner scope variable created since the target loop boundary).
  - Statement boundaries (releasing any non-consumed expression temporaries such
    as inline concatenations passed into `print(a + b)` or `foo(@"...")`).
- **Dynamic arrays (`T[]`):** supports `int[]`, `bool[]`, `string[]`, and
  `enum[]`. `new T[n]` bounds-checks `n >= 0`, allocates `16 + 8 * n` bytes, and
  zero-initializes scalar arrays or fills `string[]` elements with immutable `""`
  (setting `elem_ref = 1` so dropping `string[]` recursively releases elements).
  Array literals `{ e1, e2, ... }` support local initializers and direct element
  typing. `arr.length` reads `[arr + 8]` in $O(1)$; `arr[i]` and element writes
  (`=`, `+=`, `-=`, `++`, `--`) share the bounds-checking mechanism of Slice 4,
  while `s[i] = ...` on immutable `string` values is rejected at compile time.
- **String concatenation (`+`) & value templates (`@"..."`):** `s1 + s2` emits
  `__planc_str_concat`, allocating exact UTF-8 byte lengths + trailing `0x00`.
  Non-trivial `@"..."` expressions outside `print(...)` materialize a heap
  `string` via `__planc_int_to_str` and `__planc_str_concat` chains (static
  templates such as `@"plain\n"` fold directly into `.rodata`), while
  `print(@"...")` preserves Slice 3's zero-allocation direct `write` path.

---

## 3. Runtime intrinsics added

| Symbol | Signature | Purpose |
|---|---|---|
| `__planc_alloc` | `void* (u64 payload_bytes, u8 elem_ref)` | Size-class slab pop / guarded `0x11000` arena bump / large `mmap + mprotect` |
| `__planc_ref` | `void* (void* ptr)` | Validates header (`0x504C`, not poisoned), `lock incl [rdi]` if heap |
| `__planc_unref` | `void (void* ptr)` | Validates header, `lock decl [rdi]`; poisons `0xDEADDEAD`, recurses elements, pushes slab or bumps `free_count` |
| `__planc_str_concat` | `string* (string* a, string* b)` | Allocates `a.len + b.len + 1`, copies UTF-8 payloads + `0x00` |
| `__planc_int_to_str` | `string* (int64 val)` | Formats signed 64-bit integer (`int64.MIN`-safe) into a heap `string` |
| `__planc_mem_panic` | `noreturn` | Writes memory safety violation diagnostic to `stderr`, exits `134` |
| `__planc_leak_panic` | `noreturn` | Writes leak diagnostic to `stderr` (`--check-leaks`), exits `134` |

---

## 4. Verification

```sh
./planc/build.sh
./planc/tests/run.sh     # 107 cases, 107 pass, 0 fail
```

- **Valid (51):** all 46 Slice 0–4 tests plus `array_int`, `array_string`,
  `string_concat`, `template_value`, and `refcount_loop` (500 loop iterations
  exercising allocations, concatenations, templates, `int[]`/`string[]`, helper
  returns, `continue`, and `break`).
- **Invalid (44):** all 40 Slice 0–4 rejections plus `array_type_mismatch`,
  `array_elem_mismatch`, `array_size_not_int`, and `string_index_assign`, plus
  updated `type_mismatch_template_var` (`int s = @"$x";`).
- **Bounds (6):** `oob_neg`, `oob_pos`, `no_bounds_check`, `array_oob_pos`,
  `array_oob_neg`, and `array_neg_size`.
- **Leak checks (`--check-leaks`, 5):** `array_int`, `array_string`,
  `string_concat`, `template_value`, and `refcount_loop` all pass with
  `alloc_count == free_count` (`stderr` empty, exit codes matching `.code`),
  3 `PT_LOAD` segments (`R E`, `R`, `RW`), empty `nm -u`, and deterministic
  SHA-256 outputs.

Determinism (**TC-05**), segment audit (**KR-03**), and GDB backtrace (**TC-08**)
on `planc --check-leaks planc/tests/valid/array_string.vala`:

```
$ sha256sum b1 b2
68e43a2f729c28b15beab0c9a2c19c037a0915674ceb0c90521e69035f1daffa  b1
68e43a2f729c28b15beab0c9a2c19c037a0915674ceb0c90521e69035f1daffa  b2

$ readelf -lW b1
  LOAD  0x0000e8 0x00000000004000e8 ... R E
  LOAD  0x001000 0x0000000000401000 ... R
  LOAD  0x002000 0x0000000000402000 ... RW  (FileSiz 0x0, MemSiz 0x60)

$ gdb -batch -ex 'b __planc_str_concat' -ex 'run' -ex 'bt' b1
#0  0x0000000000400835 in __planc_str_concat ()
#1  0x000000000040030c in main ()
```
