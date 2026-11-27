# The Plan Language (`.plan` / `.vala`)

**Plan** is a systems-oriented evolution of Vala compiled directly by `planc` to native x86-64 machine code (Linux ELF64, PlanetOS ELF, Windows PE32+ `.exe`, and SPIR-V). All Plan extensions are designed to preserve **stage-0 bootstrap compatibility with `valac`** via Vala-compatible syntax (`requires`, `ensures`, `unowned`), attributes (`[...]`), and the preprocessor symbol `PLANC`.

---

## 1. `.plan` File Extension & Stage-0 Compatibility

### Source Extensions
`planc` accepts both **`.plan`** and **`.vala`** source files interchangeably:
```sh
planc --target=windows -O2 app.plan -o app.exe
planc -O2 module.plan helper.vala -o app
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

## 4. `c2vala` Integration (`--plan`)

The `tools/c2vala` C-to-Vala translator supports emitting Plan code via `--plan` or a `.plan` output filename:
```sh
c2vala input.c --plan -o output.plan
planc --target=windows -O2 output.plan -o output.exe
```
When `plan_mode` is active, `c2vala` annotates translated C functions with `[Wrap]` to preserve C modular integer semantics cleanly under `planc`.

---

## 5. Summary of Targets

| Target Flag | Output Format | Runtime / Imports |
|---|---|---|
| *(default)* | Linux x86-64 ELF64 | Direct Linux syscalls (no libc) |
| `--target=windows` | Windows x86-64 PE32+ `.exe` | `KERNEL32.dll` (`ExitProcess`, `GetStdHandle`, `WriteFile`, `VirtualAlloc`) |
| `--target=planetos` | PlanetOS x86-64 ELF | PlanetOS syscalls / `.dlib` imports |
| `--target=spirv` | SPIR-V shader binary | Vulkan / Venus compatible |
