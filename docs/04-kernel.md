# 04 — Kernel

## 1. Principle

The kernel is written in Vala and compiled by `planc`. There is no C anywhere, not even at the boot boundary: privileged instruction sequences are written as `[AsmBody]` bodies inside Vala functions (I5).

The only thing that is not generated code is the `planc` assembler, which encodes those sequences.

## 2. Boot

### 2.1 Limine protocol

The Limine protocol is used through four requests:

| Request | Purpose |
|---|---|
| `memmap` | physical memory map for the frame allocator |
| `hhdm` | *direct map* offset; a fixed value is not assumed |
| `framebuffer` | graphical console |
| `smp` | list of CPUs |

`limine.conf`:

```
TIMEOUT=0
:PlanetOS
    PROTOCOL=limine
    KERNEL_PATH=boot:///planet-kernel
```

### 2.2 `_start`

```vala
namespace Planet.Kernel.Arranque {
    [AsmBody(@"
        .section .bss
        .align 16
    pila_arranque:
        .skip 16384
    pila_arranque_alto:

        .section .text
        .global _start
    _start:
        cli
        lea     pila_arranque_alto(%rip), %rsp
        xor     %rbp, %rbp
        and     $-16, %rsp
        call    planet_iniciar         # rdi already carries Limine's response
        hlt
    ")]
    private static extern void _start();
}
```

`planet_iniciar` is ordinary Vala. From there on there is no assembler other than the HAL's.

```vala
namespace Planet.Kernel {

    private static void iniciar(void* respuesta) {
        Serial.iniciar();              // first available log
        Gdt.cargar();
        Idt.cargar();
        Tss.iniciar();

        var arranque = Limine.interpretar(respuesta);
        Pmm.iniciar(arranque.mapa);
        Vmm.iniciar(arranque.hhdm);
        Slab.iniciar();                // from here on the allocator works

        Log.iniciar();
        Log.info("planet", @"kernel $(Version.cadena) on $(Cpu.modelo())");

        Apic.iniciar();
        Temporizador.iniciar(1000);
        Planificador.iniciar();
        Vfs.iniciar();
        Ramfs.montar("/");
        Elf.iniciar();
        Syscalls.iniciar();
        Proceso.crear("/system/bin/init", null);

        Planificador.bucle_inactivo();  // never returns
    }
}
```

### 2.3 Organization

```
kernel/
├── src/
│   ├── arranque.vala        ← _start, planet_iniciar
│   ├── cpu/                 ← gdt, idt, tss, msr, puertos, apic
│   ├── mm/                  ← pmm, vmm, slab, copia_usuario
│   ├── sched/               ← hilo, proceso, cambio_contexto [AsmBody]
│   ├── syscall/             ← tabla, despacho, validación
│   ├── vfs/                 ← nodo, archivo, montaje, ramfs
│   ├── ipc/                 ← message channels
│   └── log/                 ← log backend for the kernel profile
├── hal/                     ← [AsmBody] bodies
├── drivers/
└── enlace.plan              ← memory layout for the linker
```

## 3. CPU

| Structure | Content | Notes |
|---|---|---|
| GDT | null, `kcode`, `kdata`, `ucode`, `udata`, TSS | user selectors are needed for `sysret` |
| IDT | 256 entries | 32 exceptions, vectorized IRQs, `int 0x80` reserved |
| TSS | `rsp0` of the current task, IST1 for double fault | updated on every process switch |
| MSR | `EFER.SCE`, `STAR`, `LSTAR`, `FMASK` | `FMASK` masks `IF` and `DF` on entering the kernel |

### 3.1 Interrupt entry

```
hardware → IDT[n] → stub [AsmBody]
                     ├─ if coming from user: swapgs
                     ├─ push of the error code, if the exception provides it
                     ├─ push of registers
                     ├─ align stack to 16
                     └─ call planet_irq_despachar(vector, marco)
                            └─ Vala: corresponding handler
                     ├─ pop of registers
                     ├─ if returning to user: swapgs + iretq
                     └─ if there is a task switch: load context
```

Stubs are generated with assembler macros so that the 32 exceptions and the N IRQ vectors have exactly the same frame shape. The cause of the classic bug is that some exceptions push an error code and others do not; the stub normalizes it by pushing a zero when there is none.

### 3.2 Per-thread CPU state

`FXSAVE` is always saved, never lazily (KR-09). The area is 512 bytes aligned to 16. Enabling `CR0.EM=0`, `CR0.MP=1`, `CR4.OSFXSR=1`, `CR4.OSXMMEXCPT=1` is mandatory before executing any SSE instruction, because `planc` uses XMM for `float` and `double`.

### 3.3 Panic

```vala
[NoReturn]
public extern void panico(string motivo);   // the caller uses a template: panico(@"failure in $x")
```

It prints: reason, CPU, thread, `rip`, `rsp`, `cr2` if it is a *page fault*, frame chain and the top 8 words of the stack. In graphical mode it also colors the framebuffer. A panic that does not allow diagnosis is a useless panic (KR-06).

## 4. Memory

```
Pmm   buddy over the Limine map
      ├── zone <4 GiB (DMA, tables)
      └── high zone
Vmm   4-level tables
      ├── direct map of all the RAM
      ├── kernel in higher half, W^X per section
      └── PML4 per process, shared upper half
Slab  classes from 16 to 8192 bytes, plus buddy above that
```

Rules:

- **W^X** (KR-03): `.text` is RX, `.rodata` is R, `.data`/`.bss` are RW. Never RWX.
- **No red zone.** The compiler never emits it (ABI, §3 of [01](01-architecture.md#31-function-call)).
- **Every physical access goes through the direct map.**
- **Copies from and to user** with prior validation of the range against the process map and *page fault* recovery (KR-07). Recovery uses a table of fixup points: if the faulting `rip` is registered as a copy point, the instruction is skipped and an error is returned instead of killing the process.

## 5. Interrupts and time

| Component | Choice | Reason |
|---|---|---|
| Controller | APIC + IOAPIC | needed for SMP and for masking per line |
| Timer | local APIC, 1 kHz | no PIT calibration, one per CPU |
| Wall clock | CMOS at boot + monotonic offset | avoids reading CMOS on every call |
| Monotonic | invariant TSC | nanosecond resolution |

The **target** is that the kernel's main loop (`Planet.Eventos`) is the same code the userland uses, with the `kernel` profile, and that a driver registers a `Fuente` backed by an IRQ. The **current state** is narrower: no kernel file instantiates `MainContext`; only the timer, keyboard and mouse have IRQ stubs, while ATA completes by PIO polling and virtio-gpu completes by bounded spin. The migration is Phase C of [08](08-io-data-path.md), and it keeps the scheduler from D-10:

```vala
while (true) {
    Principal.iterar(false);
    Planificador.recalendar_si_necesario();
}
```

The kernel keeps the scheduler; the loop runs on top of it. Drivers that need to wait use the internal equivalent of `SYS_WAIT_ADDR`/`SYS_WAKE_ADDR`: the IRQ handler publishes a sequence and wakes the word, and the calling task is suspended instead of spinning.

## 6. Scheduler

```vala
public struct Hilo {
    uint64         rsp;             // saved stack
    EstadoHilo     estado;          // LISTO, EJECUTANDO, BLOQUEADO, ZOMBI
    uint8          prioridad;       // 0..31
    Proceso*       proceso;         // null if it is a kernel thread
    AreaFx         fpu;             // 512 bytes, aligned to 16
    char[32]       nombre;
}
```

- Queue per CPU and per priority; *round-robin* within the same level.
- The timer sets `recalendar`; on leaving the interrupt a switch happens if a higher-priority thread is ready.
- Context switch in `[AsmBody]`: saves `rbx`, `rbp`, `r12`–`r15`, `rsp`, `rip`, `rflags`, and `FXSAVE`.
- Idle thread per CPU with `hlt`.

Lifecycle:

```
create → load ELF → create PML4 → map segments → stack + arguments
      → main thread LISTO
exit → close descriptors → free PML4 → notify whoever waits → ZOMBI
```

**No `fork`** (US-03). `Proceso.crear` is the only primitive. There is no COW, no table duplication, no POSIX signal semantics.

## 7. Syscalls

```vala
internal delegate int64 FuncionSys(uint64 a1, uint64 a2, uint64 a3,
                                   uint64 a4, uint64 a5, uint64 a6);

internal int64 despachar(uint64 numero, uint64 a1, uint64 a2, uint64 a3,
                         uint64 a4, uint64 a5, uint64 a6) {
    if (numero >= tabla.length || tabla[numero] == null)
        return -Err.NO_IMPLEMENTADA;
    return tabla[numero](a1, a2, a3, a4, a5, a6);
}
```

Rules:

- **Centralized validation** of pointers in the dispatcher, not in each handler.
- Stable numbers, documented in `docs/abi.md` and frozen per version.
- `sys_llamar_v` carries `abi_version` in the argument structure in order to evolve without breaking binaries.
- If a handler returns a pointer, the dispatcher checks that it lies in user space.
- Every resource is named by a **per-process handle with rights**, never by a global slot index ([08](08-io-data-path.md)). The current global `FD_TABLE` and `SYS_MAP_USER_AT` are transitional and must not be extended.
- Pointer validation is against the caller's page table and is recoverable (KR-07). Today `user_ok` only bounds the address against `USER_LIMIT`.

## 8. VFS

```vala
public abstract class Nodo : Object {
    public abstract Archivo abrir(uint32 banderas);
    public abstract Entrada[] listar();
    public abstract Nodo buscar(string nombre);
    public virtual void borrar(string nombre) throws Error;
}

public abstract class Archivo : Object {
    public abstract ssize_t leer(uint8[] destino) throws Error;
    public abstract ssize_t escribir(uint8[] origen) throws Error;
    public abstract int64   posicionar(int64 desplazamiento, Origen origen) throws Error;
    public virtual void cerrar();
}
```

| Filesystem | Persistence | Use |
|---|---|---|
| `ramfs` | no | temporary root, `/tmp` |
| `pfs` | yes | persistent root: 4 KiB blocks, simple B tree, minimal journal |
| `devfs` | no | device nodes generated on enumeration |

Requirement of `pfs`: to survive a power cut without losing the consistency of the tree. It is verified with the cut test described in [06](06-verification.md#4-verification-in-qemu).

## 9. Drivers

The two I/O contracts of [08](08-io-data-path.md) decide the interface. Byte devices become `Gio` streams over a handle; framed devices become a validated descriptor ring. The physical driver and the doorbell stay in ring 0 in both cases.

| Driver | Need | Contract | State |
|---|---|---|---|
| UART 1650 | kernel log, later `/dev/serial0` | A: byte stream | ring-0 log exists; user handle pending B1 |
| Framebuffer + 8×16 font | text console | kernel-only | implemented |
| PS/2 keyboard | shell input | A: raw scancodes after B2, ASCII via `SYS_READ_KEY` meanwhile | implemented |
| PCI enumeration | discover virtio | kernel | implemented |
| ATA PIO | disk (legacy) | B: validated ring, PIO fallback | implemented, polled |
| virtio-blk | disk | B: validated ring | planned |
| RTC | wall time | syscall today, byte device later | implemented |
| virtio-gpu | display and 3D | B: validated ring plus scanout grant | implemented, controlq polled |
| virtio-net | network | B: validated ring | planned, no driver |
| audio | sound | B: data ring | planned |

None of them knows the scheduler. None of them exposes a vtable to userland: the boundary is a handle plus a ring, and the protocol stack runs in the LibOS. Line discipline and terminal echo move to userland last, keeping `SYS_READ_KEY` for the boot and panic console.

## 10. Vala pitfalls in the kernel

| Pitfall | Symptom | Rule |
|---|---|---|
| Implicit allocation when building strings | invisible leaks | use `uint8[]` and buffers on hot paths |
| `unref` with the lock held | sporadic deadlock | release outside the critical section |
| Objects with signals in an IRQ handler | allocation in a non-allocatable context | `[Compact]` and direct functions in IRQ |
| Vala global variables | not visible from `[AsmBody]` | declare them with `[CCode(cname)]` and export them |
| Hardware structures | uncertain layout | define them as `[SimpleType] struct` with explicit offsets and a layout test |
| Panic inside a handler | reentrancy in the logger | logger with a lock-free ring and deferred dump |
| `throw` in an exception handler | building `Error` with corrupted memory | exception handlers do not throw; they panic |

## 11. Debugging

```bash
# boot with GDB waiting
qemu-system-x86_64 -cdrom iso/planetos.iso -serial stdio -s -S -m 1G

# exception and triple fault trace
qemu-system-x86_64 -cdrom iso/planetos.iso -serial stdio -d int,cpu_reset,guest_errors

# deterministic output for CI
qemu-system-x86_64 -cdrom iso/planetos.iso -display none -serial file:serial.log \
  -no-reboot -device isa-debug-exit,iobase=0xf4,iosize=0x04
```

With DWARF (TC-06) GDB shows Vala names, lines and variables. Stack unwinding uses frame pointers, which the backend keeps in `debug` mode.

Permanent instrumentation in the kernel:

- slab `reservas`/`liberaciones` counters, dumpable from the shell;
- canary at the end of each thread stack, checked on every context switch;
- interrupt counter per vector, exposed at `/info/irq`.

## 12. Shared `.dlib` read-only mapping (`glib.dlib`)

- **VMM read-only helpers** ([kernel/vmm.vala](../kernel/vmm.vala)): `map_user_4k_phys (cr3, vaddr, paddr, flags)`, `map_user_4k_ro` (`0x05`: `PRESENT | USER`), `map_user_range_ro`, and `protect_user_range_ro` (downgrades only existing `USER`-accessible 4 KiB PTEs by clearing the `RW` bit and invalidating the TLB).
- **Syscalls** ([kernel/syscall.vala](../kernel/syscall.vala)): `52` (`SYS_PROTECT_USER_RO`, backed by `Vmm.protect_user_range_ro`) and `53` (`SYS_MAP_USER_RO_AT`), used by `open_dlib` in [stdlib/gmodule_compat.vala](../stdlib/gmodule_compat.vala) to protect `.text` and `.rodata` sections read-only.
- **ELF loader & PMM** ([kernel/elf_loader.vala](../kernel/elf_loader.vala), [kernel/pmm.vala](../kernel/pmm.vala)): `Pmm.init` reserves `0x1800000..0x1900000` for shared `.dlib` modules; `ElfLoader.ensure_shared_glib` loads `glib.dlib` from XFS once (also invoked from `load_and_run` for `shell.elf`), and `map_shared_glib_into` maps `.text+.rodata` as `0x05` shared read-only while allocating a zeroed per-process `0x07` RW copy of `.data+.bss` via `zero_page_4k`. The header is validated before use: magic, `is_dlib`, `.plan` version and a `.text` base inside the reserved window, with a `Klog` error instead of a silent misload.
- **Blocking, errno and readiness** ([kernel/sched.vala](../kernel/sched.vala), [kernel/syscall.vala](../kernel/syscall.vala), [kernel/klog.vala](../kernel/klog.vala)): `TASK_BLOCKED` plus per-task errno and futex bookkeeping (kept in scheduler arrays, since the 128-byte TCB is full). `sched_tick` resumes blocked tasks whose deadline expired and `SYS_WAKE_ADDR` resumes the ones parked on a matching address; `SYS_WAIT_ADDR` uses both, `SYS_POLL`/`SYS_SLEEP_MS` wait on the tick. `Klog` gained the `user` category (7) and `write_bytes`, so `SYS_KLOG_WRITE` copies the record straight from user memory.
- **User stack is 1 MiB** ([kernel/elf_loader.vala](../kernel/elf_loader.vala)): `USER_STACK_PAGES = 257` (1 bottom guard + 256 usable) replaces the old 16 usable pages. `planc.elf` is expected to build programs on-target, and compiling the concatenated SDK prelude (~120 KB) recursed deep enough in `Codegen.expr_type_full` to fault in the guard page at `cr2 = stack_base + 4096`.
- **Transitional mapping**: `SYS_MAP_USER_AT` (50) and `SYS_MAP_USER_RO_AT` (53) take a physical address and check only a range. [08](08-io-data-path.md) replaces both with `SYS_GRANT` over a handle, so a `.dlib` or a shared surface is backed by owned frames instead of an address the caller guessed.
