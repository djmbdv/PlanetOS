# 07 — Risks and decisions

## 1. Criterion

A risk is useful if it meets two conditions: **it can be detected before it is too late** and **it has a concrete technical response**. Risks without a signal or a response are comments, not risks.

Impact scale:

| Value | Meaning |
|---|---|
| 1 | Annoying; it is fixed locally |
| 2 | It breaks a requirement and forces part of the design to be redone |
| 3 | It breaks a project invariant |
| 4 | It invalidates a complete artifact (`planc`, `planetrt`, `planetos`) |

## 2. Compiler risks

| ID | Risk | Prob. | Imp. | Signal | Response |
|---|---|---|---|---|---|
| **R-01** | The parser diverges from the documented grammar | High | 2 | Cases that pass by hand and fail in the suite | EBNF grammar as source of truth; generation of cases from it |
| **R-02** | Constructor semantics do not match Vala | High | 2 | Half-built objects that pass simple tests | Initialization-order suite by combination of `this()`/`base()`/`construct` |
| **R-03** | Monomorphization of generics inflates the kernel binary | Medium | 2 | Kernel size grows with each instantiation | Share code by type descriptor when all arguments are reference types |
| **R-04** | Escape analysis of closures is incorrect | Medium | 3 | Stack box that outlives the function, or leak from an unnecessary box | Conservative mode: every box that is not proven local goes to the heap; the analysis only optimizes |
| **R-05** | The lowering of `async` does not cover all cases | High | 2 | `yield` inside nested loops or inside `try` produces inconsistent states. **Measured:** `valac` resolves the loop with an increment flag; omitting it duplicates the increment on resume ([E-04](experiments/E04-async.md)) | The flag is mandatory in the lowering, not an optimization. Conformance suite with `yield` in `for`, `while`, `do`, nested `if` and inside `try` |
| **R-06** | Closing `lock` on error edges is forgotten | Medium | 3 | Deadlock reproducible only when a function throws | The lowering generates the close on every edge, without analysis; test by combination |
| **R-07** | Register allocation bug | High | 2 | Failure only with many live variables | Differential: same program with and without optimization; *fuzzing* of intervals |
| **R-08** | Incorrect computation of struct offsets | Medium | 3 | Subtle corruption in the kernel | Reference layout table computed by hand; test per structure |
| **R-09** | Relocations applied incorrectly | Medium | 3 | It links, it boots, it fails on the first call | Test with symbols at known distances, including 32-bit overflow |
| **R-10** | Incorrect DWARF | High | 1 | GDB shows wrong lines or variables | Compare `bt` and `info locals` against the declared expectation |
| **R-11** | The `[AsmBody]` assembler does not cover a necessary instruction | Medium | 2 | The HAL does not compile | Closed list of instructions with a test case per instruction |
| **R-12** | The bootstrap subset breaks | Medium | 3 | `planc-0` stops compiling `planc` | Lint `planc lint --arranque` in CI and a versioned whitelist |
| **R-13** | The compiler is not deterministic | Medium | 3 | The fixed point does not converge | Forbid unordered dictionary iteration, absolute paths and timestamps in the output |

## 3. Runtime and system risks

| ID | Risk | Prob. | Imp. | Signal | Response |
|---|---|---|---|---|---|
| **R-14** | Reference count imbalance | High | 2 | Premature releases or leaks | Exact counters in the `host` profile; test `reserves == releases` in every suite |
| **R-15** | `unref` with a lock taken | Medium | 3 | Sporadic deadlock | Documented rule; audit in review; the compiler cannot detect it |
| **R-16** | Signal emission allocates memory | Medium | 2 | Failure in IRQ context | Test with the allocator blocked (RT-06) |
| **R-17** | Inexact decimal formatting of floats | High | 1 | Numbers that do not return to their value | Round-trip test against the oracle (RT-08) |
| **R-18** | `pfs` is corrupted after a cut | Medium | 2 | Files that disappear or an inconsistent tree | Minimal journal and simulated-cut test |
| **R-19** | The `host` profile leaks dependencies into the target | Medium | 3 | Host symbol in a binary of the system | Audit by directory: `perfil/host` is the only allowed place (VE-02) |
| **R-20** | A primitive is missing in `planetrt` for the kernel | Medium | 2 | The kernel needs something that existed only in the host libc | Explicit inventory of primitives by profile; if one is missing, it is added to the profile contract |
| **R-21** | The ABI changes between compiler versions | Medium | 3 | Old binaries stop working | Freeze the ABI per major version; `abi_version` in structures |
| **R-22** | QEMU hides hardware failures | Medium | 2 | Everything green in CI | Test on a known physical machine before declaring stability |
| **R-23** | Semantic ambiguity in Vala edge cases | Medium | 2 | Two implementations disagree | The differential oracle decides; the decision is documented in `dialecto/` |
| **R-24** | Reusing Vala semantics where they depend on GIO or `GType` | High | 2 | A new module requires `gio-2.0` like `async`, or a `GType` like generics | Check with `valac -C` before designing: if the generated C mentions `g_task_*`, `g_type_*` or `GValue`, the API is **not** reused ([E-01](experiments/E01-dialect.md), [E-04](experiments/E04-async.md)) |
| **R-25** | The dialect drifts so far from Vala that the code of `planc` stops being portable to `valac` | Medium | 3 | `planc-0` (via `valac`) starts rejecting the source of `planc` | The code of `planc` is limited to the common subset; the extensions (`[AsmBody]`, `[Inline]`, `[NoAtomico]`, thick delegate) are not used inside `planc` itself |
| **R-26** | The local oracle diverges from the `valac` that another developer uses | Medium | 1 | Two people obtain different diagnostics from the same source | The oracle version is pinned in [experiments/oracle/install.sh](../experiments/oracle/install.sh) and it is recorded with each measurement |
| **R-27** | An IR operation has no SPIR-V equivalent and the shader backend diverges from the native one | Medium | 2 | A shader compiles to x86_64 and fails to lower to SPIR-V (or the reverse) | The restriction table of [02 §10.4](02-compiler.md) is enforced by the frontend (TC-12), not by the backend; differential suite: every shader case must lower cleanly and pass `spirv-val` |
| **R-28** | The Vulkan host bindings leak into a target-system binary | Medium | 3 | A symbol of the graphics profile appears in a kernel or userland build | GX-03 keeps them in the `host` profile directory only; symbol audit per build (VE-02) |
| **R-29** | The current I/O substrate is not a capability system: one global fd table and `SYS_MAP_USER_AT` accept arbitrary physical addresses | High | 3 | A second process reads or closes another's fd, or maps a frame it does not own; `SharedSurface` already depends on it | Phase A1-A2 of [08](08-io-data-path.md): per-process handles with rights and `SYS_GRANT`; cross-process denial test before any driver work |
| **R-30** | A userland driver programs DMA and overwrites memory it does not own | High if attempted | 4 | A driver bug corrupts the kernel or another process; QEMU has no IOMMU | The kernel owns the doorbell and validates every descriptor (IO-05). Userland MMIO is gated on D-15 and an IOMMU |
| **R-31** | A userland protocol stack blocks the main loop or copies per stage | High | 2 | One blocked `read` stalls every source; throughput collapses on packet paths | Coroutines for stream stages (VL-08), buffered byte streams, rings for framed devices |
| **R-32** | `SYS_POLL` does not report real readiness and its capacity is too low | High | 2 | The loop spins on an open file, or watches past 8 sources are dropped | IO-06: handle-scoped readiness, dynamic watch array, no busy-poll |
| **R-33** | Scanout stays a copy even when app/compositor is zero-copy | Medium | 1 | Frame time is dominated by `SYS_FB_BLIT_RECT` | Grant the framebuffer to the compositor and double-buffer; measured separately from the ring work |
| **R-34** | The coroutine runtime cannot link into a program that imports a `.dlib` | High | 3 | `planc` fails with `call target out of range for __planc_async_enqueue`; observed with the unqualified `Mutex` intrinsic in `sys_demo`, which imports `glib.dlib` | Reproduced while adding the ThreadPool test. Until the linker resolves the async runtime against imports, dlib consumers must use `RecMutex`/`Cond` (or `Channel` outside async contexts); regression case pending |

## 4. Open decisions

Each one is closed with a technical criterion, not with a date.

| ID | Decision | Alternatives | Closure criterion |
|---|---|---|---|
| **D-01** | Dialect scope | All of Vala / documented subset | Everything the conformance suite covers is accepted; the rest is diagnosed and documented, it is never accepted halfway |
| **D-02** | Generics | Full monomorphization / shared by descriptor | **Closed by measurement** ([E-01 §3](experiments/E01-dialect.md#3-generics-erasure--boxing-not-monomorphization)): `valac` erases the type and boxes with `GType`, a model that requires type registration at run time and violates I3. It is monomorphized. Shared code remains as an optional optimization, verified by differential oracle |
| **D-03** | Optimization level | Folding and DCE only / + inlining / + more | An optimization is added only if there is a differential test that detects its error |
| **D-04** | Link layout format | Own format / subset of *linker script* | Own format as long as there is no case that needs the foreign syntax |
| **D-05** | `refcount` atomicity in the kernel | Always atomic / `[NoAtomico]` annotation | The annotation is allowed only with a stress test that proves that there are no races on that type |
| **D-06** | `glib-src` source layer | No layer / compatibility `.vapi` | It is implemented only if Vala code worth reusing shows up; no ABI involved |
| **D-07** | DWARF richness | Minimal DIEs / complete | Minimal ones that allow `bt` and `info locals` with correct types |
| **D-08** | Allocation of the coroutine state | Always on the heap / on the stack when it does not escape | Stack only if the analysis is conservative and the differential test confirms it |
| **D-09** | Assembler | Closed subset / general assembler | Closed; every instruction added requires its test |
| **D-10** | Scheduler / event loop relationship | Loop over scheduler / scheduler over loop | Own scheduler, event loop on top: the scheduler needs timing guarantees that a generic loop does not give |
| **D-11** | Package format | Own / reuse an existing one | Own as long as the manifest is the only database needed |
| **D-12** | Dialect name and version | — | It is fixed together with the first stable version of the ABI; from then on, changes with a major version |
| **D-13** | How Vulkan reaches the system: host-profile bindings only / own Vulkan ICD inside `planetos` (own driver stack: kernel driver + ICD loader + layers) | The toolchain side is the same either way: SPIR-V from the same IR (TC-11). It closes when the system has a GPU driver with command submission working in QEMU/virtio-gpu or on real hardware; until then, GX-03 (host bindings) is the only commitment |
| **D-14** | I/O data path: **two contracts**, byte streams and validated descriptor rings, adopted in [08](08-io-data-path.md). The physical driver and the doorbell stay in ring 0; protocol logic runs in userland | One `Gio` stream for every device / kernel-side STREAMS framework with `M_*` messages | It closes when IO-01 to IO-06 are green and the phase exit criteria of 08 §8 are met |
| **D-15** | Userland drivers: kernel doorbell with descriptor validation now; userland MMIO and DMA only under an IOMMU later | Userland MMIO without an IOMMU / never allow userland drivers | It closes only with a userland driver that crashes or misbehaves and leaves the kernel and other processes intact, plus a DMA containment test. Until then, no BAR is mapped to userland |

## 5. Reformulation conditions

They are not dates or budgets: they are technical states that force the plan to change.

| # | Condition | Consequence |
|---|---|---|
| **C-01** | The fixed point does not converge after removing the known sources of non-determinism | The compiler is not reliable: the dialect is frozen and the scope is reduced before continuing |
| **C-02** | The accepted dialect does not allow compiling `planc` (the bootstrap subset is empty) | Self-hosting is not viable as proposed; the compiler must be extended with the host as the only support |
| **C-03** | A requirement of [00](00-requirements.md) turns out to be impossible with the chosen architecture | The requirement is reviewed, not the architecture: a broken invariant invalidates the project |
| **C-04** | The kernel requires a primitive that cannot exist in any profile | The profile contract is incomplete: it is corrected before continuing |
| **C-05** | The symbol audit cannot come out empty in any build | The system is not what it says it is (I2); new functionality is stopped until it is resolved |

## 6. Discarded alternatives

| Alternative | Technical reason for discarding |
|---|---|
| Emitting C and compiling it | It is exactly invariant I1 that the project denies |
| Reusing `valac` as a backend | It emits C; there is no way to ask it for machine code |
| Cloning the GLib ABI | The API can be reimplemented, but the ABI contributes nothing without C (I3) |
| Using an external assembler and linker | It breaks I1 and ties the project to binutils |
| Interpreter or virtual machine instead of native code | The requirement is to compile to native (TC-01) |
| Cycle collector | It changes the memory model of the language; it is not a requirement |
| Microkernel with intensive IPC | It unblocks no requirement; it multiplies the cost of every call. Note: protocol stacks in userland over kernel-validated rings are **not** this alternative; the physical driver and the doorbell stay in ring 0 ([08](08-io-data-path.md)) |
| Shared libraries and `dlopen` | There is no requirement; it adds a dynamic loader and its error surface |
| GObject instances, vtables or signals crossing kernel/user | A kernel vtable in userland is a ring-0 call primitive, not an abstraction boundary |
| Userland MMIO or DMA programming without an IOMMU | It turns any driver bug into arbitrary physical writes; gated on D-15 |
| Kernel-side STREAMS framework with `M_DATA`/`M_PROTO` messages | It puts protocol logic and message allocation back in ring 0, which is what [08](08-io-data-path.md) removes |

## 7. Note on licenses

Relevant facts, without interpretation:

- `valac` is free software under LGPL-2.1-or-later. It is used **only in stage 0 of the bootstrap** and it is not part of the delivered system.
- GLib is under LGPL-2.1-or-later. The project does not link it or copy its code; it only shares concept names (objects, signals, references) that are design ideas, not implementation.
- The `.vapi` files that are distributed are written in this project to describe `planetrt`.
- `planc`, `planetrt` and `planetos` are our own code. The license is set in `LICENSE`; its choice does not affect any technical requirement.
- If at some point code from a third-party library is copied, the license must be reviewed before integrating it. It is a process rule, not a technical risk.

## 8. Review

The risk table is updated when:

- a risk materializes: the entry and the response that worked are added;
- a validation experiment closes a `[V]` assumption: the associated risk changes probability or disappears;
- a requirement changes: the risks whose impact depended on it are reviewed.

A risk that disappears from the table without an entry that explains it is a hidden risk.
