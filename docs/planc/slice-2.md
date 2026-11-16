# planc, slice 2: stack arguments and globals

Slice 1 gave the project its calling convention for the six register
arguments. Slice 2 closes the two gaps that convention had and that
[slice-1.md §8](slice-1.md) left explicitly open: **more than six arguments
(stack arguments)** and **global variables (.data/.bss)**. The writable
segment also exercises W^X (KR-03) against a real ELF for the first time:
three segments now, and the writer must never map one page with two
different permissions.

Requirements demonstrated: still **I1**, **I2**, **TC-02**, **TC-05**,
**TC-08**, **KR-03**, plus the stack-argument half of the ABI in
[01-architecture.md §3.1](../01-architecture.md) (the register half landed
in slice 1).

---

## 1. Language additions

```
global    := 'int' IDENT ('=' '-'? INTEGER)? ';'
```

- Global variables live at program level, share **one namespace with
  functions** (a duplicate name is an error, not a shadow), and are visible
  everywhere — declared before or after use, since registration happens
  before code generation.
- A local with the same name **shadows** the global. This is a deliberate
  slice decision; duplicate locals remain an error.
- The initializer must be an **integer literal, optionally negated**. There
  is no constant folding yet, and run-time global initialization would need
  startup code before `main` — that is the runtime's job (slice 3), not a
  global's.
- `int x;` at program level is a zero-initialized global: it lives in `.bss`
  and starts at zero.

## 2. Stack arguments

With `n` arguments, the first `r = min(n, 6)` travel in the argument
registers and the remaining `s = n - r` go on the stack:

**Caller.** Arguments are evaluated left to right (VL-12), and their final
resting places are decided up front:

1. Reserve the outgoing area: `sub rsp, area` with
   `area = align16(8*s) + (depth odd ? 8 : 0)`. The extra 8 carries the
   alignment: at the `call`, `rsp` must be 16-byte aligned, and since pushes
   and pops cancel in pairs, only the statically known live-push depth
   decides the parity. When `s == 0` this degenerates to slice 1's pad
   applied after the register pops.
2. Register arguments are pushed as they are evaluated; stack arguments are
   stored directly into the area (`mov [rsp + 8*i], rax`), above the
   register pushes. With `r` pushes live, argument `i ≥ r` written at
   `rsp + 8*i` lands exactly at `area_base + 8*(i-r)`.
3. The register arguments are popped in reverse into `rdi…r9`.
4. `call`, then `add rsp, area`.

After the pops, `rsp` points at the first stack argument — which is exactly
where the callee expects it.

**Callee.** Stack argument `j ≥ 6` arrives at `[rsp + 8 + 8*(j-6)]` at
entry, i.e. `[rbp + 16 + 8*(j-6)]` after the frame is opened. The prologue
**copies** it into its own slot. That copy is not optional bookkeeping: in
Vala a parameter is a local copy, and a callee that wrote through
`[rbp+16]` would be mutating the caller's outgoing area — the test
`stack_args_write` (a callee that assigns to its stack parameters, called
twice) is what keeps that property honest.

## 3. Globals: the third segment

| Section | Content | Representation |
|---|---|---|
| `.data` | initialized globals | 8 bytes little-endian per global, written at compile time |
| `.bss` | zero-initialized globals | `SHT_NOBITS`, no file bytes; `p_memsz > p_filesz` on the segment |

The image now has three `PT_LOAD` segments: R|X (headers + `.text`), R
(`.rodata`), RW (`.data` in the file, `.bss` only in memory). `.bss` occupies
no file bytes; the loader zero-fills the tail of the segment.

Globals are reached with rip-relative loads and stores
(`48 8B 05` / `48 89 05` + disp32), which extends the slice-0 relocation
mechanism with a **target space**: the same `RipPatch` now names whether its
target lives in `.rodata`, `.data` or `.bss` (the latter resolved as
`data_vaddr + data_size + offset`). Nothing else changes: the resolution is
still one pass after the final layout, still range-checked against int32.

### The page-sharing bug, caught by inspection not by tests

The first layout set `data_offset = align_up(rodata_offset + rodata_size,
PAGE_SIZE)`, which is correct whenever `.rodata` is non-empty and wrong when
it is empty: the RW segment then starts at the same page the R segment
already maps — one page mapped with two different permission sets. The
correction is the rule stated in the section title: **each segment begins on
the page after the last byte of the previous one** (an empty `.rodata` still
owns its page). The test suite cannot see this failure mode on Linux, which
silently tolerates the overlap — a fixed layout rule beats a test that
cannot fail.

## 4. Verification

```sh
./planc/build.sh
./planc/tests/run.sh     # 53 cases, 53 pass
```

- **Valid (30):** the 25 slice-1 cases plus `stack_args` (8 arguments),
  `stack_args_expr` (stack arguments evaluated under nested calls and an odd
  live-push depth), `stack_args_write` (assignment to stack parameters,
  called twice), `globals` (initialized, mutated across calls),
  `globals_bss` (zero-filled), `globals_order` (VL-12 made observable: a
  global accumulator records the argument evaluation order, `1, 2, 3` →
  123), `mixed_args` (9 arguments plus a global), `global_shadow`
  (local shadows global; the other function still reads the global).
  Segment checks are updated: exactly **3** `PT_LOAD`, still no RWX.
- **Invalid (23):** the slice-1 cases plus `global_init_not_literal`,
  `duplicate_global`, `global_function_conflict` (one namespace),
  `duplicate_param`. `too_many_args` was **retired**: more than six
  arguments is now supported, not rejected.

Determinism and the invariant audit, measured on a program with a global,
a `.bss` variable and a nine-argument call:

```
$ sha256sum s2 s2b        # compiled twice
2598d208…  s2
2598d208…  s2b
$ readelf -lW s2 | grep LOAD
LOAD 0x0000e8 0x4000e8 … R E    ← headers + .text
LOAD 0x001000 0x401000 … R      ← .rodata
LOAD 0x002000 0x402000 … RW     ← .data (8 bytes) + .bss (8 bytes)
$ nm -u s2 | wc -l
0
```

The callee side disassembles exactly as specified:

```
400108: 48 8b 45 10     mov  0x10(%rbp),%rax   ; 7th argument arrives here
40010c: 48 89 45 c8     mov  %rax,-0x38(%rbp)  ; copied into its own slot
```

## 5. Vala constraints hit while writing this

- Nothing new in the language this slice. The two mistakes were our own:
  the page-sharing layout rule above, and a first `gen_call` that computed
  the alignment pad from `depth + args` (slice 1) — the stack-argument path
  forced the correct formulation: the pad depends only on the **live push
  depth**, because the area's own size is what must absorb the parity.

## 6. What slice 2 deliberately does not do

| Missing | Consequence | Where it is specified |
|---|---|---|
| Non-literal global initializers | rejected at parse time | startup code belongs to the runtime ([03-runtime-and-stdlib.md](../03-runtime-and-stdlib.md)) |
| `bool`, arrays, strings as values | `int` still the only type | [01-architecture.md §3.2](../01-architecture.md) |
| Register allocation | every access is still memory | [02-compiler.md](../02-compiler.md) |
| Relocatable objects, linker | single translation unit | [02-compiler.md](../02-compiler.md) |
| DWARF | gdb sees functions, not lines | [02-compiler.md](../02-compiler.md) |
| `[AsmBody]`, SPIR-V target | the second backend exists as design (TC-11) only | [02-compiler.md §10.4](../02-compiler.md) |
| Self-hosting | still built by `valac` (stage 0) | [06-verification.md](../06-verification.md) |

Next: the language grows its first reference type — `string` variables with
the runtime's header `{ refcount, bytes… }` — or the compiler grows the
register allocator. Both are open; strings unblock printing computed values,
which every later test suite wants.
