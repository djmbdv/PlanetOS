# planc, slice 4: 16-byte string ABI, bounds checking, `bool`, `for`, bitwise ops, `enum`, and `struct`

Slice 3 gave `planc` its first static type checker (`int`, `string`, `void`,
`var`), `.rodata` string headers, `R_X86_64_64` relocations for string globals,
and `@"..."` template formatting. Slice 4 upgrades the `string` ABI header to
16 bytes for $O(1)$ `.length` and bounds-checked byte indexing (`s[i]`), and
extends the language with `bool`, `for`/`break`/`continue`, `+=`/`-=`/`++`/`--`,
bitwise operators, `enum`, and value-semantics `struct`s.

Requirements demonstrated: **I1**, **I2**, **TC-02**, **TC-05**, **TC-08**,
**KR-03**, **VL-11**, plus the updated 16-byte `string` layout in
[01-architecture.md §3.2](../01-architecture.md) and
[03-runtime-and-stdlib.md §3.1](../03-runtime-and-stdlib.md).

---

## 1. Language and type additions

```
program     := (enum_decl | struct_decl | function | global)*
enum_decl   := ('public'|'private'|'internal')? 'enum' IDENT '{' enum_members '}'
struct_decl := ('public'|'private'|'internal')? 'struct' IDENT '{' field* '}'
type        := 'int' | 'bool' | 'string' | 'void' | IDENT
statement   := ...
             | 'for' '(' simple_stmt? ';' expr? ';' simple_stmt? ')' stmt
             | 'break' ';'
             | 'continue' ';'
             | simple_stmt ';'
expr        := lor -> land -> bor ('|') -> bxor ('^') -> band ('&')
             -> cmp -> shift ('<<'|'>>') -> add -> mul -> unary ('-'|'!'|'~')
             -> postfix ('.' IDENT | '[' expr ']')* -> primary
```

- **Gradual `bool` compatibility:** `bool` (`true`, `false`) is a distinct type,
  and comparisons (`<`, `<=`, `>`, `>=`, `==`, `!=`), `!`, `&&`, and `||` yield
  `bool`. To keep existing code and the Slices 1–3 tests compatible, `int` and
  `bool` are mutually accepted in conditions (`if`/`while`/`for`), assignments,
  arithmetic, and returns, while `print(@"$b")` formats `bool` values as
  `"true"` or `"false"`.
- **Block and `for`-loop scoping:** Blocks (`{ ... }`) and `for` headers open a
  lexical scope whose variables are deactivated when the block/loop ends,
  allowing consecutive `for (int i = 0; ...)` loops while still rejecting
  shadowing of active outer-scope variables (`shadow_outer_var.vala`), matching
  `valac`.
- **Loop control & compound ops:** `for` (`continue` jumps to the `step` clause,
  `break` exits the loop), `while` `break`/`continue`, `+=`, `-=`, `++`, `--`,
  and bitwise operators `&`, `|`, `^`, `~`, `<<`, `>>` (signed arithmetic right
  shift `sar`).
- **`enum`:** Auto-incrementing and explicit signed integer literals (`Enum.MEMBER`),
  strictly typed per `enum` name, formatted as integers in `print(@"...")`.
- **`struct` (value semantics):** Supports `struct` declarations (including
  nested `struct`s, `string` fields, `bool`, `enum`, and cycle rejection),
  `Struct() { field = expr, ... }` literals, dot-field reads and writes
  (`b.origin.x += 2`, `b.origin.y++`), global `struct`s (`.bss` for scalar-only
  structs, `.data` with `R_X86_64_64` `""` initialization when containing `string`
  fields), and value-copy semantics across assignments, parameters, and returns.

## 2. 16-byte `string` ABI header ($O(1)$ `.length` and fast `==`)

To avoid $O(N^2)$ scans in loops such as `while (pos < source.length)` (which
the compiler itself uses in [lexer.vala](../../planc/src/lexer.vala)) and to
align `string` headers with `T[]`, Slice 4 places `length` in the header:

```
offset  size  field
+0      4     refcount (uint32 = 0 for static .rodata strings)
+4      4     hash     (uint32 = 0, uncomputed)
+8      8     length   (uint64, UTF-8 byte count)
+16     N+1   UTF-8 bytes followed by 0x00 trailing NUL
```

Consequences in code generation:
- `s.length` lowers inline to `mov rax, [rax + 8]` (`48 8B 40 08`, $O(1)$),
  removing the `__planc_str_len` helper entirely.
- `__planc_write_str` loads `rdx = [rdi + 8]` and `rsi = rdi + 16` directly and
  issues `write(1, rsi, rdx)` as a leaf routine.
- `__planc_str_eq` checks pointer identity (`cmp rdi, rsi`), then rejects length
  mismatches in $O(1)$ (`mov r8, [rdi + 8]; cmp r8, [rsi + 8]; jne .false`)
  before scanning `0 .. r8 - 1` at `[ptr + rcx + 16]`, which also keeps embedded
  NUL bytes safe from premature truncation.

## 3. Bounds-checked string indexing (`s[i]`) and `--no-bounds-check`

String byte indexing `s[i]` reads `[rax + rcx + 16]` (`movzx eax, byte ptr
[rax + rcx + 16]`) as an `int` (`0..255`).

By default, every `s[i]` emits a single unsigned range check covering both
negative (`i < 0`, large unsigned values) and `i >= length`:

```
cmp  rcx, [rax + 8]           ; 48 3B 48 08
jae  __planc_bounds_panic     ; 0F 83 rel32
```

On out-of-bounds access, `__planc_bounds_panic` writes
`"planc: panic: index out of bounds\n"` to `stderr` (`fd = 2`) and terminates
via `exit(134)`. Passing `--no-bounds-check` to `planc` omits both the per-site
check and `__planc_bounds_panic`.

## 4. Struct frame partitioning and return passing

Each function frame is partitioned into three disjoint slot regions calculated
by `prepare_function()` before emitting the prologue:

```
[0 .. after_params)           incoming param spill slots + struct value copies
[after_params .. var_end)     local variables (scalars = 1 slot, structs = N)
[var_end .. total_slots)      temporaries for StructLiteral & CallExpr returns
```

- **Parameters:** All incoming arguments (`rdi..r9` + stack) are first spilled
  into raw slots before any `struct` copy runs, ensuring `copy_struct_rax_to_rcx`
  (`rcx`/`rdx`) never clobbers live argument registers. Each `struct` parameter
  is then copied into its own `N`-slot local block so mutating it in the callee
  never mutates the caller.
- **Struct returns:** A function returning a `struct` copies the result into a
  shared `.bss` scratch buffer, and every `CallExpr` returning a `struct`
  immediately copies from that buffer into its dedicated caller-side `temp_slot`,
  keeping expressions such as `add_points(make_point(1, 2), make_point(5, 6))`
  and recursive struct calls free of aliasing.

## 5. Verification

```sh
./planc/build.sh
./planc/tests/run.sh     # 90 cases, 90 pass
```

- **Valid (47):** all 41 slice-3 cases plus `bool_type`, `for_break_continue`,
  `bitwise`, `enum_type`, `struct_type`, and `string_index`.
- **Invalid (40):** all 31 slice-3 cases plus `break_outside_loop`,
  `continue_outside_loop`, `index_on_int`, `index_non_int`,
  `unknown_enum_member`, `unknown_struct_field`, `struct_field_type_mismatch`,
  `cyclic_struct`, and `shadow_outer_var`.
- **Bounds checks (3):** `oob_pos` (`s[3]` on `"abc"`) and `oob_neg` (`s[-1]`)
  both abort with exit `134` and `"planc: panic: index out of bounds"` on
  `stderr`; `string_index` compiled with `--no-bounds-check` omits
  `__planc_bounds_panic` and exits `40` with expected stdout.

Determinism (**TC-05**), segment audit (**KR-03**), and GDB backtrace (**TC-08**)
on `struct_type.vala`:

```
$ sha256sum s4_st1 s4_st2
f76e9c8da5d3499347aefcff99b896ab870e28a4f14465fa3395e732bdfc1e82  s4_st1
f76e9c8da5d3499347aefcff99b896ab870e28a4f14465fa3395e732bdfc1e82  s4_st2

$ readelf -lW s4_st1 | grep LOAD
  LOAD  0x0000e8 0x00000000004000e8 ... R E
  LOAD  0x001000 0x0000000000401000 ... R
  LOAD  0x002000 0x0000000000402000 ... RW   ← .data (0x20) + .bss (0x20)

$ gdb -batch -ex 'break add_points' -ex run -ex bt s4_st1
#0  0x000000000040015b in add_points ()
#1  0x000000000040036a in main ()
```

## 6. What slice 4 deliberately does not do

| Missing | Consequence | Where it is specified |
|---|---|---|
| Heap allocator, refcounting, dynamic `T[]`, string `+`, dynamic `@"..."` values | No heap allocation yet; templates with expressions are restricted to `print(...)` | [03-runtime-and-stdlib.md](../03-runtime-and-stdlib.md) |
| `switch`, `do`, `foreach`, `class`, `interface`, `throws`, `async` | Value types (`int`, `bool`, `string`, `enum`, `struct`) only | [02-compiler.md](../02-compiler.md) |
| Register allocation / SSA IR | Frame-pointer stack slots (`[rbp - 8*(slot+1)]`) | [02-compiler.md](../02-compiler.md) |
| Relocatable `ET_REL` objects, linker | Single translation unit only | [02-compiler.md](../02-compiler.md) |
| DWARF line/variable tables | GDB sees functions/frames, not source lines/locals | [02-compiler.md](../02-compiler.md) |
| `[AsmBody]`, SPIR-V target | Specified in design only | [02-compiler.md](../02-compiler.md) |
| Self-hosting | Stage 0 still compiled by `valac` | [06-verification.md](../06-verification.md) |

Next (Slice 5): minimal runtime allocator (`mmap`/`brk` on host, interface-aligned
for `planetrt`), dynamic arrays `T[]` (`{ refcount, pad, length, elements... }`),
reference-counted string concatenation (`+`), and value-producing `@"..."`
templates.
