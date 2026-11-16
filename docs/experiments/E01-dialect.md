# E-01 — Real dialect of Vala 0.56

- **Tool measured:** `Vala 0.56.18`, GLib 2.88.0, on Ubuntu (resolute), x86_64.
- **Harness:** [`experiments/e01-dialect/run.sh`](../../experiments/e01-dialect/run.sh) and [`run_executables.sh`](../../experiments/e01-dialect/run_executables.sh)
- **Risk it attacks:** R-01 (divergent parser), R-02 (constructor semantics), R-23 (semantic ambiguity)
- **Question:** what does the language actually accept, and with what observable semantics?

## 1. Method

Two passes over the same corpus in `experiments/e01-dialect/cases/`:

1. `valac -C` — frontend and semantics only. It detects whether the construct is accepted.
2. full `valac` — produces an executable. It detects the **observable semantics** at run time.

The generated C is also inspected, and serves as a *readable intermediate representation*: even though `planc` does not emit C, the C from `valac` reveals exactly which semantics must be reproduced.

## 2. Results per case

**Reproducible count:** `SUMMARY: 39 cases, 29 accepted, 10 rejected`. The 10 rejections are language or environment rules, not harness failures; each one is explained in the table.



| Case | Accepted | Measured fact |
|---|---|---|
| `01_class.vala` | yes | class with `virtual`/`override`, properties, signal |
| `02_compact.vala` | yes | `[Compact]` without vtable |
| `03_simpletype.vala` | yes | `[SimpleType] struct Metro : int` and `[IntegerType] struct Id : uint` are accepted |
| `04_pointertype.vala` | yes | `[PointerType]` with `uint8*` and `size_t` fields |
| `05_signal.vala` | yes | **generates a static typed marshaller**, not the generic one |
| `06_async.vala` | **no** | `error: gio-2.0 package required for async methods` |
| `07_try_catch.vala` | yes | `errordomain` with `throws` |
| `08_finally.vala` | yes | `finally` exists and is lowered to a **label + fallthrough**, with no unwinding |
| `09_switch_type.vala` | **no** | `error: Integer or string expression expected` — `switch` only over integer or string |
| `10_lock.vala` | **no** | `lock` over a local: `does not denote a lockable member` |
| `10b_lock_field.vala` | **no** | `error: Only members of the current class are lockable` |
| `11_foreach.vala` | **no** | `ArrayList` does not exist: it is `Gee`, not GLib |
| `11b_foreach_glib.vala` | **no** | `GenericArray` is a container not iterable by `foreach` (it picks `Gee`) |
| `12_generic_struct.vala` | yes | generics accepted; **implementation by erasure + boxing** (§3) |
| `13_generic_constrained.vala` | **no** | `Gee` not available without the package |
| `13b_generic_constrained.vala` | **no** | `where T : Object` **is not valid syntax** in 0.56 |
| `14b_lambda_escapes.vala` | yes | escaping delegate; refcounted box (§4). The case with a parameter named `base` was discarded because of a collision with the reserved keyword |
| `15_constructors.vala` | **no** | `Cannot assign to construct-only properties` |
| `15c_constructors.vala` | yes | initialization order measured (§5) |
| `16_interface.vala` | yes | interface with the `Object` prerequisite |
| `17_errordomain.vala` | **no** | `main` cannot throw |
| `17b_errordomain.vala` | yes | `errordomain` used from a method that throws |
| `18_sizetypeof.vala` | yes | `sizeof(int)` = 4; `typeof` returns a descriptor |
| `19_user_varargs.vala` | yes | **accepted and lowered to C varargs** (§6) |
| `20_cheader.vala` | yes | `[CCode(cheader_filename)]` accepted (we reject it) |
| `21_template.vala` | yes | `@"…$x…"` |
| `22_owned_unowned_weak.vala` | yes | `owned`/`unowned`/`weak` |
| `23_struct_methods.vala` | yes | struct with methods and literal `Pair() { … }` |
| `24_enum_methods.vala` | yes | enum with methods |
| `25_ccode_cname.vala` | yes | `[CCode(cname)]` replaces the type name in C |
| `26_nested_namespace.vala` | yes | `namespace A.B.C` |
| `27_flags.vala` | yes | `[Flags]` with OR of members |
| `28_abstract.vala` | yes | abstract class with a concrete method |
| `29_statics.vala` | yes | `const`, `static` field, `static` method |
| `30_arrays.vala` | yes | `int[] x = { … }` and `new int[4]`; `int[3]` is a **syntax error** |
| `31_unichar.vala` | yes | `unichar` = 32 bits; `string` `.length` counts bytes |
| `34_attributes.vala` | yes | `[NoReturn]` exists; **`[Inline]` does not** (§7) |

## 3. Generics: erasure + boxing, not monomorphization

`12_generic_struct.c` generated from `class Caja<T> { public T valor { get; set; } }`:

```c
struct _CajaPrivate {
    GType t_type;
    GBoxedCopyFunc t_dup_func;
    GDestroyNotify t_destroy_func;
    gpointer _valor;
};
```

And the instantiation passes the type and the copy functions:

```c
caja_construct (TYPE_CAJA, t_type, t_dup_func, t_destroy_func);
```

Consequences:

- The value is stored as a `gpointer`: **every type argument is boxed**.
- The real type travels at run time (`t_type`, a `GType`).
- Copy and destruction are function pointers provided by the caller.

**Project decision:** `planc` **monomorphizes**. It is not a preference: without a run-time `GType` registry there is no way to implement the erasure model. It is a deliberate, documented deviation (D-02 is closed with this datum).

Positive side effect: without `GType` or `dup_func`, a `Lista<int>` stores `int` without boxing.

## 4. Delegates: function pointer + `(target, destroy_notify)`, not a struct

Type emitted for `delegate int Operacion(int x)`:

```c
typedef gint (*Operacion) (gint x, gpointer user_data);
```

The function that **returns** a delegate receives two additional output parameters:

```c
Operacion hacer (gint suma,
                 gpointer* result_target,
                 GDestroyNotify* result_target_destroy_notify);
```

And the captured box is a structure with its own counter:

```c
struct _Block1Data {
    int _ref_count_;
    gint suma;
};
```

That is: **a delegate is neither a double pointer nor a three-word struct**. It is one word (code) plus a `(data, destructor)` pair that travels outside.

**Project decision:** `planc` uses a **two-word fat pointer** `{ codigo, entorno }`. Reason: Vala's model exists to respect C's `GCallback + user_data` convention; with no C to respect, the separate pair only adds hidden output parameters to every function that returns a delegate.

## 5. Object initialization order (measured)

Source `15c_constructors.vala`:

```vala
public class Orden : Object {
    public int a { get; set; default = 1; }
    public int b { get; construct; }
    public int c { get; set; }
    public Orden(int b) { Object(b: b); this.c = 3; print("cuerpo a=%d b=%d c=%d\n", a, b, c); }
    construct { print("construct a=%d b=%d c=%d\n", a, b, c); }
    ~Orden() { print("destructor\n"); }
}
```

Real output:

```
construct a=1 b=2 c=0
cuerpo a=1 b=2 c=3
tras new: 1 2 3
destructor
```

Order established:

| Step | Observed state |
|---|---|
| 1. Field initializers and property `default` | `a = 1` |
| 2. `construct` properties | `b = 2` |
| 3. `construct` block | `c = 0` (not yet assigned) |
| 4. Constructor body | `c = 3` |
| 5. Destructor when the last reference is released | — |

**Correction to the previous plan:** it said *"body → `construct` → `base()`"*. That is false. The `construct` block runs **before** the body, and the `construct` properties are set **before** the `construct` block.

Additional measured rule: a `{ get; construct; }` property **cannot be assigned in the body**. Only through chaining `Object(b: valor)` or `this(…)`.

## 6. User varargs: accepted by Vala, impossible for us

```vala
void imprimir(string fmt, ...) { print(fmt); }
```

`valac` accepts it and emits C with a real `...`:

```c
void imprimir (const gchar* fmt, ...) { … }
```

It works because a C compiler compiles it. `planc` has no `va_list` and cannot build a variadic frame without a C ABI.

**Consequence:** VL-11 is kept, but its justification changes. It is not a Vala restriction: it is a restriction **of ours**, derived from removing C. The diagnostic must explain it that way, not attribute it to the language.

## 7. Attributes: what is Vala and what is invented

| Attribute | Does it exist in Vala 0.56? | Observation |
|---|---|---|
| `[Compact]`, `[SimpleType]`, `[IntegerType]`, `[PointerType]` | yes | layout semantics |
| `[CCode(cname)]` | yes | renames the type/symbol in C |
| `[CCode(cheader_filename)]` | yes | we reject it (it presupposes C) |
| `[NoReturn]` | yes | accepted |
| `[Flags]` | yes | — |
| `[Inline]` | **no** | `warning: Attribute 'Inline' never used` |
| `[NoAtomico]` | **no** | it is ours |

Two corrections to the plan: `[Inline]` and `[NoAtomico]` are **`planc` extensions**, not Vala attributes. They must be documented as such so that nobody expects `valac` to understand them when porting code.

## 8. Other measured rules

| Rule | Data |
|---|---|
| `switch` | only over integer or string. **There are no type patterns** (V-01 answered) |
| `finally` | it exists; it is lowered to a label, with no unwinding (V-02 answered) |
| `lock` | the target must be **a member of the current class**, not an expression |
| arrays | `int[3] x` is a syntax error; every array is dynamic and carries a count |
| generics | no constraint syntax (`where T : …`) in 0.56 |
| `main` | cannot declare `throws` |
| type names | `valac` rejects single-letter names by *lint*, not by the language |
| evaluation order | measured **right to left** (`print("%d %d %d", MAX, f(), f())` → `10 2 1`) |

The evaluation order is a C artifact that leaks through. In `planc` it is **defined** left to right, and documented as a dialect difference: it is an improvement, not an accidental incompatibility.

## 9. Conclusion

- **Passes.** The harness is in place and the dialect is characterized with facts, not assumptions.
- **Assumptions answered:** V-01 (switch), V-02 (finally), V-05 (generics: erasure, not monomorphization), V-06 (delegates: separate pair, not struct).
- **Assumptions pending:** V-03 (`async`/`yield` → see [E-04](E04-async.md)), V-04 (vapi attributes → [E-06](E06-vapis.md)), V-07 (`#if`).
- **Mandatory changes to the plan:**
  1. Fix the initialization order in [02 §3.3](../02-compiler.md#33-semantics).
  2. Document monomorphization as a **deviation** from Vala, with the reason (there is no `GType`).
  3. Change the delegate to a two-word fat pointer and justify the deviation.
  4. Move `[Inline]` and `[NoAtomico]` to the list of our own extensions.
  5. Add the restriction of `lock` to class members.
  6. Declare the left-to-right evaluation order as a defined difference.
  7. Reword VL-11: our own restriction, not the language's.
