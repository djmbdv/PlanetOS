# 02 — `planc`: native Vala compiler

It is the central artifact. Everything else depends on it. This document defines its architecture, the representation decisions and what must be verified before writing each part.

## 1. Compiler scope

`planc` takes Vala sources (`.vala`) and interface descriptors (`.vapi`) and produces ELF64 objects and executables for x86_64. It does not generate C at any point, neither as an intermediate step nor as debug output.

It has **two backend targets that share one IR**:

| Target | Output | Consumer |
|---|---|---|
| `x86_64` | ELF64 objects and executables | the system itself: kernel and userland |
| `spirv` | SPIR-V binary modules | GPU drivers: Vulkan shaders (TC-11, [§10.4](#104-spir-v-backend-shaders-tc-11)) |

Both consume the same SSA IR. A shader is written in the Vala dialect, compiled by the same frontend and lowered to SPIR-V by its own backend; no GLSL, no glslang, no external shader compiler exists in the chain.

```
.vala / .vapi
   │
   ├─ lexer       → tokens with position
   ├─ parser      → AST
   ├─ semantics   → symbol table, types, resolution, checking
   ├─ lowering    → typed AST → IR
   ├─ IR          → SSA, blocks, phi
   ├─ backend     → instruction selection, registers, encoding
   ├─ ELF         → .o with sections, symbols and relocations
   └─ linker      → static executable with segments and entry point
```

## 2. Dialect

`planc` does not implement "Vala" in the abstract: it implements a versioned dialect (TC-10), defined in `dialecto/gramatica.ebnf` and in `dialecto/conformidad/`.

### 2.1 Accepted

| Category | Constructs |
|---|---|
| Types | `class`, `[Compact] class`, `interface`, `struct`, `[SimpleType] struct`, `enum`, `[Flags] enum`, `delegate`, `errordomain`, `namespace`, generics with type parameters (classes, structs and **functions**). Every class without a declared base derives from `Object`, the implicit root ([slice-52](planc/slice-52-object-and-compact.md)) |
| Members | fields (**including `static` fields, one global per class**), constants, properties (`get`, `set`, `construct`, `default`), **indexers** (`T this[I i]`, a `planc` extension), methods, signals, constructors with `this()` and `base()` |
| Control | `if`, `while`, `do`, `for`, `foreach`, `switch` (**with `case a, b:` lists**), `break`/`continue` with a label, `return`, `throw`, `try`/`catch`/`finally`, `using` |
| Expressions | `@"…"` templates, `is`, `as`, `??`, `in`, `out`, `ref`, lambdas `(a) => expr`, method references, `new`, array literals, indexers, property access, `sizeof`, `typeof` |
| Preprocessing | `#if` with the dialect version macros |
| Modifiers | `public`, `private`, `internal`, `protected`, `static`, `abstract`, `virtual`, `override`, `sealed`, `owned`, `unowned`, `weak`, `async` |
| Vala attributes | `[Compact]`, `[SimpleType]`, `[IntegerType]`, `[PointerType]`, `[CCode(cname)]`, `[NoReturn]`, `[Flags]` |
| Own attributes | `[AsmBody]`, `[Inline]`, `[NoAtomico]` — **they do not exist in `valac`**, they are `planc` extensions |
| Shader attributes (planned, [§10.4](#104-spir-v-backend-shaders-tc-11)) | `[ShaderStage(stage)]`, `[Specialization(id)]`, `[Location(id)]` — mark Vala functions and types as Vulkan interface elements |

Semantic restrictions measured in the language, which the compiler must enforce:

| Restriction | Detail |
|---|---|
| `switch` | only over integer, enum or string. **There are no type patterns** ([E-01](experiments/E01-dialect.md)) |
| `lock` | the target must be a **reference type**; `planc` accepts any reference expression, not only a member of the current class (see [slice-50](planc/slice-50-dialect-gaps.md)) |
| `main` | cannot declare `throws` |
| arrays | there are no fixed-size arrays (`int[3]` is a syntax error); every array is dynamic |
| generics | no constraint syntax; `where T : …` does not exist in 0.56 |
| `construct` properties | assignable only through `Object(prop: value)` chaining, never in the body |

### 2.2 Rejected with a diagnostic (TC-07)

| Construct | Reason |
|---|---|
| `[CCode(cheader_filename = …)]` | Presupposes a C compiler |
| `[CCode(cprefix/ctypes/array_length/array_null_terminated/ref_function/…)]` | C interop conventions with no meaning here |
| `extern` declared against a C header | There is no C to link against; `extern` is admitted only for `planetrt` symbols described in a project-owned `.vapi` |
| User variadic functions | VL-11. **Note:** `valac` does accept them and lowers them to C varargs; the restriction is ours, derived from not having a C ABI |
| `[CCode(cname)]` on types with C layout | The layout is our own |
| `is` / `as` / cast to a `[Compact]` class, `[Compact]` with a base or an interface | A compact instance has no vtable and no reference count, so it has no runtime type ([slice-52](planc/slice-52-object-and-compact.md)) |

Rejection of foreign attributes is **deferred to the point of use, not to load time** ([E-06](experiments/E06-vapis.md)): `cheader_filename` appears 752 times in the standard vapi files, and rejecting the whole file would make any third-party `.vapi` unusable. The metadata is loaded, the parts that have meaning are applied, and a warning is issued when a symbol that depends on C is used.

### 2.3 Assumptions, already answered by measurement

| ID | Assumption | Result | Evidence |
|---|---|---|---|
| V-01 | Does `switch` support type patterns? | **no**: only integer, enum or string | [E-01](experiments/E01-dialect.md) |
| V-02 | Does `finally` exist? | **yes**, and it lowers to a label without unwinding | [E-01](experiments/E01-dialect.md) |
| V-03 | Shape of `async`/`yield` | re-entry with `goto` and the whole state on the heap; **API tied to GIO** | [E-04](experiments/E04-async.md) |
| V-04 | `[CCode]` attributes in vapi files | `cname` 1179, `cheader_filename` 752, `type_id` 462 | [E-06](experiments/E06-vapis.md) |
| V-05 | Are generics monomorphized? | **no**: type erasure + boxing with `GType` | [E-01 §3](experiments/E01-dialect.md#3-generics-erasure--boxing-not-monomorphization) |
| V-06 | Delegate layout | function pointer **plus** a separate `(target, destroy_notify)` pair | [E-01 §4](experiments/E01-dialect.md#4-delegates-function-pointer--target-destroy_notify-not-a-struct) |
| V-07 | Does `#if` exist? | **yes**, with `VALA_0_56` and family | [E-01](experiments/E01-dialect.md) |

One assumption remains open: **V-08**, whether declaration order affects type resolution in edge cases (circular dependencies between units). It will be checked with the conformance suite, not before.

## 3. Frontend

### 3.1 Lexer

Tokens with line, column and offset. Cases that must be handled explicitly:

- String literals with templates `@"hola $nombre"` and `@"${expr}"`: the lexer produces a sequence of fragments and expressions, not a flat string.
- Verbatim strings `"""…"""` with significant indentation.
- Numeric literals with suffixes (`u`, `l`, `ul`, `f`), hexadecimal, binary, and `_` separators.
- Nested comments `/* /* */ */` if the language admits them `[V]`.
- Unicode identifiers.

### 3.2 Parser

Recursive descent, hand-written, with one token of lookahead and limited backtracking. The grammar is documented in EBNF and the implementation is checked against it in a conformance test.

The parser produces an AST **without resolved types**, with error nodes that allow recovering and reporting several diagnostics per file (TC-08).

### 3.3 Semantics

Passes in order, each one with its own test:

| Pass | Responsibility |
|---|---|
| 1. Unit loading | resolve `using`, load `.vapi` and `.vala`, detect cycles |
| 2. Symbol collection | declare namespaces, types, members, without resolving bodies |
| 3. Inheritance resolution | close hierarchies, check `override` signatures, interfaces |
| 4. Type checking | local inference (`var`), `null` versus non-nullable, return, `throws` |
| 5. Constructor resolution | `this()`/`base()`, initialization order, `construct` |
| 6. Flow analysis | return on all paths, variables used before assignment, valid `break` |
| 7. Memory ownership | `owned`/`unowned`/`weak` transfers, insertion of `ref`/`unref` |
| 8. RTTI closure | which types need a descriptor |
| 9. Closure resolution | which lambdas escape, which variables they capture by value or by reference |

Pass 5 is the most delicate one. The order is **measured**, not assumed ([E-01 §5](experiments/E01-dialect.md#5-object-initialization-order-measured)):

```
1. field initializers and property `default` values
2. assignment of `{ get; construct; }` properties through the chain
3. `construct` block
4. constructor body
```

An earlier plan in this document said *"body → `construct`"*. It is false, and the error is of the kind that produces half-built objects that work in simple tests and fail in composite ones. The measurement is in the real output of case `15c_constructores`.

Corollary: a `construct` property **cannot** be assigned in the body. Only with `Object(prop: value)` or `this(...)`. If the compiler allows it, it is wrong.

Pass 7 is where the memory model is decided (§5).

## 4. Type representation

Every type is reduced to one of these forms before generating IR:

| Form | Description | Example |
|---|---|---|
| `Vacio` | no value | `void` method |
| `Entero(ancho, signo)` | register | `int`, `uint8`, `size_t` |
| `Flotante(ancho)` | SSE register | `float`, `double` |
| `Puntero(tipo)` | 8 bytes | `void*`, implicit class pointer |
| `Estructura(campos, alineacion)` | value, by copy | `struct`, `[SimpleType]` |
| `Referencia(tipo)` | pointer with refcount | class, `string`, `T[]`, delegate |
| `InstanciaGenerica(tipo, args)` | monomorphized | `Lista<int>` |

### 4.1 Generics

**Decision: monomorphization.** Each instantiation produces its own code and layout.

**It is a deliberate deviation from Vala, not an imitation.** It is measured ([E-01 §3](experiments/E01-dialect.md#3-generics-erasure--boxing-not-monomorphization)) that `valac` does the opposite: it erases the type and stores the value in a `gpointer` with a `GType` and two function pointers for copy and destruction.

```c
/* what valac emits for class Caja<T> */
struct _CajaPrivate {
    GType t_type;
    GBoxedCopyFunc t_dup_func;
    GDestroyNotify t_destroy_func;
    gpointer _valor;          /* every type argument is boxed */
};
```

We cannot replicate it: the erasure model **requires a runtime type registry**, which is exactly what the project does not have. Monomorphization is not an aesthetic preference; it is the only option compatible with I3.

| Advantage | Cost |
|---|---|
| No *boxing*, no type registry | Binary growth |
| Exact layout per instantiation | Longer compile time |
| A `Lista<int>` stores `int` without boxing | — |

A threshold is documented: if an instantiation repeats and all of its arguments are reference types, the compiler MAY share the code by passing the method table as a hidden argument. It is an optimization, not a requirement; the behaviour must be identical and the verification is differential (§[06](06-verification.md#6-differential-oracle)).

### 4.2 Layout

The compiler computes offsets, sizes and alignment. Rules:

- Natural alignment of the field; the struct is aligned to its most-aligned field.
- No field reordering (the programmer controls the layout).
- Hidden field first: vtable pointer in classes; header in `string` and arrays.
- `[Compact]` has no vtable and no reference count: fields start at `+8` instead of `+16`, so an instance is 16 bytes smaller and cannot be the target of `is`, `as` or a cast. Its lifetime is manual (`free ()`), see [slice-52](planc/slice-52-object-and-compact.md).
- `[SimpleType] struct` is passed by value in registers, never by pointer.

## 5. Memory model

Vala uses reference counting. `planc` makes it explicit:

| Operation | Lowering |
|---|---|
| assignment to `owned T` | `ref(new); unref(old); store` |
| passing to an `owned` parameter | transfer; the caller does not free |
| passing to a parameter without a modifier | implicit `ref` if the receiver retains |
| returning `T` | transfer to the caller |
| `weak T` | registration in the weak table; nulled on free |
| `unowned T` | no refcount; the programmer guarantees the lifetime |
| `[Compact] T` | no refcount at all: the block is released by an explicit `free ()`, which also releases its reference-typed fields ([slice-52](planc/slice-52-object-and-compact.md)) |

**Cycles are not collected** (non-requirement, see [00 §7](00-requirements.md#7-non-requirements)). It is a property of the language, not a defect of the compiler, and it is documented in the standard library.

**Atomic counting by default** (RT-03). In the `host` and `user` profiles, `ref`/`unref` use `lock inc`/`lock dec`. In the `kernel` profile, likewise, except for types marked `[NoAtomico]` and used exclusively under a lock — an explicit annotation, not an inference.

## 6. Closures

**Vala does not represent a delegate as a struct.** It is measured ([E-01 §4](experiments/E01-dialect.md#4-delegates-function-pointer--target-destroy_notify-not-a-struct)): it emits a function pointer to which a `user_data` parameter is added, and the box travels **outside**, in out parameters:

```c
typedef gint (*Operacion) (gint x, gpointer user_data);

Operacion hacer (gint suma,
                 gpointer* result_target,              /* output: environment */
                 GDestroyNotify* result_target_destroy_notify);
```

That design exists to respect C's `GCallback + user_data` convention. With no C to respect, it only adds hidden out parameters to every function that returns a delegate.

**Decision: two-word fat pointer.**

```
delegate → { codigo: fn, entorno: void* }
```

The captured box still has its own counter (Vala uses `_ref_count_` in a separate structure; we keep it), but the delegate is a 16-byte value that is passed and returned like any other.

| Vala decision | `planc` decision | Reason |
|---|---|---|
| `fn` + separate `(target, destroy_notify)` | `{ fn, entorno }` in one value | Without a C ABI there is no reason to separate them |
| Box with a counter, freed by `destroy_notify` | Box with a counter, freed when the delegate is released | Consistency with `unref` |
| Environment as the `user_data` of the last parameter | Environment as the first hidden argument in `rdi` | Symmetry with `this` (§3.1 of [01](01-architecture.md#31-function-call)) |

Lowering rules:

- Capture **by value** at creation time, copying into the box.
- A captured variable that is modified later moves to live in the box.
- If the delegate does not escape, the box is allocated on the caller's stack (escape analysis, pass 9). **Vala does not do this**: it always uses `g_slice_new0`. We attempt it as an optimization and the conservative mode is the box on the heap.
- **No *trampolines* generated at runtime.** The environment travels as an argument, so generated executable memory is never needed, and with that the W^X restriction on closures disappears.

## 7. Signals

Measured in [E-01](experiments/E01-dialect.md): `valac` does **not** use the generic marshaller or libffi. It generates one typed marshaller per signal:

```c
static void g_cclosure_user_marshal_VOID__INT_STRING (GClosure*, GValue*, guint,
                                                      const GValue*, gpointer, gpointer);
emisor_signals[EMISOR_AVISO_SIGNAL] = g_signal_new ("aviso", TYPE_EMISOR,
    G_SIGNAL_RUN_LAST, 0, NULL, NULL, g_cclosure_user_marshal_VOID__INT_STRING,
    G_TYPE_NONE, 2, G_TYPE_INT, G_TYPE_STRING);
```

That is: the statement that "signals require libffi" was **false** for the static case. libffi only appears with dynamic dispatch by name and type.

What Vala does and we do not:

| Aspect | Vala | `planc` |
|---|---|---|
| Marshalling | static typed marshaller | direct typed dispatch, without `GValue` |
| Emission | `g_signal_emit`, **variadic** | direct call to the handler loop |
| Connection | `g_signal_connect(e, "aviso", …)` — **by name, on a string** | by static signal identifier |
| Storage | `GClosure` + `GValue` | node with a typed function pointer |

Connection by string name requires looking the signal up in the type descriptor at runtime: it is reflection that we do not need and that also prevents dispatch in IRQ context without allocating memory.

Artifacts that `planc` generates per signal:

| Artifact | Content |
|---|---|
| Signal constant | stable `uint32` per type |
| Entry in the type descriptor | id, name, signature, flags (`RUN_LAST`, `DETAILED`, `NO_RECURSE`) |
| Typed emission function | walks the handlers and calls with the exact signature |
| Typed connection function | wraps the delegate in a node |

```vala
// source
public signal void dicho(string quien);

// generated (conceptual)
const uint32 __SIG_DICHO = 3;
void saludo_emitir_dicho(Saludo self, string quien) {
    for (var n = self->manejadores; n != null; n = n->siguiente) {
        if ((n->banderas & BLOQUEADO) == 0)
            ((void (*)(void*, string)) n->codigo)(n->entorno, quien);
    }
}
```

Consequences:

- **Without libffi**, without a generic marshaller, without `GValue` — confirmed as a viable path, because it is the one `valac` already takes in the static case.
- `connect` and `emit` are direct calls: they can be used in IRQ context (RT-06).
- The handler list is allocated on the first connection; an object without connections pays nothing.
- Nested emission and `RUN_LAST`/`RUN_FIRST` order are implemented with the same traversal plus a depth counter.
- `connect` by name is lost. It is a capability that is not used in the system tree and that can be added later with a name table if it were needed.

## 8. Coroutines and errors

### 8.1 `async`

**Measured restriction:** Vala 0.56's `async` **requires GIO**. `valac` without `--pkg gio-2.0` answers:

```
error: gio-2.0 package required for async methods
```

and the generated C uses `GTask`, `GAsyncResult` and `g_main_context_iteration`. PlanetOS does not have GIO, so **Vala's API is not reused; only its lowering shape** ([E-04](experiments/E04-async.md)).

Shape of the lowering that is adopted:

| Generated part | Content |
|---|---|
| State structure | **all** locals, parameters, loop temporaries and the resume index |
| Resumable function | re-invoked from the beginning and jumps to the suspension point |
| Suspension | `return` with a "not finished" indicator |
| Completion | `return` with a "finished" indicator |
| `Planet.Corrutinas.Tarea` object | result, error, continuations |

Two details of the lowering that must be replicated literally, measured and not deduced:

1. **Re-entry from the top, not dispatch by state.** `valac` emits `switch (_state_) { case 0: goto _state_0; case 1: goto _state_1; }` at the beginning of the function. In SSA IR this is a block `switch` to the suspension labels.
2. **`for` loop with a control flag.** The `for` is rewritten to `while (TRUE)` with a flag that avoids repeating the increment on resumption:

```
i = 0;
primero = TRUE;
while (TRUE) {
    if (!primero) { i = i + 1; }
    primero = FALSE;
    if (!(i < hasta)) break;
    … body, possible yield …
}
```

Without that flag, a `continue` or a `yield` inside the body executes the increment twice and the loop runs out of control. It is the most likely error in the whole lowering.

**State on the heap by default**, as in Vala. Stack allocation is an optimization that escape analysis may apply (VL-08), never an assumption.

### 8.2 `throws`

Without stack unwinding. A method that throws receives a hidden out parameter:

```vala
// source
int analizar(string s) throws ParseError;

// effective ABI
int analizar(string s, Planet.Error** error);
```

- On success, `*error` is left as `null`.
- On `throw`, the error is constructed, written to `*error` and the zero value is returned.
- `try`/`catch` checks after every call that throws.
- `lock` is closed on **every exit edge**, including the error ones. Since there is no unwinding, the compiler knows all the edges and `finally` is not needed.
- `Planet.Error` is a class with `dominio`, `codigo` and `mensaje`; its ownership belongs to the caller.

## 9. IR

SSA with basic blocks and `phi` nodes.

| Group | Operations |
|---|---|
| Constants | `const.i*`, `const.f*`, `const.null`, `const.string` |
| Arithmetic | `add`, `sub`, `mul`, `div`, `rem`, signed and unsigned, integers and floats |
| Logic | `and`, `or`, `xor`, `shl`, `shr`, `sar`, `not` |
| Comparison | `cmp.eq/ne/lt/le/gt/ge` per type |
| Conversion | `trunc`, `zext`, `sext`, `fptrunc`, `fpext`, `fptosi`, `sitofp`, `bitcast` |
| Memory | `alloca`, `load`, `store`, `field.ptr`, `index.ptr`, `ptr.add` |
| Call | `call`, `call.virtual`, `call.closure`, `call.intrin` |
| Control | `br`, `br.cond`, `switch`, `ret`, `unreachable` |
| Runtime | `ref`, `unref`, `alloc`, `free`, `error.set`, `error.check`, `signal.emit` |

No alias analysis in the first version: `load`/`store` are optimization barriers. It is documented as a conscious limitation, not as pending work.

Optimizations included: constant folding, copy propagation, dead code elimination, CFG simplification, inlining of small functions marked `[Inline]`. Nothing else. Correctness weighs more than performance.

## 10. Backend

### 10.1 Instruction selection

Table-driven mapping from IR operations to x86_64 sequences. Cases that require more than one instruction:

| Operation | Sequence |
|---|---|
| integer `div` | sign-extend, `idiv`, move from `rdx:rax` |
| integer `rem` | idem, keep `rdx` |
| floating `cmp.lt` | `ucomisd` + `setb` + `movzx` |
| `fptosi` conversion | `cvttsd2si` with range checking if the value can overflow |
| dense `switch` | jump table in `.rodata` |
| sparse `switch` | comparison tree |

### 10.2 Register allocation

*Linear scan* over live intervals, with separate GPR and SSE classes, and *spilling* to stack slots. Constraints: registers fixed by the ABI, `rax`/`rdx` reserved around `div`, `rcx` for variable shifts.

Prologue and epilogue generated per function: in builds with `debug = dwarf` the **frame pointer** (`rbp`) is kept even when it is not needed, because GDB rebuilds the stack with it; without CFI, the alternative would be to emit `.eh_frame`, which is not needed because there is no unwinding.

### 10.3 Encoding

x86_64 encoding tables with support for `REX`, `ModRM`, `SIB`, 8/32-bit displacements and 8/32-bit immediates. The same table is used by the backend and by the `[AsmBody]` assembler.

### 10.4 SPIR-V backend, shaders (TC-11)

The second backend target. It consumes the same SSA IR and emits a **SPIR-V binary module** with `planc`'s own serializer — the same shape as the ELF writer, a new one is not invented: SPIR-V is a flat sequence of 32-bit words (`magic 0x07230203`, version, generator, bound, schema, instructions).

| Aspect | Decision |
|---|---|
| Entry point | a Vala function annotated `[ShaderStage(vertex|fragment|compute|…)]`; it becomes the `OpEntryPoint` of the corresponding execution model |
| Uniform blocks | a Vala class or `[Compact] class` annotated with its descriptor set/binding → `OpTypeStruct` in the `Uniform` storage class |
| Push constants | `[Compact] class` passed to the entry point → `PushConstant` storage class |
| Specialization | an `int`/`bool` constant annotated `[Specialization(id)]` → `OpSpecConstant`; the rest of the constants are folded at compile time |
| Inputs/outputs | function parameters and return value (or an `in`/`out` struct) annotated `[Location(n)]` → interface variables |
| Determinism | byte-identical module for the same input (TC-05 applies identically); no timestamps, the generator word is fixed |

The implemented fragment subset is straight-line and scalar: `frag_coord_x/y/z/w`, `uniform_time/width/height`, `uniform_p0()..uniform_p3()` (an 8-float push-constant block), `+ - * /`, and the `GLSL.std.450` scalar builtins `abs`, `floor`, `fract`, `sqrt`, `min`, `max`, `clamp`, `mix`, `step` and `smoothstep`. Modules import the extended instruction set only when one of those is used, and [stdlib/spirv_compat.vala](../../stdlib/spirv_compat.vala) evaluates exactly this subset, which is what lets `Gsk.ShaderNode` paint a render node from the same module the compositor bakes.

The shader dialect is a **restricted subset**, not an extension: what SPIR-V's execution models cannot express is rejected at compile time with a positioned diagnostic (TC-12), following the same rule as the measured Vala rejections in [E-01](experiments/E01-dialect.md):

| Rejected | Reason |
|---|---|
| recursion, `async`, `yield` | SPIR-V functions have no call stack: control flow must return |
| heap allocation, `new`, reference counting | no allocator inside a shader |
| pointers as values, pointer arithmetic | SPIR-V pointers are typed and exist only through storage classes |
| delegates, signals, exceptions | no runtime machinery behind the entry point |
| global mutable state outside the interface | the module interface is closed |

Verification: every module produced in CI must pass `spirv-val` and `spirv-dis` must round-trip it; the tests compare `spirv-dis` output against golden files, not raw bytes, so that a harmless re-encoding does not break the suite. The Vulkan interaction (host bindings, device selection, pipeline setup) is specified in the graphics requirements GX-01…GX-03 of [00-requirements.md](00-requirements.md).

## 11. Assembler and `[AsmBody]`

`[AsmBody]` allows privileged instructions to be written inside a Vala function, without taking the code out of the language (I5):

```vala
[AsmBody(@"
    mov %cr3, %rax
    mov %rax, %cr3
    ret
")]
public static extern void recargar_cr3();

[AsmBody(@"
    swapgs
    iretq
")]
public static extern void volver_a_usuario();
```

Subset of instructions that the assembler MUST encode (TC-04):

| Group | Instructions |
|---|---|
| Data | `mov` (all forms), `lea`, `movzx`, `movsx`, `xchg` |
| Arithmetic | `add`, `sub`, `imul`, `mul`, `idiv`, `div`, `inc`, `dec`, `neg` |
| Logic | `and`, `or`, `xor`, `not`, `shl`, `shr`, `sar`, `test`, `cmp` |
| Stack | `push`, `pop`, `enter`, `leave` |
| Control | `jmp`, `jcc`, `call`, `ret`, `loop` |
| System | `syscall`, `sysret`, `iretq`, `swapgs`, `cli`, `sti`, `hlt`, `pause`, `cpuid`, `rdtsc`, `lfence`, `sfence`, `mfence` |
| Privileged | `lgdt`, `lidt`, `ltr`, `mov` to/from `cr0..cr8`, `mov` to/from `dr*`, `rdmsr`, `wrmsr`, `invlpg`, `wbinvd` |
| I/O | `in`, `out` in their widths |
| Atomics | `lock` + `cmpxchg`, `xadd`, `xchg` |
| SIMD | `movsd`, `movss`, `addsd`, `subsd`, `mulsd`, `divsd`, `cvtsi2sd`, `cvttsd2si`, `ucomisd`, `pxor`, `fxsave`, `fxrstor` |

The list is closed. Adding an instruction requires adding its test case.

## 12. ELF

### 12.1 Objects (`ET_REL`)

Sections emitted: `.text`, `.rodata`, `.data`, `.bss`, `.symtab`, `.strtab`, `.rela.text`, `.rela.rodata`, `.rela.data` and, if there is `debug`, `.debug_*`.

Supported relocations, which are the ones the backend can produce:

| Type | Use |
|---|---|
| `R_X86_64_64` | 64-bit absolute pointer in data |
| `R_X86_64_PC32` | instruction-relative reference, for calls and jumps |
| `R_X86_64_32` / `R_X86_64_32S` | 32-bit absolute addresses, higher-half kernel |

Without `PLT`, without `GOT`, without dynamic `TLS`, without `COPY`. All linking is static and resolvable at link time.

### 12.2 Linker

| Responsibility | Detail |
|---|---|
| Input | list of `.o` files, own `.a` files, layout manifest |
| Resolution | unique global symbol; error if there are two definitions or an unresolved reference |
| File extraction | only the referenced members |
| *Garbage collection* | removes sections unreachable from `entry` and from exported symbols |
| Layout | assigns VMA/LMA according to the manifest, respects page alignment |
| Relocations | applies them and checks for 32-bit overflow |
| Output | `ET_EXEC` with `PT_LOAD` program headers (R, RX, RW), `PT_NOTE` if applicable |
| Verification | `e_entry` inside the executable segment; no segment overlap |

**There is no *linker script* dialect.** The layout is described in an own format, much smaller and with no compatibility to maintain:

```
# kernel/enlace.plan
base_virtual = 0xffffffff80000000
base_fisica  = 0x0000000000100000
entrada      = _start

segmento text  { secciones = [.text]            permisos = rx  }
segmento rodata{ secciones = [.rodata]          permisos = r   }
segmento data  { secciones = [.data, .bss]      permisos = rw  }
```

## 13. DWARF

Without this the system cannot be debugged (TC-06). Emitted:

| Section | Content |
|---|---|
| `.debug_info` | DIEs: `compile_unit`, `subprogram`, `variable`, `formal_parameter`, `base_type`, `structure_type`, `member`, `pointer_type`, `typedef`, `enumeration_type`, `subrange_type` |
| `.debug_abbrev` | abbreviations |
| `.debug_str` | strings |
| `.debug_line` | address → file/line/column map |

Quality requirements:

- Every Vala function appears with its qualified name (`Planet.Kernel.Sched.iniciar`).
- Every local variable and parameter, with type and location (`DW_OP_fbreg` or register).
- The line mapping distinguishes the method body from the signature.

Without `.eh_frame` or `.debug_frame`: stack unwinding is done with frame pointers, which the backend keeps in `debug` mode.

## 14. `.vapi`

A `.vapi` is Vala without bodies: it declares types and signatures. `planc` loads it like any other unit and resolves `extern` declarations against the linker.

Project-specific rules:

- `planetrt` `.vapi` files are written by hand and are the source of truth for the runtime's public API.
- Third-party `.vapi` files are admitted only if they do not use the constructs of §2.2.
- `[CCode(cname)]` in a `.vapi` determines the expected symbol (VL-10); the linker fails if it does not exist, instead of assuming.

## 15. Bootstrap

Explicit chain, with a verifiable fixed point (I4, TC-09, VE-03):

| Stage | Who compiles | Runtime used | Result |
|---|---|---|---|
| **0** | `valac` + the host C compiler | host GLib | `planc-0`, development binary |
| **1** | `planc-0` | `planetrt` `host` profile | `planc-1`, already compiled by `planc` |
| **2** | `planc-1` | `planetrt` `host` profile | `planc-2` |
| **3** | `planc-2` | `planetrt` `host` profile | `planc-3` |

Fixed-point criterion: **`sha256(planc-2) == sha256(planc-3)`**. From that point on, `planc-1` is the trusted compiler.

Consequences that must be respected:

1. **Bootstrap subset.** The `planc` code must be valid for `valac` and for `planc` at the same time. A whitelist of constructs and APIs is maintained, plus a lint (`planc lint --arranque`) that fails if the source uses anything outside it.
2. **Stage 0 is the only C dependency**, and it is a development one: it is not distributed, it is not linked into the system and it does not appear in any artifact of the target.
3. **The `host` profile needs to talk to the host.** That lives in `planetrt/perfil/host/` and is excluded from the `kernel` and `user` builds. It is the explicit and auditable boundary of the project: if a host symbol appears outside that directory, VE-02 fails.

## 16. Internal compiler risks

| Risk | Signal | Mitigation |
|---|---|---|
| The parser diverges from the documented grammar | Conformance cases that pass by hand and fail in the suite | EBNF grammar as source of truth and case generation |
| Incorrect constructor semantics | Half-built objects that work in simple tests | Initialization-order tests per combination |
| Register allocation bug | Failure only with many live variables | Differential *fuzzing*: the same program compiled with and without optimization |
| Struct offset computation | Subtle corruption in the kernel | Layout test against a hand-computed reference table |
| Badly applied relocations | It links, it boots, it fails on the first call | Relocation test with symbols at known distances |
| Incorrect DWARF | GDB shows the wrong line | Comparison of `bt` and `info locals` against expectation |
| The bootstrap subset breaks | `planc-0` stops compiling `planc` | Bootstrap lint in CI (TC-09) |

## 17. Recent built-in additions (`uintptr`, `char`, `unichar`, parser/codegen)

- **Pointer-integer conversion (`uintptr`)**: `uintptr.from_pointer (void*)` / `uintptr_t.from_pointer (void*)` extracts the raw address (offset `24` of `__PlancPtr`, or `0` for `null`), and `(uintptr).to_pointer ()` wraps a non-zero integer in a `__PlancPtr` (`ptr:void`). `ValaType.POINTER` equality (`==` / `!=`) compares underlying addresses.
- **Inline `char` / `unichar` methods**: `isalnum`, `isalpha`, `iscntrl`, `isdigit`, `isgraph`, `islower`, `isprint`, `ispunct`, `isspace`, `isupper`, `isxdigit`, `tolower`, `toupper`, `digit_value`, `xdigit_value`, plus `unichar.validate ()` (rejecting surrogates `0xD800..0xDFFF` and `> 0x10FFFF`) and `unichar.totitle ()`, emitted as inline x86-64 range checks without heap allocations.
- **Parser & property codegen**: `parser.vala` checks for `]` after `[` before treating a delegate-named identifier as an array type suffix in statements/casts; `codegen.vala` lowers compound assignments (`op=`) on custom properties that define both getter and setter.
- **Static-field `++` / `--`**: `codegen.vala` detects `Klass.field++` (the member target is a bare type name) with `is_type_name ()` and lowers it through the static-global lvalue path instead of calling `expr_type_full ()` on the type name. Using `is_type_name ()` rather than a plain `find_class ()` lookup keeps locals, globals, fields and consts that shadow a type name on the instance-field/property path (a local `Foo Foo` with a property `n` still goes through the getter/setter).

