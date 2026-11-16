# PlanetOS

**An operating system and its toolchain, entirely in Vala, compiled straight to
native code.**

Status: **specification plus a working compiler slice (`slice 8`) with static
types (`int`/`int8`–`int64`/`uint8`–`uint64`/`size_t`/`ssize_t`/`char`/`uchar`,
`bool`, `string`, `enum`, `errordomain`, `struct`, `T[]`, `class`, `Error`, `T?`,
`void`, `var`), a guarded arena/slab heap allocator, automatic atomic reference
counting (`--check-leaks`), single inheritance with `.rodata` vtables and
destructors, Option B compile-time non-null + guarded nullable checks
(`--no-null-check`), `throws`/`try`/`catch`/`finally`, `out`/`ref` parameters,
inline and `virtual`/`override` properties, `new Cls() { prop = expr }`
initializers, `foreach`/`switch`, `?:`/`??`, `s[start:end]` slicing, `const`,
`static`/value methods, `namespace`/`using`, forward types, and multi-file
compilation.** This repository holds the technical specification and a working
`planc` that compiles a growing Vala subset to a static x86_64 ELF with no
libc, no assembler and no external linker. The kernel and the runtime are still
specification only.

---

## 1. The three artifacts

| Artifact | What it is | The constraint that defines it |
|---|---|---|
| **`planc`** | Vala → x86_64 machine code compiler. Own frontend, IR, backend, assembler and linker. Written in Vala. Second backend target: **SPIR-V** bytecode for Vulkan shaders, from the same IR. | Emits no C. Needs no `cc`, `ld` or `as` to produce binaries, and no glslang/glslc to produce SPIR-V. |
| **`planetrt`** | Runtime and standard library: object model, strings, arrays, closures, signals, coroutines, errors, allocator. Written in Vala. | Does not wrap libc. Does not reimplement the GLib ABI. |
| **`planetos`** | Kernel and userland. Written in Vala, compiled by `planc`, linked with `planetrt`. | No libc, no POSIX, no Linux. |

The difference from the previous revision of this plan is structural: the
compiler used to be `valac` (which emits C) and the runtime used to be a GLib
clone. Now **the compiler is part of the project** and the runtime is just
another Vala library.

### The graphics track (planned)

The toolchain plans a second output target from the same IR: **shaders written
in the Vala dialect, lowered by `planc` to SPIR-V bytecode** for Vulkan — no
GLSL, no glslang, no external shader compiler in the chain. On the `host`
profile, `planetrt` will provide the Vulkan bindings to drive devices and
pipelines from Vala. Whether the target system eventually ships its own Vulkan
ICD is open (decision D-13). Requirements: TC-11, TC-12 and GX-01…GX-05 in
[docs/00-requirements.md](docs/00-requirements.md); backend design in
[docs/02-compiler.md §10.4](docs/02-compiler.md). Nothing of this is
implemented yet; it is specified so that the IR and dialect decisions made
today do not close the door tomorrow.

## 2. Invariants

These six points are not goals: they are boundary conditions. If one of them
breaks, the project stops being what it claims to be.

| ID | Invariant | How it is checked |
|---|---|---|
| **I1** | No C in the target compilation chain | `planc` produces ELF without invoking `cc`/`ld`/`as`; verified in CI by the absence of those executables in the build image |
| **I2** | No binary references libc or POSIX symbols | `nm -u` and `readelf -d` on every ELF in the system: only `planetrt` symbols |
| **I3** | No ABI compatibility with C or GLib is pursued | No signature translation layer; no `extern "C"`; C-interop-only `[CCode]` attributes are rejected |
| **I4** | The compiler is self-hosted | `planc` compiles `planc`; the fixed point is verified (stage N == stage N+1) |
| **I5** | The whole system is Vala, including privileged code | Privileged instruction bodies are `[AsmBody]` inside Vala functions, assembled by `planc` |
| **I6** | The system is not Linux and does not try to be | Own syscall ABI, no `fork`, no `execve`, no Linux process semantics |

## 3. What falls away and what appears

The pivot is not cosmetic. Removing the intermediate C **deletes five hard
problems** and **creates six**:

| Problem that disappears | Why |
|---|---|
| **Generic signal marshalling** | Measured in [E-01](docs/experiments/E01-dialect.md): `valac` already emits a typed marshaller per signal. Static dispatch is not our invention, it is the path Vala takes when it knows the signature |
| **Reflective `GType` in generics** | `valac` stores every type argument in a `gpointer` with a `GType` and two copy/destroy function pointers. Monomorphizing removes that machinery entirely |
| **Struct layout against C** | With no C, layout is our decision: no foreign alignment rules, no delegates split into `(target, destroy_notify)` |
| **The `plibc` layer** | There is no C code demanding `memcpy`, `__stack_chk_fail` or `errno`. The compiler does not emit them |
| **CFI / `.eh_frame`** | Without stack unwinding it is not needed: [E-08](docs/experiments/E08-dwarf.md) measures that GDB debugs fine with a frame pointer |

| Problem that appears | Why it is unavoidable |
|---|---|
| **Own backend** | Instruction selection, register allocation, x86_64 encoding, relocations |
| **Own linker** | Symbol resolution, archive extraction, relocation application, ELF and program headers |
| **Own assembler** | Needed for `[AsmBody]` bodies and for boot |
| **DWARF debugging** | Without it there is no way to debug a kernel written in a language of our own |
| **Bootstrap** | The compiler has to compile itself; the first stage needs an external build path |
| **Own `async` model** | Measured in [E-04](docs/experiments/E04-async.md): Vala's `async` requires GIO (`GTask`). Without GIO the awaitables have to be defined from scratch |

## 4. Specification index

| Document | Contents |
|---|---|
| [docs/00-requirements.md](docs/00-requirements.md) | Normative requirements with ID and verification method. This is the project contract |
| [docs/01-architecture.md](docs/01-architecture.md) | Layers, compilation pipeline, own ABI, memory, concurrency, repository layout |
| [docs/02-compiler.md](docs/02-compiler.md) | **`planc`**: lexer, parser, semantic analysis, IR, backend, ELF, linker, assembler, DWARF, bootstrap |
| [docs/03-runtime-and-stdlib.md](docs/03-runtime-and-stdlib.md) | **`planetrt`**: object model, strings, arrays, closures, signals, coroutines, errors, allocator, standard library |
| [docs/04-kernel.md](docs/04-kernel.md) | Boot, CPU, memory, interrupts, scheduler, syscalls, VFS, drivers |
| [docs/05-userland-and-abi.md](docs/05-userland-and-abi.md) | Syscall ABI, ELF loader, processes, shell, SDK, filesystem layout, packages |
| [docs/06-verification.md](docs/06-verification.md) | Conformance suites, bootstrap fixed point, differential oracle, QEMU harness, validation experiments |
| [docs/07-risks-and-decisions.md](docs/07-risks-and-decisions.md) | Technical risks with signal and mitigation, open decisions with closing criterion |
| [docs/experiments/](docs/experiments/README.md) | **Measurements made**, with the reproducible harness that produces them |
| [docs/planc/slice-0.md](docs/planc/slice-0.md) | **Implemented slice 0**: what `planc` compiles today, which bytes it emits, what it deliberately does not do |
| [docs/planc/slice-1.md](docs/planc/slice-1.md) | **Implemented slice 1**: variables, stack frame, the calling convention, `if`/`while`, semantic analysis |
| [docs/planc/slice-2.md](docs/planc/slice-2.md) | **Implemented slice 2**: stack arguments, global variables, `.data`/`.bss`, three-segment layout |
| [docs/planc/slice-3.md](docs/planc/slice-3.md) | **Implemented slice 3**: `int`/`string`/`void` type checking, `var`, string ABI layout, `R_X86_64_64` data relocations, `@"..."` formatting |
| [docs/planc/slice-4.md](docs/planc/slice-4.md) | **Implemented slice 4**: 16-byte `string` header ($O(1)$ `.length`), bounds-checked `s[i]` (`--no-bounds-check`), `bool`, `for`/`break`/`continue`, bitwise ops, `enum`, `struct` |
| [docs/planc/slice-5.md](docs/planc/slice-5.md) | **Implemented slice 5**: guarded arena/slab heap allocator, automatic atomic ARC (`--check-leaks`), `T[]`, `s1 + s2`, value `@"..."` templates |
| [docs/planc/slice-6.md](docs/planc/slice-6.md) | **Implemented slice 6**: `class` objects, `.rodata` vtables, `virtual`/`override`/`abstract`, `: base(...)`, destructors, `is`/`as`/casts, Option B `T` vs `T?` null safety (`--no-null-check`) |
| [docs/planc/slice-7.md](docs/planc/slice-7.md) | **Implemented slice 7**: `foreach`, `switch` (VL-14), `s[start:end]` slicing, `?:`/`??` (`T? ?? T -> T`), `const`, `static`/`enum`/`struct` methods, `0x`/`0b`/char literals, integer aliases |
| [docs/planc/slice-8.md](docs/planc/slice-8.md) | **Implemented slice 8**: `errordomain`/`throws`/`try`/`catch`/`finally` (`(rax, rdx)` ABI), `out`/`ref` parameters, inline and `virtual` properties, object initializers, `namespace`/`using`, forward types, multi-file compilation |

## 5. State of the measurements

The specification distinguishes **decisions** (we make them) from
**assumptions** (they must be measured). Seven assumptions are already answered
with reproducible measurement:

| Assumption | Measured result | Evidence |
|---|---|---|
| Constructs Vala accepts | 39 cases, 29 compile; the rejections are language rules | [E-01](docs/experiments/E01-dialect.md) |
| Generics | `valac` erases the type and boxes with `GType`; we monomorphize | [E-01 §3](docs/experiments/E01-dialect.md) |
| Delegates | `valac` uses `fn` + a `(target, destroy_notify)` pair; we use a fat pointer | [E-01 §4](docs/experiments/E01-dialect.md) |
| Construction order | defaults → `construct` properties → `construct` block → body | [E-01 §5](docs/experiments/E01-dialect.md) |
| `async` | tied to GIO; the shape is reusable, not the API | [E-04](docs/experiments/E04-async.md) |
| `[CCode]` attributes | `cheader_filename` ×752 forces rejection at the point of use | [E-06](docs/experiments/E06-vapis.md) |
| DWARF without CFI | GDB debugs with a frame pointer and no `.eh_frame` | [E-08](docs/experiments/E08-dwarf.md) |

Reproducible without root:

```sh
experiments/oracle/install.sh
. experiments/oracle/env.sh
experiments/e01-dialect/run.sh
```

`valac` is used **only as a development oracle**. It appears in no artifact of
the system.

### What the toolchain does today

```sh
./planc/build.sh
printf 'int fact(int n) {\n    if (n <= 1) { return 1; }\n    return n * fact(n - 1);\n}\nint main() {\n    var r = fact(5);\n    print(@"fact(5)=$r\n");\n    return r;\n}\n' > /tmp/fact.vala
./planc/build/planc /tmp/fact.vala -o /tmp/fact
/tmp/fact; echo $?     # prints fact(5)=120 and exits 120 under the project ABI
./planc/tests/run.sh   # 146 cases, 146 pass
```

The accepted subset now covers `int`/`int8`–`int64`/`uint8`–`uint64`/`size_t`/
`ssize_t`/`char`/`uchar`/`bool`/`string`/`enum`/`errordomain`/`struct`/`T[]`/
`class`/`Error`/`T?`/`void` functions and methods (`static`, `virtual`,
`override`, `abstract`, plus `enum`/`struct` methods) with value, `out`, and
`ref` parameters (any number; beyond the sixth they travel on the stack),
`const` declarations, local `var` type inference, 64-bit integer (hex `0x`,
binary `0b`, char `'x'`, underscore/suffix literals) and bitwise expressions,
comparisons, short-circuit logic, ternary `?:`, lazy null-coalescing `??`
(`T? ?? T` -> non-null `T`), guarded arena + size-class heap allocation,
compiler-inserted atomic reference counting (leak-checkable via
`--check-leaks`), single-inheritance `class` hierarchies with `.rodata`
vtables, `: base(...)` constructor chaining, inline and custom/`virtual`/
`override` properties (`{ get; set; default = ...; }`), `new Cls() { prop =
expr }` object initializers, `~Destructor()` hierarchical cleanup,
`throws`/`throw`/`try`/`catch`/`finally` checked error propagation via
`(rax, rdx)`, `is`/`as`/checked casts, Option B null safety (compile-time `T` +
flow narrowing + `--no-null-check` opt-out on unnarrowed `T?`), dynamic arrays
(`new T[n]`, array literals, `.length`, bounds-checked `arr[i]` reads/writes,
retained `foreach`), `string` literals/variables/globals with 16-byte ABI
headers, concatenation (`s1 + s2`), bounds-checked slicing (`s[start:end]`),
value-producing `@"..."` templates, $O(1)$ `.length`, bounds-checked `s[i]`
(`--no-bounds-check`), `==`/`!=` string and reference comparisons, `if`/`else`,
`switch`/`case`/`default` (VL-14), `while`, `for`/`break`/`continue`,
`+=`/`-=`/`++`/`--`, value-semantics `struct`s, `owned`/`unowned` syntax hints,
`namespace`/`using` blocks, cross-file forward types, multi-file CLI inputs,
global variables with `.data`/`.bss` (`R_X86_64_64` relocations for string
globals), and `print` / `exit` builtins.
The calling convention is the project ABI (§3.1 of [01-architecture.md](docs/01-architecture.md)):
arguments in `rdi`–`r9` plus stack, return in `rax` (plus `Error*` in `rdx`
for `throws` functions), `rbp` frame pointer, 16-byte stack alignment at every
call, no red zone.

Produced binaries have three `PT_LOAD` segments (R|X, R and RW — never RWX,
and never one page mapped with two permission sets), an empty `nm -u`, a
`.symtab` that makes `objdump -d` and `gdb` work, and byte-identical output
across runs. See [docs/planc/slice-8.md](docs/planc/slice-8.md).

## 6. Changes from the previous revision

| Before | Now |
|---|---|
| `valac` + `gcc` with an own sysroot | `planc`, an own compiler that emits machine code |
| A clone of the GLib ABI (`g_malloc`, `g_object_new`…) | An own Vala standard library, with no inherited names or ABI |
| A `plibc` layer with `memcpy`/`printf`/`malloc` | It does not exist: there is no C demanding it |
| libffi or generated *marshallers* for signals | Static dispatch generated by the compiler |
| Reflective `GType`/`GValue` | Static type descriptors, generated on demand |
| Effort estimates, calendar, time-boxed phases | Requirements, invariants and verification criteria |
