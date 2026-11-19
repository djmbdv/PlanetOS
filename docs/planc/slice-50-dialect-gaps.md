# Slice 50 — closing the Vala dialect gaps (no C interop)

This slice adds the Vala 0.56 constructs that `planc` was still missing, with one
rule from the start: **no `.vapi`, no C interop and no C code injection**. The
dialect is the language, not the bindings.

Every semantics decision below was measured against `valac` 0.56.19 before being
implemented, and every feature has a case in `planc/tests/`.

## 1. What is new

| Feature | Where | Notes |
|---|---|---|
| `#if` / `#elif` / `#else` / `#endif` | `planc/src/preproc.vala` | Line based and string/comment aware, like valac. Macros: `VALA_0_<even>` up to `VALA_0_56`, `PLANC`, plus `-D NAME` / `--define=NAME`. `#error` and `#warning` are honoured. Inactive lines are blanked, not removed, so line:column stay valid. |
| `"""…"""` verbatim strings | `lexer.vala` | Raw: no escapes, no dedent (measured: valac keeps the indentation). |
| `sealed` | parser + codegen | Inheriting from a sealed class is an error. |
| `case a, b:` | parser | Stacked `case a: case b:` already worked. |
| `enum` ↔ `int` | codegen | Measured: valac converts in both directions; `(m & Flag.A) != 0` now compiles. |
| `sizeof (T)` / `sizeof (expr)` | parser + codegen | Reports the size **in this ABI**: every scalar and reference occupies one 8-byte slot, a struct is `8 * slots`. |
| `static` class fields | parser + codegen | Stored as one global named `Class.field`; read/write through the ordinary global path. The instance layout, the field initializer and the finalizer all skip them. |
| Indexers (`T this[I i]`) | parser + codegen | Lowered to `get_item (i)` / `set_item (i, value)`; `obj[i]` and `obj[i] = v` resolve to them. Explicit `get`/`set` bodies are required. **Planc extension**: `valac` 0.56 has no indexer syntax (measured), so it cannot appear in the compiler's own sources, which stage 0 builds with `valac`. |
| Generic **functions and methods** | parser + codegen | Monomorphized like generic classes: `T identity<T> (T x)` is cloned per concrete argument list. Inference from a `T` or `T[]` parameter, or explicit `f<int> (…)`. Works for top-level functions, static methods and instance methods. |
| `static` methods in interfaces | parser + codegen | Called as `Iface.method (…)`; they are not part of the interface method table. |
| Auto-property satisfying an interface property | codegen | `public string name { get; set; }` is a plain field, so `get_name`/`set_name` are synthesized when the interface needs them. |
| `lock (expr) { … }` | parser + codegen + runtime | The runtime gains `__planc_lock_slot`, `__planc_lock_acquire` and `__planc_lock_release`: a spinlock table in `.bss` striped by object address (`xchg` + `pause`). Two threads locking the same object always contend on the same word; **the lock is not recursive**. |
| Generic **interfaces** (`interface I<T>`) | parser + codegen | `I` is monomorphized per argument list (`Holder__int`), with its methods cloned and their `T` substituted; classes implement the concrete interface and get their own itable. |
| Unqualified sibling calls in interface defaults | codegen | `return get_item_at (0);` inside a `virtual` interface method now dispatches on `this` instead of failing with “unknown function”. |
| **Signals declared on interfaces** | parser + codegen | `interface Notifier { public signal void ping (int v); }`. The signal is materialized as a hidden slot on every implementor, and the interface gains an abstract `__sigslot_<name> ()` accessor so `obj.ping (…)`, `obj.ping.connect (…)` and `disconnect` work **through an interface-typed value**: the accessor returns the concrete slot index, read from the itable. |

## 2. What was measured as *not* a Vala feature

| Claim | Measurement | Result |
|---|---|---|
| Nested block comments `/* /* */ */` | `valac` rejects the second `*/` | Not implemented; `planc` matches Vala. |
| Unicode identifiers (`café`) | `valac` reports “unexpected character” | Not implemented; `planc` matches Vala. |
| `foreach` over a `string` | `string` has no `iterator` method in glib-2.0 (both `char` and `unichar` fail) | Not implemented; `planc` matches Vala. |
| `[Flags]` changes what bitwise operators are allowed | `Mode.A \| Mode.B` compiles with and without the attribute | Accepted and inert, as in valac. |
| `@"""…"""` template verbatim strings | `valac` parses `@""` then a new string | Not implemented. |

## 3. What the compiler itself uses now

The stage-0 build is `valac`, so a feature can only be used in `planc`'s own
sources when **valac 0.56 also accepts it**. Measured:

| Feature | valac 0.56 | Used in `planc` sources |
|---|---|---|
| `sealed` | yes | 15 engine classes (`Lexer`, `Parser`, `Preprocessor`, `Emitter`, `Codegen`, `Optimizer`, `SpirvBackend`, `Elf`, `Dwarf`, `AsmAssembler`, `Program`, `StrBuilder`, `Buffer`, `StrIndexMap`, `Ieee754`): none of them is an extension point |
| `case a, b:` | yes | `lexer.vala`, the `\u`/`\U` escape |
| generic functions | yes | not used: without constraints there is no honest place for them here |
| `#if` | yes | not used: there is no build-time difference to express |
| `sizeof` | yes, but it is the **C** size (`sizeof(int)` is 4) | not used: planc's `sizeof` reports its own slot-based ABI (8), so using it for host-side buffer math would be wrong |
| indexers | **no** | cannot be used anywhere in the compiler, by construction |
| `lock` | yes | not used: the compiler is single-threaded |



## 4. Still pending

These are real Vala constructs that remain unimplemented:

| Feature | Why it is not in this slice |
|---|---|
| Visibility enforcement (`private`/`protected`/`internal`) | Accepted and ignored today. Enforcing it is a separate pass and can break existing sources. |
| `typeof` | Returns `GLib.Type`; with no GType there is nothing faithful to return. |
| `[NoReturn]`, `[SimpleType]`, `[PointerType]`, `[IntegerType]` | Accepted and inert; `planc` performs no fall-through analysis to attach `[NoReturn]` to. |
| `.vapi` / `--pkg` / `[CCode]` | Out of scope by decision: no C interop. |

`Object` as a universal root and `[Compact]` real semantics were pending here and
are implemented in [slice-52](slice-52-object-and-compact.md).

## 5. Verification

`planc/tests/run.sh` covers the new behaviour with:

- valid: `preproc`, `case_list`, `static_fields`, `indexer`, `iface_property`,
  `iface_static`, `iface_default_sibling`, `sizeof`, `generic_methods`,
  `generic_interfaces`, `lock_stmt`, `iface_signals`
- invalid: `sealed_inherited`, `sealed_on_function`, `lock_on_int`,
  `preproc_unterminated`, `preproc_unknown_directive`

The suite runs against the self-hosted compiler, so a change that only builds
under `valac` fails stage 2. On Windows the emitted ELF is executed through WSL;
`tools/build-planc-host.sh` and `planc/build.sh` both include the new
`preproc.vala` source.

`lock` was additionally checked under the parallel scheduler: four coroutines
performing 1000 guarded increments each on two OS threads produce exactly 4000.

