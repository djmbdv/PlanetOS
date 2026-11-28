# The Plan Language (`.plan` / `.vala`)

**Plan** is the primary systems-oriented language of PlanetOS, evolved from Vala and compiled directly by `planc` to native x86-64 machine code (Linux ELF64, PlanetOS ELF, Windows PE32+ `.exe`) and Vulkan SPIR-V. Stage-0 bootstrap compatibility with `valac` is preserved through `tools/plan2vala` (`.plan` -> `.vala`), Vala-compatible attributes (`[...]`), and the preprocessor symbol `PLANC`.

---

## 1. `.plan` File Extension & Stage-0 Translation (`plan2vala`)

### Source Extensions
`.plan` is the canonical extension for Plan source files; `planc` accepts both **`.plan`** and **`.vala`** source files interchangeably:
```sh
planc --target=windows -O2 app.plan -o app.exe
planc -O2 module.plan helper.vala -o app
```

### Stage-0 Translator (`tools/plan2vala`)
`plan2vala` translates Plan-specific syntax (`loop`, `loop (n)`, `inverse_foreach`, `view<T>`, `[Packed]`, etc.) into standard Vala backed by `tools/plan2vala/plan_stage0_rt.vala`, allowing Stage-0 bootstrap builds with `valac`:
```sh
plan2vala app.plan -o app.stage0.vala
```

### Automatic `PLANC` Preprocessor Symbol
`planc` automatically defines `PLANC` in its preprocessor. Shared code that must compile cleanly under both `valac` (stage 0) and `planc` can guard Plan-specific blocks or attributes with `#if PLANC`:
```vala
#if PLANC
[NoAlloc]
[AlwaysInline]
#endif
int fast_add (int a, int b) {
    return a + b;
}
```
> **Tip:** `valac` ignores unknown attributes, though it emits an `Attribute '...' never used` warning unless guarded with `#if PLANC` when compiling shared stage-0 sources.

### Stage-0 Compatibility Helpers (`planc/stage0/plan_compat.vala`)
[plan_compat.vala](file:///c:/Users/Lenovo/PlanetOS/planc/stage0/plan_compat.vala) provides `Planc.PlanMath` fallback helpers (`wrapping_add_u32`, `wrapping_sub_u32`, `wrapping_mul_u32`, `wrapping_add_i64`, `wrapping_sub_i64`, `wrapping_mul_i64`) so stage-0 builds with `valac` match modular arithmetic semantics.

---

## 2. Static Safety Features

### `[NoAlloc]` — Transitive Heap-Allocation Verification
Functions or methods marked `[NoAlloc]` are statically verified across the call graph to perform **zero heap allocations** (no `new` class/array allocations, array literals, `SliceExpr`, dynamic `TemplateExpr`, or `string` concatenation). Integer `+` is distinguished from `string` concatenation.
```vala
[NoAlloc]
int sum_pair (int a, int b) {
    return a + b; // OK
}

[NoAlloc]
int bad_fn () {
    int[] tmp = new int[4]; // Semantic error: [NoAlloc] function 'bad_fn' allocates on the heap
    return tmp.length;
}
```
If a `[NoAlloc]` function calls any helper that allocates on the heap, `planc` rejects it at compile time.

### Exhaustive `enum` `switch` Checking
When a `switch` statement inspects an `enum` without a `default:` branch, `planc` verifies that every enum member is handled and emits a compiler warning for any missing member:
```vala
enum Mode { FAST, SAFE }

int check (Mode m) {
    switch (m) {
        case Mode.FAST: return 1;
        // Warning: non-exhaustive switch on enum 'Mode', missing 'SAFE'
    }
    return 0;
}
```

### Pattern Matching `is` with Variable Binding
`is` supports an optional binding identifier that introduces a non-null, narrowed `unowned` variable scoped to the `then` branch—eliminating redundant runtime casts and atomic refcount operations:
```vala
int read_legs (in Animal a) {
    if (a is Dog d) {
        // `d` is typed as non-null `Dog` here
        return d.legs + d.bark;
    }
    return a.legs;
}
```

### Per-Function Overflow Control (`[CheckedOverflow]` / `[Wrap]`)
Override the global `--check-overflow` flag on a per-function basis:
- **`[CheckedOverflow]`**: enables signed integer overflow checks (`JO` -> panic) for the annotated function.
- **`[Wrap]`**: disables overflow checks for intentional modular / wrap-around arithmetic (hashes, bitmasks, translated C code) and keeps the `-O2` register-allocating backend (`PuzzleRA`) active even when `--check-overflow` is enabled globally.

```vala
[Wrap]
uint32 hash_step (uint32 x) {
    return x * 2654435761u + 1u;
}
```

---

## 3. Contracts & Zero-Copy Performance Features

### `requires` / `ensures` Contracts Integrated with BCE
`planc` parses `requires (<expr>)` and `ensures (<expr>)` clauses on functions and methods:
```vala
int read_at (int[] arr, int idx)
    requires (idx >= 0 && idx < arr.length)
{
    return arr[idx]; // Bounds check eliminated inside the body
}
```
- **Entry validation**: when bounds checking is enabled, `requires` preconditions are checked once on function entry (in both `-O0` `codegen.vala` and `-O2` `PuzzleRA`).
- **Bounds-Check Elimination (BCE)**: proven invariants of the form `idx >= 0 && idx < arr.length` (when neither `idx` nor `arr` is mutated in the body) are fed into the BCE tables of both `codegen.vala` and `PuzzleRA` (`-O2`), removing redundant per-access bounds checks inside the function.

### `in` Read-Only Borrowing Parameters
Parameters marked `in` borrow their argument as read-only (`is_unowned = true`) without transferring ownership or incrementing/decrementing reference counts:
```vala
int measure (in Animal a) {
    return a.legs;
}
```

### `[AlwaysInline]` & `[Arena]`
- **`[AlwaysInline]`**: raises the multi-statement inlining limit in `opt.vala` from 8 to 32 statements for performance-critical helpers.
- **`[Arena]`**: uses a linear bump-pointer arena allocator for bounded temporary allocations within the function, freed together on exit without per-object atomic refcounting.

---

## 4. Modern Plan Dialect Features

### Optional Semicolons
Statement semicolons (`;`) are optional at end-of-line or before `}`/`EOF` (semicolons remain required inside `for (init; cond; step)` headers):
```plan
int acc = 0
loop (4) {
    acc += 10
}
```

### `loop` and `loop (n)`
- **`loop { ... }`**: infinite loop (contextual keyword — variables/fields named `loop` remain valid).
- **`loop (n) { ... }`**: executes the body `n` times without boilerplate index variables:
```plan
int i = 0
loop {
    i++
    if (i == 3) break
}
loop (4) {
    acc += 10
}
```

### `inverse_foreach`
Iterates in reverse order over arrays, slices, `GenericArray`, and `ArrayList`:
```plan
int[] arr = { 1, 2, 3, 4 }
inverse_foreach (var v in arr) {
    // visits 4, 3, 2, 1
}
```

### Tuples & Destructuring
Functions can return tuples `(T1, T2, ...)` and callers can unpack them with `var (a, b) = ...`:
```plan
(int, string) pair_fn (int x) {
    return (x * 2, "ok")
}
var (dv, ds) = pair_fn (21)
```

### `view<T>` & Zero-Copy Slices
- **`arr[start:end]`**: zero-copy array slice expression.
- **`view<T>`** (`GLib.View<T>`): generic zero-copy array view supporting `vw[i]` indexing and `.slice (start, end)`:
```plan
view<int> vw = new view<int> (arr, 1, 3)
int sum = vw[0] + vw[1] + vw[2]
```

### `defer` and `errdefer`
- **`defer <stmt>`**: executes in LIFO order when leaving the enclosing block or returning.
- **`errdefer <stmt>`**: allowed only inside throwing (`!`) functions; runs in LIFO order only when exiting via an error (`throws` / propagated error):
```plan
int fail_fn! (int fail) {
    int state = 0
    defer state += 1
    errdefer state += 10
    if (fail != 0) throws -42
    return 77
}
```

### Lightweight `!` Errors
Functions marked with `!` return an `int` error code in `rdx` with zero heap allocation, using `throws <code>` and `try { ... } catch (int e) { ... }` (or bare `catch { ... }`):
```plan
int err = 0
try {
    int ok = fail_fn! (1)
} catch (int e) {
    err = e // -42
}
```

### `[Packed]` Struct Layout
`[Packed]` lays out struct fields with natural byte packing (`uint8` = 1, `uint16` = 2, `uint32`/`float` = 4, `int`/`uint64`/refs = 8) without 8-byte slot padding, reflected in `sizeof(...)`, struct literals, reads, and writes:
```plan
[Packed]
struct PackedHdr {
    public uint8 magic
    public uint16 kind
    public uint32 size
} // sizeof (PackedHdr) == 7
```

### Portable SIMD Vectors (`Simd`)
`GLib`/`Simd` provides 4-lane portable vectors `Simd.u32x4`, `Simd.i32x4`, and `Simd.f32x4` with `splat`, `make`, `add`, `sub`, `mul`, `bit_and`/`bit_or`/`bit_xor`, and `dot`:
```plan
using Simd
var va = u32x4.splat (10u)
var vb = u32x4.make (1u, 2u, 3u, 4u)
var vc = va.add (vb)
var fa = f32x4 () { x = 1.0f, y = 2.0f, z = 3.0f, w = 4.0f }
float dp = fa.dot (fa) // 30.0f
```

---

## 5. `c2plan` Integration (C -> Plan)

The `tools/c2plan` C-to-Plan translator emits Plan code by default (`.plan` output, `[Wrap]` on translated functions, `loop`/`loop (n)`/`inverse_foreach` optimizations, and optional semicolons), and supports `--vala` for legacy `.vala` compatibility output:
```sh
c2plan input.c -o output.plan
planc --target=windows -O2 output.plan -o output.exe
```

---

## 6. Summary of Targets

| Target Flag | Output Format | Runtime / Imports |
|---|---|---|
| *(default)* | Linux x86-64 ELF64 | Direct Linux syscalls (no libc) |
| `--target=windows` | Windows x86-64 PE32+ `.exe` | `KERNEL32.dll` (`ExitProcess`, `GetStdHandle`, `WriteFile`, `VirtualAlloc`) |
| `--target=planetos` | PlanetOS x86-64 ELF | PlanetOS syscalls / `.dlib` imports |
| `--target=spirv` | SPIR-V shader binary | Vulkan / Venus compatible |
