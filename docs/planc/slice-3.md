# planc, slice 3: types, string ABI layout, and intrinsic formatting

Slice 2 gave the compiler stack arguments and global variables in `.data`/`.bss`,
with `int` as the only data type. Slice 3 introduces a real static type system
(`int`, `string`, `void` plus local `var` inference), the ABI's first reference
type (`string` with its header in `.rodata` and `R_X86_64_64` relocations in
`.data`), string operations (`.length`, `==`, `!=`), and intrinsic formatting
(`print(expr)` and `@"..."` templates) without `va_list` or a heap allocator.

Requirements demonstrated: **I1**, **I2**, **TC-02**, **TC-05**, **TC-08**,
**KR-03**, plus the `string` header layout of
[01-architecture.md §3.2](../01-architecture.md) /
[03-runtime-and-stdlib.md §3.1](../03-runtime-and-stdlib.md) and compiler-driven
formatting (**VL-11**, [03-runtime-and-stdlib.md §3.2](../03-runtime-and-stdlib.md)).

---

## 1. Language and type additions

```
program    := (function | global)*
global     := ('int' IDENT ('=' '-'? INTEGER)?
           |   'string' IDENT ('=' STRING)?) ';'
function   := type IDENT '(' params? ')' block
type       := 'int' | 'string' | 'void'
params     := param_type IDENT (',' param_type IDENT)*
param_type := 'int' | 'string'
statement  := 'print' '(' expr ')' ';'
            | 'exit' '(' expr ')' ';'
            | 'return' expr? ';'
            | ('int' | 'string') IDENT ('=' expr)? ';'
            | 'var' IDENT '=' expr ';'
            | IDENT '=' expr ';'
            | 'if' '(' expr ')' stmt ('else' stmt)?
            | 'while' '(' expr ')' stmt
            | block
            | expr ';'
unary      := ('-' | '!') unary | postfix
postfix    := primary ('.' 'length')*
primary    := INTEGER | STRING | TEMPLATE_STRING
            | IDENT | IDENT '(' args ')' | '(' expr ')'
```

- **Static type checking:** Every expression and statement is type-checked
  before emission (`SemanticError.TYPE_MISMATCH`). Conditions in `if`/`while`,
  `exit(...)`, arithmetic, comparisons (`<`, `<=`, `>`, `>=`), and `&&`/`||`
  require `int`. Equality (`==`, `!=`) accepts matching types (`int` with `int`,
  or `string` with `string`). `main` may return `int` or `void`, never `string`.
- **Local `var` inference:** `var x = expr;` infers `int` or `string` from the
  initializer (rejecting `void` calls and uninitialized `var`).
- **Uninitialized `string`:** Both local (`string s;`) and global (`string g;`)
  declarations without an initializer default to the empty string `""` (never a
  null pointer).
- **`.length`:** Returns the UTF-8 byte count (`int64`) up to the terminating
  NUL (`"añb".length == 4`), matching `03-runtime-and-stdlib.md §3.1` and
  [E-01](../experiments/E01-dialect.md).
- **`print` and `@"..."` templates:** Without `va_list` (**VL-11**),
  `print(@"...")` lowers directly to a sequence of typed calls (`__planc_write_str`
  for `string` parts, `__planc_write_int` for `int` parts), with `$$` escaping a
  literal `$`. Static-only templates (`@"static $$"`) evaluate to a `.rodata`
  string anywhere; interpolated templates outside `print(...)` are rejected with
  a positioned diagnostic because heap allocation belongs to slice 4 (`planetrt`).

## 2. Parser precedence fix (`seed` threading)

Reviewing [parser.vala](../../planc/src/parser.vala) uncovered a precedence bug
in Slice 1/2: `parse_primary()` called `parse_lor(e)` directly on any
identifier or call expression, while `parse_lor(seed)`..`parse_add(seed)`
short-circuited down-propagation instead of forwarding `seed` to
`parse_mul(seed)`. As a result:

- `2 * a + b` parsed as `2 * (a + b)` when `a` was a variable;
- `c && a || 1` parsed as `c && (a || 1)`.

Slice 3 fixes `parse_primary()` to return the atom (`VarRef` or `CallExpr`)
directly, `parse_unary()` to apply `parse_postfix(...)`, and threads `seed`
uniformly from `parse_lor` through `parse_mul`. Covered by regression test
`tests/valid/precedence_vars.vala`.

## 3. `string` ABI layout and `.data` relocations

Static string literals live in `.rodata`, deduplicated and 8-byte aligned, with
the runtime header defined in [01-architecture.md §3.2](../01-architecture.md)
and [03-runtime-and-stdlib.md §3.1](../03-runtime-and-stdlib.md):

```
offset  size  field
+0      4     refcount (uint32 = 0 for static .rodata strings)
+4      4     hash     (uint32 = 0, uncomputed)
+8      N+1   UTF-8 bytes followed by 0x00
```

Loading a string literal emits `lea rax, [rip + disp32]` (`48 8D 05`) targeting
the header base in `.rodata`.

Global `string` variables live in `.data` as 8-byte pointers initialized to
their `.rodata` string header (including `""` for uninitialized `string g;`).
Because `.data` cannot use RIP-relative instructions, `Emitter` records a
`DataPatch { data_offset, rodata_target }` and `main.vala` resolves it as a
64-bit absolute relocation (`R_X86_64_64`: `layout.rodata_vaddr + rodata_target`).
For `string_globals.vala`, `objdump -s -j .rodata -j .data` shows:

```
.rodata:
  401000: 00000000 00000000 68692000 00000000  ........hi .....
  401010: 00000000 00000000 00000000 00000000  ................
  401020: 00000000 00000000 706c616e 65740a00  ........planet..
.data:
  402000: 00104000 00000000  (0x401000 -> "hi ")
  402008: 10104000 00000000  (0x401010 -> "")
```

## 4. Runtime intrinsics (emitted on demand)

To keep programs that do not format integers or compare strings compact,
`Codegen` tracks which helpers are referenced and emits only those at the end
of `.text` as regular `.symtab` symbols:

| Symbol | Signature | Purpose |
|---|---|---|
| `__planc_str_len` | `int64 (string* rdi)` | Scans `[rdi + 8 + rax]` for `0x00`; preserves `rdi` |
| `__planc_write_str` | `void (string* rdi)` | Calls `__planc_str_len`, then `write(1, rdi + 8, rax)` |
| `__planc_str_eq` | `int64 (string* rdi, string* rsi)` | Pointer fast path (`cmp rdi, rsi`), then byte-by-byte compare up to `0x00` |
| `__planc_write_int` | `void (int64 rdi)` | Converts signed 64-bit decimal into a 32-byte stack buffer, handles `int64.MIN` via `neg rax` + unsigned `div r9`, calls `write(1, buf, len)` |

All calls to these intrinsics inside expressions go through `call_aligned`,
preserving 16-byte stack alignment whenever `push_depth` is odd.

## 5. Verification

```sh
./planc/build.sh
./planc/tests/run.sh     # 72 cases, 72 pass
```

- **Valid (41):** all 33 slice-2 cases pass unchanged, plus `precedence_vars`,
  `string_vars`, `string_fn` (parameters, returns, and 8-arg mixed stack calls),
  `string_globals` (initialized and uninitialized `.data` globals),
  `string_eq` (`==`/`!=`), `string_length` (ASCII, empty, and 4-byte UTF-8
  `"añb"`), `template_print` (`$ident`, `$(expr)`, `$$`, `0`, negatives,
  `int64.MIN`), and `var_infer`. Every produced ELF still passes `ET_EXEC`,
  exactly 3 `PT_LOAD` segments, no `RWE` segment, and empty `nm -u`.
- **Invalid (31):** the 20 slice-2 invalid cases plus `type_mismatch_init`,
  `type_mismatch_assign`, `type_mismatch_arg`, `type_mismatch_return`,
  `type_mismatch_eq`, `type_mismatch_template_var`, `length_on_int`,
  `var_no_init`, `string_main`, `global_string_not_literal`, and
  `void_in_template`.

Determinism (**TC-05**), segment audit (**KR-03**), and GDB backtrace (**TC-08**):

```
$ sha256sum tp1 tp2          # template_print.vala compiled twice
64d768499e39a46ed288acb1d71ff1a0067e03b9fe618dd5b7734e29262570cf  tp1
64d768499e39a46ed288acb1d71ff1a0067e03b9fe618dd5b7734e29262570cf  tp2

$ readelf -lW sg | grep LOAD # string_globals.vala
  LOAD  0x0000e8 0x00000000004000e8 ... R E
  LOAD  0x001000 0x0000000000401000 ... R
  LOAD  0x002000 0x0000000000402000 ... RW

$ gdb -batch -ex 'break choose' -ex run -ex bt sfn
#0  0x00000000004000f0 in choose ()
#1  0x00000000004001fc in main ()
```

## 6. Vala constraints hit while writing this

- In `valac` 0.56, single-quoted `$` or `$(` inside a `@"..."` template string
  still triggers template interpolation parsing (e.g., `@"unterminated '$(' ..."`
  fails to parse `'`). Error messages containing literal `$` use `.printf(...)`
  instead of `@"..."`.
- Returning an `unowned Function` from a helper requires an explicit
  `unowned Function?` local variable rather than `var`, which infers a strong
  reference.
- Using an `out` variable in the second branch of a short-circuiting `||`
  condition requires initializing it at declaration (`ValaType pt = ValaType.VOID;`)
  to satisfy `valac`'s definite-assignment check.

## 7. What slice 3 deliberately does not do

| Missing | Consequence | Where it is specified |
|---|---|---|
| Heap allocator, refcounting, `+` on strings, dynamic `@"..."` values | Templates with expressions are restricted to `print(...)`; strings are static `.rodata` pointers | [03-runtime-and-stdlib.md](../03-runtime-and-stdlib.md) |
| `bool`, narrower/unsigned ints, floats, arrays, structs, classes | Only `int`, `string`, `void` exist | [01-architecture.md §3.2](../01-architecture.md) |
| Register allocation | Locals/params still spill to `[rbp - 8*(slot+1)]` | [02-compiler.md](../02-compiler.md) |
| Relocatable `ET_REL` objects, linker | Single translation unit only | [02-compiler.md](../02-compiler.md) |
| DWARF line/variable tables | GDB walks frames and symbols, not lines/locals | [02-compiler.md](../02-compiler.md) |
| `[AsmBody]`, SPIR-V target | Specified in design only | [02-compiler.md](../02-compiler.md) |
| Self-hosting | Stage 0 still compiled by `valac` | [06-verification.md](../06-verification.md) |

Next: either introducing `bool`, `for`, `break`/`continue` and structs/arrays
to expand the language toward self-hosting, or separating the SSA IR /
relocatable `ET_REL` object pipeline ([02-compiler.md §9–12](../02-compiler.md)).
