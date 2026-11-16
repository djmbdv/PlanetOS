# planc, slice 8: `throws`/`try`/`catch`/`finally`, `out`/`ref`, properties, object initializers, namespaces, and multi-file compilation

Slice 8 completes the core application-level Vala features needed for multi-file
programs and self-hosting preparation in `planc` (**I1**, **I2**, **I3**,
**TC-02**, **TC-05**, **KR-03**, **VL-12**, **VL-14**, **RT-03**, **RT-04**):
checked error domains with zero-CFI register-based propagation, pass-by-reference
`out` and `ref` parameters, inline and synthesized `class`/`struct` properties,
`new Cls(args) { prop = expr }` object initializers, multi-file compilation
with cross-unit forward type resolution, and `namespace`/`using` support.

Requirements demonstrated: **I1**, **I2**, **I3**, **TC-02**, **TC-05**,
**KR-03**, **VL-12**, **VL-14**, **RT-03**, **RT-04**.

---

## 1. Checked error handling: `errordomain`, `throws`, `try`/`catch`/`finally`

- **Dual-return error ABI (Decision A1):**
  - Functions, constructors, and methods declared with `throws Domain...`
    return their normal value in `rax` and an `Error*` pointer in `rdx`
    (`xor edx, edx` on the normal return path; non-zero `Error*` in `rdx` on
    `throw`).
  - Callers check `test rdx, rdx` directly after every throwing call and jump
    immediately to the active local unwind target on error without `.eh_frame`
    or stack-unwinding tables.
- **Heap `Error` payload and ARC integration:**
  - `throw new Domain.CODE(msg)` allocates a 24-byte heap payload via
    `__planc_alloc(24, 1)` (`kind = 1`) with 1 tracked reference slot:
    `[err + 8] = 1`, `[err + 16] = message` (`string*`), `[err + 24] = domain_id`,
    `[err + 32] = code`.
  - Setting `kind = 1` reuses `__planc_unref`'s built-in ref-slot walker to
    automatically release `message` when an `Error` instance's refcount reaches
    zero under `--check-leaks`.
- **Compile-time verification & runtime matching:**
  - Calls to `throws` functions/constructors/methods from a context whose
    enclosing `try`/`catch` handlers or enclosing `throws` signature do not
    cover every thrown domain are rejected at compile time (`unhandled_error`,
    `catch_unknown_domain`).
  - `try { ... } catch (Domain e) { ... } catch (Error e) { ... } finally { ... }`
    supports domain matching by `[err + 24]`, catch-all `Error` handlers,
    `e.message`, `e.domain`, `e.code`, and `e is Domain` checks.
  - `emit_error_jump` realigns `rsp` over active stacked call operands
    (`push_depth`), releases only live expression temporaries
    (`live_stmt_ref_slots`) and active locals in scope, and runs enclosing
    `finally` blocks cleanly on `throw`, `return`, `break`, and `continue`.
  - `VarDeclStatement`, `ForeachStatement`, and `SwitchStatement` register their
    local/hidden reference slots only after their initializer/collection/target
    expressions complete, ensuring an exception thrown during initialization
    never unrefs an uninitialized stack slot.

---

## 2. `out` and `ref` parameters (Decision A2)

- Parameters marked `out` or `ref` accept caller lvalues (local variables and
  `arr[i]` array elements; property getters and constants are rejected) and pass
  their 64-bit address (`T*`) under the existing calling convention.
- On function entry, `out` parameters clear/unref any pre-existing caller value
  (`__planc_unref` for reference types or struct reference fields, zero-init /
  empty-string default initialization) before body execution, while `ref`
  parameters retain direct read-modify-write access via `[ptr]`.
- Reassignments inside the callee update `*ptr` via `emit_field_store`, keeping
  reference counts balanced for `string`, `Class`, `T[]`, `Error`, and `struct`
  values carrying strings.
- Option B nullability rules are enforced symmetrically on argument binding and
  callee assignments (`out T` initializes non-null or guarantees definite
  assignment semantics for reference/scalar slots).

---

## 3. Properties and object initializers (Decision A3)

- **Inline auto-properties vs. accessor methods:**
  - Non-virtual bodyless properties (`{ get; set; default = ...; }` or
    `{ get; private set; default = ...; }`) lower directly to inline object/struct
    field slots ($O(1)$ load/store with zero call overhead).
  - Properties with custom `get { ... }` / `set { ... }` bodies (with implicit
    `value` parameter) or `virtual` / `override` / `abstract` dispatch synthesize
    `<Class>__get_<prop>` / `<Class>__set_<prop>` methods and `.rodata` vtable
    entries, allocating a hidden `#prop_<name>` backing field when a bodyless
    accessor is paired with a custom one.
- **Object initializers:** `new Cls(args) { prop1 = expr1, prop2 = expr2 }`
  evaluates constructor arguments first, initializes the object, and assigns
  named fields or invokes property setters in declaration order before returning
  the constructed reference.

---

## 4. Multi-file compilation, forward types, and `namespace` / `using`

- **Multi-unit CLI (`planc <src1.vala> <src2.vala>... -o <output>`):**
  Accepts any number of `.vala` translation units on the command line and merges
  them into a single static native ELF binary.
- **Pre-scan & forward types (`Parser.prescan_types`):** Pre-registers `enum`,
  `struct`, `class`, and `errordomain` declarations across all input units
  before parsing function signatures or bodies, allowing forward and mutual
  type references within and across files.
- **`namespace` & `using`:** Parses nested `namespace A.B { ... }` blocks and
  `using A.B;` directives, flattening declared symbols cleanly into the
  compilation program. (Explicit `Namespace.Symbol` dotted type/call
  qualification is left for Slice 9 self-hosting extensions.)

---

## 5. Verification

`/home/djmbdv/PlanetOS/planc/tests/run.sh`: **146 cases, 146 pass, 0 fail**
(64 valid including `error_handling`, `properties_and_initializers`,
`out_ref_params`, and `namespaces_and_forward_types`; 53 invalid including
`unhandled_error` and `catch_unknown_domain`; 8 bounds; 17 `--check-leaks` runs
covering all 4 new single-file valid tests with empty `stderr`; 3 null/cast
checks; 1 multi-file `--check-leaks` test compiling two cross-referencing units).

Determinism (**TC-05**), W^X segments (**KR-03**), and zero external symbols
(**I2**) on `planc --check-leaks planc/tests/valid/error_handling.vala`:

```
$ sha256sum err1 err2
b740de684817973989970c6823f7a11fdd52f4dd5035d1fae0a3d8f775763e42  err1   (13416 bytes)
b740de684817973989970c6823f7a11fdd52f4dd5035d1fae0a3d8f775763e42  err2   (13416 bytes)

$ readelf -lW err1
  LOAD  0x0000e8 0x00000000004000e8 ... 0x0012b9 0x0012b9 R E
  LOAD  0x002000 0x0000000000402000 ... 0x00030c 0x00030c R
  LOAD  0x003000 0x0000000000403000 ... 0x000000 0x000060 RW

$ nm -u err1
(empty)
```
