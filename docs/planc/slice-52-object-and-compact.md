# Slice 52 — `Object` as universal root and `[Compact]` as manual memory

Two constructs, one layout problem. `Object` needs every class to share a root;
`[Compact]` needs some classes to opt **out** of the object machinery entirely.
They are in the same slice because both are decided by `has_weak_slot ()` and
`class_field_base ()` in `codegen.vala`: the two functions that answer "where do
the fields start?".

Everything here was measured against `valac` 0.56.19 before being implemented.

## 1. What `Object` means now

`Object` is synthesized into the program by the `Program` constructor, before
parsing, with `is_defined = true`. It has no fields, no methods, no vtable entry
beyond the finalizer, and it is the implicit base of every class that does not
declare one (except `[Compact]` classes, which have no base by definition).

| Question | Before | Now |
|---|---|---|
| `Alpha a; Object o = a;` | error: unrelated types | accepted, `Alpha` derives from `Object` |
| `if (x is Object)` | worked only against the declared hierarchy | true for every non-`null` instance |
| `Object[] all = new Object[2]` | array of a type no class could produce | holds any instance |
| `(Object) a`, `a == o` | — | identity, no conversion code |

**The layout does not change.** Every root class already reserved field slot 0 for
the weak-reference box, so a class that now derives from `Object` keeps exactly the
same offsets: what the base adds is type identity in the parser, not bytes in the
instance. `is_bare_object ()` skips the `__planc_init_Object` call for the
synthesized class itself, and its finalizer is kept because it is the one that
calls `__planc_weak_clear`.

Two internal heap types are excluded from the root (`GenericArray__*`,
`Channel__*`): their runtime accesses `data` at `+16` and `length` at `+24` with
literal offsets in twelve places, and they must not inherit the weak slot.

### Measured divergence from `valac`

`valac` only allows `Object o = instance` when the class **declares** `: Object`;
a plain `class Alpha { }` is not a GObject and the assignment is an error. `planc`
makes the base implicit, so the same program is accepted. Compiling the test
program with the explicit bases under `valac` produces **byte-identical stdout**, so
the semantics of `is`, `as`, `==`, `Object[]` and interface checks through an
`Object` value are the same ones Vala implements.

### Cost

| Measure | Result |
|---|---|
| Instance layout | unchanged: `[+0 refcount] [+8 vtable] [+16 fields]`, weak slot already present |
| Emitted code for a plain class | unchanged apart from the class's own `Object` init function, which is not called |
| Runtime, 20 million `new` + release of a 2-field class: baseline vs this slice | 0.97 s vs 1.01 s user CPU — inside run-to-run noise |
| Compiler, 10 self-compiles | 16.4 s user CPU (15.4 s at slice 51, with smaller sources) |

## 2. What `[Compact]` means now

Before this slice the attribute was parsed and discarded. It is now a real
allocation and lifetime policy:

| Aspect | Normal class | `[Compact]` |
|---|---|---|
| instance header | refcount word, vtable pointer, then fields | allocator word, then fields |
| fields start at | `+16` | `+8` |
| reference counting | `__planc_ref` / `__planc_unref` | none: `__planc_ref`/`__planc_unref` return immediately (tag 3) |
| virtual dispatch | vtable | **no vtable** |
| `is` / `as` / cast | walk the vtable chain | rejected at compile time |
| destruction | automatic at refcount 0 | explicit `free ()` |
| weak references | slot 0 of the field block | not available |

### Layout, measured on the emitted machine code

A class with three `int` fields, compiled with the same compiler:

| Kind | `mov rdi, imm` before `__planc_alloc` | block handed to the caller |
|---|---|---|
| normal | `32` (weak slot + 3 fields) | 48 bytes |
| `[Compact]` | `16` (3 fields, minus the allocator word) | 32 bytes |

**16 bytes less per instance, 33 % less for a small object**: the allocator word
(8) and the vtable pointer (8) are the whole difference, and the weak slot
disappears with them. The saving is a constant per instance, so it matters most
exactly where memory is tight: many small objects.

### `free ()`

`free ()` is **synthesized** for every `[Compact]` class that does not declare its
own method with that name. It releases every reference-typed field, then calls
`__planc_compact_free`, which poisons the block and jumps into `__planc_unref`
with the refcount forced to 0 so the ordinary free path runs — including the
accounting the leak checker reads.

The compiler emits **no** `ref`/`unref` for a value whose type is `[Compact]`:
`local_is_compact[]` is computed when the local is declared, and the automatic
cleanup, assignment, field-store and finalizer paths all skip those slots. A
compact object owns itself; freeing it is the programmer's call.

`--check-leaks` therefore reports a compact object that is never freed, because the
counter it reads is the allocator's, not a reference count.

**A compact field is not owned by its container.** `free ()` releases the
reference-typed fields (a `string`, a normal object) but leaves a `[Compact]`
field alone, and a normal class's finalizer skips it too. Every compact value the
program creates is the program's to free, whichever object it was stored in;
freeing the container does not free the contents.

`free ()` twice panics with `planc: panic: memory error (double free or corrupted
block)` and exit 134: the block is poisoned with `0xDEADDEAD` on the first call and
`__planc_compact_free` checks for the poison before touching the refcount word.

### Rejected

| Construct | Diagnostic |
|---|---|
| `[Compact] class B : Base` | `[Compact] class 'B' cannot have a base class` — there is no room for a base's fields and no vtable to inherit |
| `[Compact] class B : Iface` | `[Compact] class 'B' cannot implement interfaces: it has no vtable` — the itable lives at `+8`, which is the first field |
| `b is B`, `b as B`, `(B) x` | `'is' cannot target [Compact] class 'B': it has no runtime type` |
| `Object o = b` | `cannot initialize Object variable 'o' with B ('B' is a [Compact] class: it has no reference count and no runtime type)` |

`valac` accepts a compact class implementing an interface (and rejects only a
non-compact base), so that row is a deliberate `planc` limitation: supporting it
would mean an itable without a class vtable, i.e. two different notions of "type
of an object" in the same compiler.

`valac` 0.56 also has **no `free ()`** on compact classes — they are GC-managed
there. `free ()` is a `planc` extension, consistent with the dialect's explicit
memory model.

## 3. Verification

| Case | What it proves |
|---|---|
| `valid/object_root.vala` | `Object` field/variable/array/parameter, `is` through an interface, `as` hit and miss, `==`/`!=`, `Object?` null |
| `valid/compact_manual.vala` | fields, constructor, string and reference fields, `free ()` releasing them in order, no refcount traffic |
| `valid/compact_nested.vala` | a compact object inside a compact object, a zero-field compact class, and the ownership rule: the container's `free ()` does not free the contents |
| `invalid/compact_is.vala`, `invalid/compact_as.vala` | the `is`/`as` diagnostics |
| `invalid/compact_to_object.vala` | conversion to `Object` is rejected with the compact-specific hint |
| `invalid/compact_with_base.vala`, `invalid/compact_with_iface.vala` | the declaration restrictions |
| `run.sh` → `compact_double_free_panic` | second `free ()` panics with exit 134 |

`object_root`, `compact_manual` and `compact_nested` also run in the
`--check-leaks` group, so the first must be leak-free with automatic counting and
the others with manual `free ()` — including the inner compact object, which the
outer `free ()` deliberately does not touch.

## 4. Use in the compiler itself

Neither construct is used in `planc`'s own sources: stage 0 is `valac`, which
rejects `Object o = instance` for implicit roots and has no `free ()`. The
compiler keeps its explicit roots and its reference counting, which is what the
existing code was written against.
