# planc, slice 9: generics, interfaces, delegates/closures, and self-hosting extensions

Slice 9 completes the polymorphic type system and closure/constructor ergonomics
needed to prepare `planc` for self-hosting (**I1**, **I2**, **I3**, **TC-02**,
**TC-05**, **TC-09**, **KR-03**, **VL-01**, **VL-12**, **VL-13**, **VL-14**,
**VL-15**, **RT-03**, **RT-04**): compile-time monomorphized generics and
built-in `GenericArray<T>`, `.rodata` interface `itable` dispatch (`VL-01`),
16-byte `{ #code, #env }` delegates with ARC-managed closures (`VL-13`), named
constructors and `: this(...)` chaining, default parameter values, scalar
integer casts, and `main(string[] args)`.

Requirements demonstrated: **I1**, **I2**, **I3**, **TC-02**, **TC-05**,
**TC-09**, **KR-03**, **VL-01**, **VL-12**, **VL-13**, **VL-14**, **VL-15**,
**RT-03**, **RT-04**.

---

## 1. Generics & compile-time monomorphization (Decision 1 — Opción A, `VL-15`)

- **Template specialization (`Program.request_instantiation` / `Program.monomorphize_all`):**
  - Generic `class` and `struct` declarations (`Box<T>`, `Pair<K, V>`, `Span<T>`)
    are marked as templates (`is_generic_template = true`) and skipped during
    raw vtable/function codegen.
  - Each concrete type argument list encountered across declarations, nested
    generic types (`Box<Pair<int, string>>`), constructors, literals, casts, and
    type arguments is cloned into a mangled concrete type (`Box__int`,
    `Pair__int__string`, `Span__string`) with type parameters substituted
    throughout fields, properties, constructors, methods, and destructors.
- **Built-in `GenericArray<T>` (`Program.synthesize_generic_array`):**
  - Monomorphized per element type (`GenericArray__int`, `GenericArray__string`)
    with backing `.data` (`T[]`), `.length` (`int`), doubling `.add(T)` growth,
    bounds-checked `ga[i]` reads and assignments (`+=`/`-=`/`=` with ARC balance
    on reference elements), and retained `foreach (var x in ga)` iteration.

---

## 2. Interfaces & `.rodata` `itable` dispatch (Decision 2 — Opción B, `VL-01`)

- **Object representation:** Interface-typed variables, parameters, return
  values, fields, and `IFoo[]` arrays carry the standard 8-byte `obj_ptr`
  (`ValaType.INTERFACE`), keeping ARC, `out`/`ref`, and Option B nullability
  (`IFoo` vs `IFoo?`) uniform with `Class` references.
- **`.rodata` vtable & `itable` layout:**
  - Every concrete `class` emits its `.rodata` vtable with fixed header slots
    `[ +0 finalizer_ptr, +8 parent_vtable, +16 itable_ptr, +24+8k methods ]`.
  - Classes implementing interfaces emit one method-table (`mtable`) per
    transitive interface (`iface_id` assigned per `InterfaceDecl`, covering
    prerequisite interfaces and interface default method bodies when not
    overridden by the class) and a zero-terminated `.rodata` `itable` of
    `(uint64 iface_id, uint64 mtable_ptr)` pairs referenced from `vtable + 16`.
- **Constant-register lookup & casts:**
  - Interface method calls invoke `__planc_iface_lookup` (`rdi = obj_ptr`,
    `rax = iface_id`) which walks `itable` using only `r10`, `r11`, and `rax`
    (preserving `rdi`–`r9` call arguments) and calls `[rax + 8 * iface_slot]`.
  - Compile-time verification rejects classes that omit required interface
    methods or mismatch signatures/throws domains (`unimplemented_interface_method`);
    `is`, `as`, and checked `(IFoo)` / `(Class)` casts validate interface and
    class ancestry uniformly.

---

## 3. Delegates, lambdas, and closures (Decision 3 — Opción A, `VL-13`)

- **16-byte `{ #code, #env }` representation:**
  - `delegate` declarations register a 2-slot value struct (`is_delegate = true`)
    holding 8-byte function pointer `#code` and an ARC-managed `"string?"`
    closure pointer `#env`.
- **Uniform target calling convention:**
  - Every callable stored into a delegate (`d(args...)`) is entered as
    `(void* #env, user_args...)`:
    - **Free functions & `static` methods:** wrapped by synthesized zero-cost
      pass-through thunks (`__planc_delthunk_N`) that shift user arguments over
      and jump/tail-call with `#env = 0`.
    - **Bound instance methods (`obj.method`):** bind `#code = method_sym` (or
      vtable dispatch) and `#env = __planc_ref(obj)`.
    - **Non-capturing lambdas (`x => ...`, `(a, b) => { ... }`):** compile as
      `__planc_lambda_N` with `#env = 0`.
    - **Capturing closures:** allocate `8 * n_cap` payload bytes via
      `__planc_alloc(bytes, 1)` (`kind = 1`), placing reference-typed captures
      first and setting `[env + 8] = ref_cap_count` so `__planc_unref`
      automatically releases captured `string`, `Class`, `T[]`, `Error`, and
      `Interface` values when the closure environment's refcount hits zero.
  - Copy, return (`struct_ret_bss_offset`), reassignment (ref-source-before-unref
    for self-assignment safety), and `out`/`ref` delegate updates preserve ARC
    balance under `--check-leaks`.

---

## 4. Self-hosting extensions (`TC-09`)

- **Named constructors & constructor chaining:** Supports `public Cls.named(...)`,
  `new Cls.named(...)` (including generic classes `new Cls<T>.named(...)`), and
  `: this(...)` / `: this.named(...)` initializer chains.
- **Default parameter values:** Evaluates and binds trailing parameter defaults on
  functions, instance/static methods, and constructors at call sites.
- **Scalar integer casts & `main(string[] args)`:** Supports explicit scalar
  narrowing/sign casts (`(uint8)`, `(int8)`, etc.) and optional `string[] args`
  parameter on `main`, built on entry in `_start` by `__planc_build_args(argc, argv)`
  and unreffed cleanly before exit.

---

## 5. Verification

`/home/djmbdv/PlanetOS/planc/tests/run.sh`: **155 cases, 155 pass, 0 fail**
(68 valid including `generics_and_array`, `interfaces`,
`delegates_and_lambdas`, and `named_ctors_defaults_args`; 54 invalid including
`unimplemented_interface_method`; 8 bounds; 21 `--check-leaks` runs covering all
4 new single-file valid tests with empty `stderr`; 3 null/cast checks; 1
multifile test).

Determinism (**TC-05**), W^X segments (**KR-03**), and zero external symbols
(**I2**) on `planc --check-leaks planc/tests/valid/delegates_and_lambdas.vala`:

```
$ sha256sum del1 del2
28033f1ab817328d0f4702c7fb00e65ecbb68f0224259211597a4bcddbf2492b  del1   (13920 bytes)
28033f1ab817328d0f4702c7fb00e65ecbb68f0224259211597a4bcddbf2492b  del2   (13920 bytes)

$ readelf -lW del1
  LOAD  0x0000e8 0x00000000004000e8 ... 0x001833 0x001833 R E
  LOAD  0x002000 0x0000000000402000 ... 0x00029c 0x00029c R
  LOAD  0x003000 0x0000000000403000 ... 0x000000 0x000070 RW

$ nm -u del1
(empty)
```
