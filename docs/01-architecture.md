# 01 — Architecture

## 1. Pipeline

```
┌──────────────┐   ┌──────────┐   ┌───────────┐   ┌─────────┐   ┌──────────┐
│  .vala       │   │          │   │           │   │         │   │          │
│  .vapi       │──▶│ frontend │──▶│    IR     │──▶│ backend │──▶│ ELF .o   │
│  [AsmBody]   │   │          │   │  (SSA)    │   │ x86_64  │   │          │
└──────────────┘   └──────────┘   └───────────┘   └─────────┘   └────┬─────┘
                                                                     │
                    ┌────────────────────────────────────────────────┘
                    ▼
              ┌────────────┐   ┌───────────────┐   ┌───────────────────┐
              │  linker    │──▶│ ELF executable│──▶│ bootable image    │
              │  (pl-ld)   │   │  ET_EXEC      │   │ ISO / disk        │
              └────────────┘   └───────────────┘   └───────────────────┘
```

There is no box that receives or emits C. `planc` is at the same time compiler, assembler (for `[AsmBody]`) and linker.

The IR is the shared frontier of two backend targets: x86_64 machine code for the system, and **SPIR-V bytecode for shaders** ([02 §10.4](02-compiler.md)). A shader is not a second language and does not pass through GLSL: it is Vala, the same frontend, a different final encoding (GX-01).

## 2. System layers

```
┌────────────────────────────────────────────────────────────────────┐
│ USERLAND (Vala)                                                    │
│ init · shell · utilities · apps                                    │
├────────────────────────────────────────────────────────────────────┤
│ planetrt   "user" profile                                          │
│ objects · strings · arrays · closures · signals · coroutines       │
│ allocator over mem_map/brk                                         │
├────────────────────────────────────────────────────────────────────┤
│ SYSCALL ABI          rax=nr · rdi rsi rdx r10 r8 r9 · syscall      │
├────────────────────────────────────────────────────────────────────┤
│ KERNEL (Vala)                                                      │
│ sched · vmm · pmm · vfs · ipc · irq · time                         │
│ planetrt   "kernel" profile   (same code, different backend)       │
├────────────────────────────────────────────────────────────────────┤
│ HAL x86_64   GDT · IDT · TSS · APIC · paging · MSR · ports         │
├────────────────────────────────────────────────────────────────────┤
│ _start  [AsmBody]  →  kmain  (Vala)  →  planet_kernel_main         │
└────────────────────────────────────────────────────────────────────┘
```

`planetrt` is **the same source code** with three compilation profiles. The profile is not a C macro: it is a `planc` argument that selects the implementation of the allocator, of the type registry and of the lock at compile time.

| Profile | Allocator | Lock | Log | Time |
|---|---|---|---|---|
| `host` | the host's | host threads | standard output | host clock |
| `kernel` | slab + buddy | spinlock with IRQ disabling | UART / framebuffer | TSC + HPET |
| `user` | arena over `brk` + `mem_map` | futex over channels | `sys_debug_write` | `time_mono` |

Interface that each profile satisfies, written in Vala:

```vala
// planetrt/profile/Planet.Profile.vala
public interface Allocator : Object {
    public abstract void*  reserve(size_t n, size_t alignment);
    public abstract void   release(void* p);
    public abstract size_t size(void* p);
}

public interface Lock : Object {
    public abstract void enter(void* lock);
    public abstract void leave(void* lock);
    public abstract void wait(void* cond, void* lock, int64 timeout_ns);
    public abstract void wake(void* cond, bool all);
}

public interface Clock : Object {
    public abstract int64 monotonic_ns();
    public abstract int64 real_ns();
}
```

## 3. Own ABI

Since there is no C, the calling convention is a design decision. It is defined once and documented in `docs/abi.md`.

### 3.1 Function call

| Aspect | Rule |
|---|---|
| Integers and pointers | `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`; the rest on the stack, right to left |
| Floating point | `xmm0`–`xmm7`; the rest on the stack |
| Integer/pointer return | `rax` |
| Floating-point return | `xmm0` |
| *Callee-saved* | `rbx`, `rbp`, `r12`–`r15`, `rsp` |
| *Caller-saved* | everything else |
| Stack alignment at `call` | 16 bytes |
| Red zone | **Does not exist**, neither in the kernel nor in the userland |
| Closures | environment pointer as a hidden argument in `rdi` |
| `this` | first argument after the environment |
| Varargs | **do not exist** (VL-11) |

`rcx` and `r11` are destroyed by the `syscall` instruction; that is why the syscall ABI uses `r10` instead of `rcx`. They are two different conventions and both are documented.

### 3.2 Type layout

| Type | Representation |
|---|---|
| `bool` | 1 byte, 0 or 1 |
| `char` | 1 byte |
| integers | natural width, little-endian |
| `float` / `double` | IEEE-754 binary32 / binary64 |
| `string` | pointer to `{ refcount: uint32, hash: uint32, length: size_t, bytes… }`, trailing NUL |
| `T[]` | pointer to `{ refcount: uint32, length: size_t, elements… }` |
| class | pointer to `{ vtable, refcount, …data }` |
| `[Compact] class` | pointer to `{ …data }`, no vtable |
| `struct` | value; natural alignment |
| delegate | `{ code, environment, destructor }` |
| enum | integer of the smallest width that fits |
| `weak` | pointer without refcount, cleared on free |

`string` preserves Vala's semantics: UTF-8, trailing NUL, immutable. Arrays carry length and refcount in their **own** header; the `valac` layout is not imitated because there is no C that consumes it.

### 3.3 Symbols

- *Mangling*: `planet__<space>__<type>__<member>` with a short hash to disambiguate overloads.
- `[CCode(cname = "x")]` replaces the symbol name. It is the only function of that attribute that is kept (VL-10).
- Visibility: `internal` is not exported; `public` is. The linker removes what is not referenced.

## 4. Memory

| Level | Mechanism | Consumer |
|---|---|---|
| Physical | buddy over Limine's memory map; bitmap per zone | `Pmm.reserve_pages` |
| Kernel virtual | 4 levels, higher-half, *direct map* | `Vmm.map_kernel` |
| Kernel heap | slab per size class + buddy for large blocks | `Allocator`, kernel profile |
| User address space | PML4 per process, upper half shared | ELF loader |
| User heap | arena with `brk`; `mem_map` for large blocks | `Allocator`, user profile |

Invariant rules:

- **W^X** (KR-03): no writable and executable page.
- **No red zone**, neither in the kernel nor in the userland: the compiler never generates it.
- **Guard page** below the stack of each thread.
- **Every access to physical memory goes through the direct map.**
- **`copy_from_user` / `copy_to_user`** validate against the process map and are recoverable on page fault (KR-07).

## 5. Concurrency

| Primitive | Kernel | Userland |
|---|---|---|
| Atomics | `lock` instructions from the `atomic.*` intrinsic | idem |
| Spinlock | `Lock` with `pause` + local IRQ disabling | — |
| Mutex | FIFO queue, sleeps the thread | futex over channel |
| Condvar | idem | idem |
| Thread-local storage | `%gs` (per-cpu) | real `%fs`, static TLS |
| `async` | scheduler coroutine | coroutine over the main loop |

**Real TLS from the beginning.** With no C and no inherited `GPrivate` there is no reason to emulate: each thread receives a TLS block and `%fs` points to it.

## 6. Object model

No `GType`, no `GValue`, no dynamic reflection. What is needed:

| Need | Solution |
|---|---|
| Virtual dispatch | vtable per class, generated at compile time |
| Interface dispatch | *itable* per (class, interface) |
| `is` / `as` | static type descriptor + ancestor chain |
| `typeof` | pointer to the descriptor; it is emitted only if the type participates in a reflective context |
| Signals | static table per type: `(id, handlers, typed marshaller)` |
| Properties | direct accessors; `notify` is one more signal |
| `weak` | slot in the object's weak reference table |

The compiler computes the **RTTI closure**: it emits descriptors only for types that appear in `is`, `as`, `typeof`, `switch` by type or signals with dynamic connection. A kernel without those constructs carries no type tables.

Object identity stops at the process boundary. An object is never shared across
CR3 or across the ring boundary: the kernel and userland exchange **handles and
rings**, and the `Gio` object that the application uses is a local proxy
([08](08-io-data-path.md)). Sharing a kernel vtable would be a ring-0 call
primitive, not an abstraction.

## 7. Repository structure

```
PlanetOS/
├── README.md
├── docs/
├── planc/                    ← compiler, in Vala
│   ├── src/
│   │   ├── lexer/
│   │   ├── parser/
│   │   ├── semantic/
│   │   ├── ir/
│   │   ├── backend/          ← selection, registers, x86_64 encoding
│   │   ├── elf/              ← object and executable writer
│   │   ├── linker/
│   │   ├── assembler/        ← [AsmBody]
│   │   ├── dwarf/
│   │   └── main.vala
│   └── tests/
├── dialect/                  ← accepted language
│   ├── grammar.ebnf
│   └── conformance/
├── planetrt/                 ← runtime and standard library, in Vala
│   ├── core/
│   ├── text/
│   ├── containers/
│   ├── events/
│   ├── coroutines/
│   ├── profile/
│   └── tests/
├── kernel/
│   ├── src/
│   ├── hal/                  ← [AsmBody] for GDT, IDT, context switch
│   ├── drivers/
│   └── link.plan             ← own layout, consumed by the linker
├── userland/
└── tests/
    ├── qemu.sh
    └── guest/
```

## 8. Build

`planc` is the only program needed to build the system. The build is described in a manifest readable by `planc`:

```
# planet.build
target kernel {
    profile = kernel
    architecture = x86_64
    sources = kernel/src/**/*.vala
    link = kernel/link.plan
    output = planet-kernel
    debug = dwarf
}

target userland  { profile = user   ... }
target planetrt-host { profile = host ... }
target conformance   { ... }
```

```bash
planc build --manifest planet.build --target kernel
planc build --manifest planet.build --target userland
planc test  --profile host
planc link  --layout kernel/link.plan -o iso/planet-kernel ...
```

While `planc` does not exist, building `planc` uses the host (see [02 §15](02-compiler.md#15-bootstrap)). That is the only point in the project where a C compiler appears, and **it is not part of the delivered toolchain**.

## 9. Debugging

| Tool | Use |
|---|---|
| DWARF + GDB | Vala names, lines, variables, complete `bt` (TC-06) |
| `-serial stdio` | kernel log, formatted by `planetrt` |
| `-d int,cpu_reset,guest_errors` | exceptions and triple fault |
| `-device isa-debug-exit` | deterministic exit code for CI |
| `host` profile | all pure logic is debugged without an emulator (VE-01) |

Rule: **if a failure reproduces in the `host` profile, it is fixed in the `host` profile**. The cycle in QEMU is slower and has fewer tools.
