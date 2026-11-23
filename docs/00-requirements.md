# 00 — Normative requirements

This document is the project contract. Every requirement has a stable identifier and a verification method. If a requirement has no verification, it is not a requirement: it is an intention.

Convention: **MUST** (mandatory), **SHOULD** (expected, with justification for deviating), **MAY** (optional).

## 1. Compilation requirements (TC)

| ID | Requirement | Verification |
|---|---|---|
| **TC-01** | `planc` MUST produce ELF64 `ET_EXEC` executables and `ET_REL` objects for `EM_X86_64` | `readelf -h` on the output |
| **TC-02** | `planc` MUST NOT invoke any C compiler, assembler or external linker | Execution trace (`strace -f -e trace=execve`) with no `cc`, `as`, `ld`, `collect2` |
| **TC-03** | The linker MUST be part of `planc` and resolve every relocation that `planc` emits | Linking a program with symbols crossing between two objects |
| **TC-04** | The assembler MUST accept the `[AsmBody]` bodies of the system tree | Compilation of the complete kernel |
| **TC-05** | The output MUST be reproducible: same input, same hash | Two compilations in different directories, identical `sha256` |
| **TC-06** | `planc` MUST emit DWARF that lets GDB show Vala names, lines and variables | `gdb -batch -ex bt` on a test binary built with `-g` |
| **TC-07** | `planc` MUST reject, with a diagnostic, any `[CCode]` that only makes sense for C interop | Negative case suite |
| **TC-08** | Compilation errors MUST include file, line, column and a stable message in English | Diagnostic suite |
| **TC-09** | `planc` MUST be able to compile its own source code | Complete bootstrap, see [06](06-verification.md#2-bootstrap-fixed-point) |
| **TC-10** | The compiler MUST fix and version the dialect it accepts | `docs/dialect.md` document + conformance test per version |
| **TC-11** | `planc` MUST lower Vala functions annotated as shaders to SPIR-V binary modules, with its own serializer and no external shader compiler in the chain | `planc --target=spirv`; `spirv-val` in CI; no `glslang`/`glslc`/`dxc` invocation (same `strace` rule as TC-02) |
| **TC-12** | In shader mode, `planc` MUST reject with a positioned diagnostic every construct that the SPIR-V execution model cannot express (recursion, allocation, pointers as values, exceptions) | Negative case suite against [02 §10.4](02-compiler.md) |

## 2. Language requirements (VL)

| ID | Requirement | Verification |
|---|---|---|
| **VL-01** | The compiler MUST accept the core of the Vala language: classes, interfaces, structs, enums, delegates, generics, lambdas, `async`, `throws`, `lock`, `foreach`, properties | Conformance suite |
| **VL-02** | `[Compact]`, `[SimpleType]`, `[IntegerType]` and `[PointerType]` MUST have defined semantics (layout and parameter passing) | Layout tests |
| **VL-03** | Property semantics (`owned`, `unowned`, `weak`) MUST respect Vala's reference model | Refcount tests |
| **VL-04** | `string` MUST be UTF-8, immutable and reference-counted | String tests |
| **VL-05** | Arrays MUST carry their own length and reference count; the layout is the compiler's decision | Array tests |
| **VL-06** | `signal` MUST compile to static dispatch: handlers as typed function pointers, connection by signal identifier, with no `GValue` and no *trampolines* generated at run time. Measured in [E-01](experiments/E01-dialect.md): `valac` already generates a static marshaller, so libffi is not needed | Inspection of the generated code |
| **VL-07** | `throw`/`catch`/`finally` MUST compile to explicit propagation without stack unwinding. `finally` MUST be lowered to a label or to edge duplication, never to `setjmp` ([E-01](experiments/E01-dialect.md)) | Nested error tests |
| **VL-08** | `async`/`yield` MUST compile to a resumable function with explicit state. The state MUST go to the heap by default; the stack is an optimisation that requires conservative escape analysis. The `for` MUST carry an increment control flag so that `yield` and `continue` do not duplicate it ([E-04](experiments/E04-async.md)) | Coroutine tests, including `yield` inside a loop |
| **VL-09** | `[AsmBody]` MUST allow privileged instructions to be written inside a Vala function | Kernel boot |
| **VL-10** | `[CCode(cname)]` MUST be used only as the symbol name in the ELF; the remaining `[CCode]` attributes MUST be ignored with a warning when they are used, not when the `.vapi` is loaded ([E-06](experiments/E06-vapis.md)) | Exported symbol test |
| **VL-11** | There MUST be no `va_list` and no user variadic functions. **Own justification:** `valac` does accept them because it lowers them to C varargs; `planc` has no C ABI and cannot build a variadic frame. Formatting is intrinsic to the compiler and is verified at compile time | Negative case: invalid format or varargs do not compile |
| **VL-12** | Argument evaluation order MUST be defined left to right. Measured in [E-01](experiments/E01-dialect.md): `valac` inherits a right-to-left order from C. It is a deliberate dialect difference | Observable order test |
| **VL-13** | A delegate MUST be a two-word value `{code, environment}`. Measured in [E-01](experiments/E01-dialect.md): `valac` splits `(target, destroy_notify)` into out parameters by inheritance from `GCallback`/`user_data` | Delegate size and passing test |
| **VL-14** | The compiler MUST enforce the measured restrictions of the language: `switch` only over integer, enum or string; `lock` only over members of the current class; `main` does not throw; no fixed-size arrays; no generic constraints ([E-01](experiments/E01-dialect.md)) | Negative cases |
| **VL-15** | Generics MUST be monomorphized. **Declared deviation:** `valac` uses type erasure with `GType` and boxing, which requires a run-time type registry incompatible with I3 ([E-01 §3](experiments/E01-dialect.md#3-generics-erasure--boxing-not-monomorphization)) | Layout test per instantiation |

## 3. Runtime requirements (RT)

| ID | Requirement | Verification |
|---|---|---|
| **RT-01** | `planetrt` MUST NOT reference any libc, libm or POSIX symbol | `nm -u libplanetrt.a` against a whitelist |
| **RT-02** | The allocator MUST have a backend selectable at compile time: `host`, `kernel`, `user` | Three builds of the same source |
| **RT-03** | Reference counting MUST be atomic and race-free under concurrency | Multi-threaded stress test |
| **RT-04** | The runtime MUST report leaks and double frees in the `host` profile with exact counters | Test with `alloc_count == free_count` |
| **RT-05** | Signals MUST support connection, disconnection and nested emission with Vala's ordering | Ordering tests |
| **RT-06** | The runtime MUST work without allocation on the signal emission path | Allocator test with the counter locked |
| **RT-07** | The standard library MUST be Vala code compiled by `planc`, not third-party precompiled binaries | Provenance of the tree |
| **RT-08** | Floating-point number formatting MUST be correct (exact round trip in decimal notation) | Tests against the oracle |
| **RT-09** | Unicode tables MUST be generated from `UnicodeData.txt` at build time, not maintained by hand | Versioned generation script |

## 4. Kernel requirements (KR)

| ID | Requirement | Verification |
|---|---|---|
| **KR-01** | The kernel MUST boot on x86_64 via Limine in higher-half mode | Boot in QEMU |
| **KR-02** | The kernel MUST NOT reference libc symbols | `nm -u planet-kernel` |
| **KR-03** | Memory MUST be W^X: no writable and executable page | Flag check in the VMM and in the loader |
| **KR-04** | The kernel MUST be preemptive and support N concurrent threads | Atomic counter test |
| **KR-05** | Every exception MUST have its own handler; none may cause a silent reboot | Injected exception suite |
| **KR-06** | The panic MUST dump enough state to diagnose without GDB | Controlled panic test |
| **KR-07** | User pointer accesses MUST be validated and recoverable | Invalid pointer test from userland |
| **KR-08** | The kernel MUST be compiled with the same `planc` as the userland | Single build |
| **KR-09** | The per-thread CPU state (including SIMD) MUST be preserved across a context switch | Register round-trip test |

## 5. Userland requirements (US)

| ID | Requirement | Verification |
|---|---|---|
| **US-01** | The loader MUST execute static ELF64; it MUST reject `PT_INTERP` | Loader tests |
| **US-02** | Each process MUST have an isolated address space | Out-of-range write test |
| **US-03** | Process creation MUST be `proc_spawn`; there MUST be no `fork` | Syscall catalogue |
| **US-04** | The shell MUST support pipes, redirection and variable substitution | Shell suite |
| **US-05** | The SDK MUST be reduced to `planc` + `planetrt` + its own `.vapi` descriptors | Package contents |
| **US-06** | A user program MUST be compiled with the SDK and run on the system | End-to-end test |
| **US-07** | The system MUST expose introspection under `/info` with a stable format | Format test |

## 6. Verification requirements (VE)

| ID | Requirement | Verification |
|---|---|---|
| **VE-01** | Every suite MUST be runnable in the `host` profile without QEMU | `planc test --profile=host` |
| **VE-02** | CI MUST fail if a forbidden symbol appears in any binary | `symbol-audit` job |
| **VE-03** | CI MUST verify the fixed point of the bootstrap | `bootstrap` job |
| **VE-04** | CI MUST boot the system and obtain a deterministic exit code | `boot` job with `isa-debug-exit` |
| **VE-05** | The guest tests MUST run inside the real system | `guest` job |
| **VE-06** | No requirement MUST be considered met without its verification green | Requirement → job traceability |

## 7. Graphics requirements (GX)

The toolchain plans two output targets: native code for the system and SPIR-V for shaders. These requirements fix what "writing shaders and interacting with Vulkan" means, so that they do not become an intention:

| ID | Requirement | Verification |
|---|---|---|
| **GX-01** | A shader MUST be written in the same Vala dialect, compiled by the same `planc` frontend and lowered to SPIR-V by the same IR. There MUST be no second shader language and no GLSL in the chain | Shader example in the suite: one Vala source, one `.spv` output |
| **GX-02** | The SPIR-V output MUST be byte-deterministic (TC-05) and MUST pass `spirv-val`; `spirv-dis` MUST round-trip it | CI job comparing against golden `spirv-dis` files |
| **GX-03** | On the `host` profile, `planetrt` MUST provide Vulkan bindings to drive device, swapchain, pipelines and descriptor sets from Vala. The bindings live only in the host profile directory: a symbol audit MUST show none of them in a target-system binary (same rule as R-19/VE-02) | Host sample renders a triangle; symbol audit of a target build is clean |
| **GX-04** | The shader dialect restrictions (TC-12) MUST be enforced by `planc`, not by discipline: a construct that SPIR-V cannot express never reaches the backend | Negative cases |
| **GX-05** | Whether the target system ships its own Vulkan ICD (driver inside `planetos`) or only consumes SPIR-V through the host profile is an open decision (**D-13**). Nothing in the toolchain design may assume either answer | Decision closed in [07](07-risks-and-decisions.md) |

## 8. Device I/O requirements (IO)

The data path is specified in [08](08-io-data-path.md). `KR-07` and `US-02`
are its prerequisites, not its consequences.

| ID | Requirement | Verification |
|---|---|---|
| **IO-01** | Handles MUST be per-process opaque values with a rights mask. No process may name another process's handle, and no syscall may accept a global slot index as a capability | Cross-process handle test; a forged value returns `E_BAD_HANDLE` |
| **IO-02** | Physical frames MUST be granted only through a handle that owns them. No syscall may map an arbitrary physical address into a process | Mapping an unowned frame fails; the compositor `SharedSurface` works through the grant |
| **IO-03** | User pointers MUST be validated against the caller's page table and MUST be recoverable on fault (`KR-07`), including descriptors read by the kernel | Invalid pointer returns an error and the calling task survives |
| **IO-04** | Byte devices MUST be reachable as `Gio` streams over a handle. Line discipline, framing transforms and protocol logic MUST run in userland, not in ring 0 | `/dev` case: open, filter chain and line-discipline test |
| **IO-05** | Framed devices MUST use a descriptor ring whose entries the kernel validates before the doorbell. While there is no IOMMU, userland MUST NOT program MMIO or DMA | A malformed descriptor is rejected without touching the device; no BAR is mapped to userland |
| **IO-06** | Readiness MUST be reported per handle by `SYS_POLL`; the event loop MUST NOT busy-poll, and no driver completion may depend on a bounded spin | Poll test with timeout; no spin loop in the block path |

## 9. Non-requirements

Explicit, so that they do not slip in as implicit goals:

| Not done | Reason |
|---|---|
| Binary or source compatibility with GLib/GIO | Invariant I3. The standard library is our own |
| Compiling Vala to C, not even as an intermediate debugging step | Invariant I1 |
| C-compatible ABI, `dlopen`, FFI | No consumers; it drags in foreign rules |
| POSIX, Linux, Linux ELF with `PT_INTERP` | Invariant I6 |
| `fork`, `execve`, POSIX signals | Our own process model |
| Multiple architectures | x86_64 is the only one that defines the backend. SPIR-V is a shader target of the same IR (TC-11), not a second CPU architecture |
| GLSL, HLSL or any second shader language | The dialect is Vala; a shader is Vala restricted by the execution model (GX-01) |
| Multiple object formats or dynamic linking | One format, one linker, static |
| GObject instances, vtables or signals crossing the kernel/user boundary | The boundary is handles and rings; a kernel vtable in userland is a ring-0 call primitive |
| Userland MMIO or DMA programming without an IOMMU | A driver bug becomes an arbitrary physical write; deferred to D-15 |
| A kernel-side STREAMS framework with `M_DATA`/`M_PROTO` messages | Protocol logic belongs to the LibOS; the kernel keeps bytes and descriptor rings |
| Compiler-proved exclusive ownership of I/O buffers | `planc` is ARC, not a linear type system; buffer leases are enforced at run time |
| Cycle collection | Vala's model is reference counting; cycles are the responsibility of the code |
