# planc, slice 7: `foreach`, `switch` (VL-14), `s[start:end]` slicing, `?:`, `??`, constants, and `static`/`enum`/`struct` methods

Slice 7 expands the Vala dialect supported natively by `planc` (**I1**, **I2**,
**I3**, **TC-02**, **TC-05**, **VL-12**, **VL-14**, **RT-03**, **RT-04**):
reference-safe array iteration with `foreach`, non-fallthrough `switch` over
`int`/`bool`/`enum`/`string`, bounds-checked string slicing `s[start:end]`,
ternary `?:` (with Option B null narrowing), lazy null-coalescing `??` with
`T? ?? T -> T` unwrapping, `const` declarations, `static` methods on classes,
structs, and enums, instance methods on `enum` and `struct` values, plus hex
(`0x`), binary (`0b`), underscore-separated, suffixed (`u`/`l`), and char
(`'A'`, `'\n'`) literals alongside integer type aliases and `owned`/`unowned`
ownership syntax qualifiers.

Requirements demonstrated: **I1**, **I2**, **I3**, **TC-02**, **TC-05**,
**KR-03**, **VL-12**, **VL-14**, **RT-03**, **RT-04**.

---

## 1. Control flow: `foreach` and `switch`

- **`foreach (var x in arr)` / `foreach (Type x in arr)`:**
  - Evaluates `arr` once, applies Option B null checks only if `arr` has
    nullable type `T[]?`, and retains the array header into a hidden local slot
    (`col_mark`) for the duration of the loop. Reassigning the source array
    variable inside the loop body cannot drop the array reference count to zero
    while iterating.
  - Compares the hidden iteration index (`#fe_idx`) against `[col + 8]`
    (`arr.length`) and reads elements directly from `[col + 16 + 8 * idx]`
    without redundant per-element bounds checks.
  - Per-iteration reference elements (`string`, `Class`) are retained into
    `var_name` (`iter_mark`), released at `unref_locals_from(iter_mark)` on
    normal step, `continue`, and `break`, while `unref_locals_from(col_mark)`
    releases the hidden array reference exactly once at loop exit (deactivating
    `iter_mark` before unreffing `col_mark` to guarantee zero double-frees).
- **`switch (expr)` (VL-14):**
  - Accepts `int` (including aliases), `bool`, `enum`, and non-nullable
    `string`. Structs, arrays, classes, and nullable types are rejected at
    compile time.
  - Evaluates the scrutinee once into `#sw_<mark>` (retaining if `string`),
    dispatches integer/bool/enum `case` arms via `cmp rax, rcx` and `string`
    `case` arms via `__planc_str_eq`, supports multi-label arms (`case 1: case 2:`),
    `default:`, and Vala non-fallthrough exit to `l_end`.
  - Pushes `l_end` onto `break_labels` / `break_scope_marks` (`pop_break_label`)
    without modifying `continue_labels` / `continue_scope_marks`, so `break;`
    exits `switch` while `continue;` inside a `switch` nested in a loop targets
    the enclosing loop and cleans both `case`-local and `#sw_` slots.

---

## 2. String slicing: `s[start:end]` and `__planc_str_slice`

`s[start:end]` lowers to `SliceExpr` and invokes runtime helper
`__planc_str_slice(string* rdi, int64 rsi_start, int64 rdx_end)`:

- **Bounds check (`--no-bounds-check` aware):** performs unsigned range checks
  `cmp rdx, [rdi + 8]; ja __planc_bounds_panic` and
  `cmp rsi, rdx; ja __planc_bounds_panic`, catching `start < 0`, `end < 0`,
  `end > length`, and `start > end` in two comparisons (`exit 134`,
  `planc: panic: index out of bounds`).
- **Empty slice fast path:** when `end <= start` (e.g., `s[2:2]`), returns a
  pointer to the static `.rodata` empty string `""` (zero heap allocation,
  zero-refcount sentinel safe for `__planc_ref`/`__planc_unref`).
- **Non-empty slice:** allocates `(end - start) + 1` bytes via `__planc_alloc`
  with `kind = 0`, stores length `end - start` at `[rax + 8]`, copies bytes
  from `[src + 16 + start]` via `rep movsb`, and appends the trailing NUL byte.

---

## 3. Ternary `?:`, Coalescing `??`, Constants, Methods, and Literals

- **Ternary (`cond ? a : b`):** supports scalar, enum, struct, and reference
  branch unification (including common class ancestors and `null` promotion to
  `T?`), Option B null narrowing when `cond` is `v != null` or `v == null`, and
  per-branch `consume_ref_expr` + sub-temp cleanup into `TernaryExpr.ref_temp_slot`
  so unused branches do not trigger runtime unrefs and live results balance under
  `--check-leaks`.
- **Null-coalescing (`a ?? b`):** short-circuits lazily (only evaluates `b`
  when `a` is `null`), cleans `a` sub-temps on the null path before evaluating
  `b`, and unwraps `T? ?? T -> T` at compile time so downstream uses of the
  result carry zero runtime null checks under Option B.
- **Constants, Static Methods, and Value Methods:**
  - `const` declarations at top level or inside `class`/`struct`/`enum` support
    `int`, `bool`, `enum`, and `string` values (`TypeName.CONST` or unqualified
    within owning type).
  - `static` methods on classes, structs, and enums compile cleanly without a
    `this` parameter or vtable slot (`TypeName.method(...)` or unqualified inside
    the owning type).
  - `enum` and `struct` instance methods compile with mangled symbol
    `<TypeName>__<method>` (`prepare_value_methods`), passing `this` by enum
    value or copied struct value with automatic ARC field retain/unref and
    unqualified field/member lookup.
- **Literals, Integer Type Aliases, and Ownership Modifiers:**
  - Lexer accepts hex (`0x...`), binary (`0b...`), underscore separators
    (`0x10_20`, `0b1010_0101`), unsigned/long suffixes (`u`/`U`/`l`/`L`), and
    char literals (`'A'`, `'\n'`, `'\''`, `'\\'`).
  - Parser accepts 64-bit integer aliases (`int64`, `int32`, `int16`, `int8`,
    `uint64`, `uint32`, `uint16`, `uint8`, `size_t`, `ssize_t`, `char`, `uchar`)
    and `owned`/`unowned` syntax qualifiers on declarations and parameters.
- **Unified Function Temp Assignment:** `prepare_function` records
  `pending_struct_exprs` and `pending_ref_exprs` during `prepare_expr` while
  nested block locals (`if`, `for`, `foreach`, `switch`) are active, fixing
  temp-slot assignment for reference/struct expressions inside block scopes.

---

## 4. Verification

`/home/djmbdv/PlanetOS/planc/tests/run.sh`: **135 cases, 135 pass, 0 fail**
(60 valid including `foreach_array`, `switch_stmt`, `ternary_coalesce`, and
`string_slice_literals`; 51 invalid including `switch_on_struct` and
`foreach_non_array`; 8 bounds including `slice_oob_end` and `slice_oob_order`;
13 `--check-leaks` runs covering all 4 new valid tests with empty `stderr`;
3 null/cast checks).

Determinism (**TC-05**), W^X segments (**KR-03**), and zero external symbols
(**I2**) on `planc --check-leaks planc/tests/valid/ternary_coalesce.vala`:

```
$ sha256sum /tmp/tc1 /tmp/tc2
c6b7508e1d50aa2f20787d07c69e2fb7502956112eee5b29ba1d310cb85a300a  /tmp/tc1
c6b7508e1d50aa2f20787d07c69e2fb7502956112eee5b29ba1d310cb85a300a  /tmp/tc2

$ readelf -lW /tmp/tc1
  LOAD  0x0000e8 0x00000000004000e8 ... R E
  LOAD  0x001000 0x0000000000401000 ... R
  LOAD  0x002000 0x0000000000402000 ... RW  (FileSiz 0x8, MemSiz 0x78)

$ nm -u /tmp/tc1
(empty)

$ /tmp/tc1; echo "EXIT=$?"
cfg_ok:box1:box1:fallback_1:99:true:1:25:1
EXIT=37
```
