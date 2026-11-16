# planc, slice 6: classes, inheritance, `.rodata` vtables, destructors, `is`/`as`, and compile-time non-null (`T`) + guarded nullable (`T?`)

Slice 5 gave `planc` a guarded `mmap` arena/slab allocator, atomic reference
counting (`--check-leaks`), dynamic arrays `T[]`, `s1 + s2`, and value `@"..."`
templates. Slice 6 introduces the Vala object model without C or `GType`
(**I1**, **I2**, **I3**, **VL-01**, **RT-03**, **RT-04**): single-inheritance
`class` hierarchies, `abstract`/`virtual`/`override` methods, constructors with
`: base(...)`, destructors `~ClassName()` chained with automatic field cleanup,
type checks/casts (`is`, `as`, `(Class) x`), and hybrid **Option B** null
safety (`T` non-nullable at compile time, flow narrowing on `T?`, and targeted
runtime null guards only on unnarrowed `T?` dereferences).

Requirements demonstrated: **I1**, **I2**, **I3**, **TC-02**, **TC-05**,
**TC-08**, **KR-03**, **KR-05**, **RT-03**, **RT-04**, **VL-01**, **VL-12**.

---

## 1. Unified 16-byte class instance & `.rodata` vtable ABI

Every heap allocation in `planc` keeps the same 16-byte header (`kind = 2` for
class instances, `kind = 1` for ref arrays such as `string[]` / `Class[]`,
`kind = 0` for `string` and scalar arrays):

```
Class instance (allocated via __planc_alloc(payload_bytes, 2)):
  +0    u32   refcount      (>= 1 on heap; 0 during ~dtor helper calls; 0xDEADDEAD on free)
  +4    u8    kind = 2      (identifies class instance in __planc_unref)
  +5    u8    size_class    (0..7 = slab 32B..4096B; 0xff = large mmap)
  +6    u16   magic         (0x504C 'PL')
  +8    u64   vtable*       (pointer to class's static .rodata descriptor)
  +16   ...                 flattened fields: ancestor fields followed by derived fields

Static .rodata vtable (8-byte aligned, relocated by pass 5):
  +0    u64   finalizer*    (__planc_dtor_<Class> in .text if needs_finalizer, else 0)
  +8    u64   parent_vt*    (ancestor .rodata vtable*, or 0 at hierarchy root)
  +16+8k u64  vslot[k]      (virtual/abstract/override implementation pointer in .text)
```

- **Finalization (`__planc_unref`):** when atomic `lock decl [rdi]` drops a
  class instance's `refcount` to `0`, `kind == 2` dispatches to `vtable[0]`
  (`__planc_dtor_<Class>(this)`) while `refcount == 0` (so helper method calls
  on `this` inside `~ClassName()` remain safe), runs user `~Derived()`,
  releases `Derived`'s reference fields in reverse order, chains into
  `__planc_dtor_<Base>(this)`, and finally poisons `[rdi]` with `0xDEADDEAD`
  and returns the slab to `free_lists[class]`.
- **Initialization:** `new Derived(args...)` allocates the instance, installs
  `vtable_Derived` at `[obj + 8]`, runs compiler-synthesized
  `__planc_init_Derived(obj)` (default field initializers + `""` empty strings
  from root to leaf), and invokes `Derived____ctor(obj, args...)` (which chains
  `: base(...)` before `Derived`'s body).

---

## 2. Option B null safety (`T` vs `T?` & `--no-null-check`)

| Construct | Compile-time rule | Runtime cost |
|---|---|---|
| `T` (`Foo`, `string`, `T[]`) | Rejects `null`, uninitialized `Foo x;`, uninitialized non-null `Foo` class fields without ctor assignment, and `Foo? -> Foo` without narrowing | **0 instructions** (guaranteed non-null) |
| Narrowed `T?` (`if (x != null)`, `if (x == null) return;`, `while (x != null)`) | Promotes local/param `x` to non-null `T` along dominated paths (invalidated after subsequent nullable reassignment) | **0 instructions** (`__planc_null_panic` omitted when all nullable uses are narrowed) |
| Unnarrowed `T?` (`node.val`, `arr[i]`, `s.length`, `obj.method()`) | Allowed without boilerplate checks | 2-instruction guard (`test rax, rax; je __planc_null_panic`), exiting `134` on null; opt-out via `--no-null-check` |

---

## 3. OOP surface, dispatch, and RTTI (`is`, `as`, casts)

```
program     := (enum_decl | struct_decl | abstract? 'class' | function | global)*
class_decl  := 'abstract'? 'class' IDENT (':' IDENT)? '{' class_member* '}'
type        := ('int' | 'bool' | 'string' | 'void' | IDENT) ('[]')? ('?')?
expr        := ... ('is' | 'as') IDENT | '(' IDENT '?'? ')' unary | 'new' IDENT '(' args ')'
             | postfix '.' IDENT '(' args ')' | 'this' | 'base' '.' IDENT '(' args ')' | 'null'
```

- **Method dispatch (exact Vala semantics):** non-virtual methods emit direct
  `call Class__method`; `virtual`/`abstract`/`override` methods dispatch through
  `mov rax, [rdi + 8]; call qword ptr [rax + 16 + 8*slot]`; `base.method(...)`
  bypasses the vtable and calls the ancestor's concrete implementation.
- **RTTI & casts:** `__planc_is_instance(void* obj, void* target_vtable)` walks
  the `parent_vt*` chain at `[rdx + 8]` in `.rodata` (returning `0` or `1` in
  `rax`): `x is Sub` yields `bool`, `x as Sub` returns `Sub?`, and `(Sub) x`
  throws `planc: panic: invalid class cast` (`exit 134`) if runtime instance
  validation fails.
- **Class arrays:** `Shape[]` sets `elem_ref = 1`, supports common-ancestor
  inference across literals such as `{ new Rect(3, 4), new Circle(5) }`, and
  recursively releases every contained object when released.

---

## 4. Verification

```sh
./planc/build.sh
./planc/tests/run.sh     # 123 cases, 123 pass, 0 fail
```

- **Valid (55):** all 51 Slice 0–5 tests plus `class_basic`,
  `class_inheritance`, `class_dtor_arc`, and `nullable_narrowing`.
- **Invalid (49):** all 44 Slice 0–5 rejections plus `null_to_non_null`,
  `uninit_non_null_class`, `nullable_to_non_null`, `instantiate_abstract`, and
  `bad_override`.
- **Bounds (6):** `oob_neg`, `oob_pos`, `no_bounds_check`, `array_oob_pos`,
  `array_oob_neg`, `array_neg_size`.
- **Leak checks (`--check-leaks`, 9):** `array_int`, `array_string`,
  `string_concat`, `template_value`, `refcount_loop`, `class_basic`,
  `class_inheritance`, `class_dtor_arc`, and `nullable_narrowing` — all exiting
  cleanly with `alloc_count == free_count` (`stderr` empty).
- **Null safety & cast panics (3):** `null_deref_panic` (`exit 134`,
  `planc: panic: null pointer dereference`), `no_null_check` (`--no-null-check`
  omits `__planc_null_panic`), and `bad_cast_panic` (`exit 134`,
  `planc: panic: invalid class cast`). `nullable_narrowing` also compiles with
  zero `__planc_null_panic` symbols via flow narrowing alone.

Determinism (**TC-05**), segment audit (**KR-03**), `.rodata` vtable inspection,
and GDB backtrace (**TC-08**) on `planc --check-leaks planc/tests/valid/class_inheritance.vala`:

```
$ sha256sum c1 c2
493815a7f183e5161c00b0c2465a034aa8dc372db9a050704215b0731d27f206  c1
493815a7f183e5161c00b0c2465a034aa8dc372db9a050704215b0731d27f206  c2

$ readelf -lW c1
  LOAD  0x0000e8 0x00000000004000e8 ... R E
  LOAD  0x001000 0x0000000000401000 ... R
  LOAD  0x002000 0x0000000000402000 ... RW  (FileSiz 0x0, MemSiz 0x60)

$ gdb -batch -ex 'b Rect__describe' -ex 'run' -ex 'bt' c1
#0  0x0000000000400674 in Rect__describe ()
#1  0x00000000004002de in main ()
```
