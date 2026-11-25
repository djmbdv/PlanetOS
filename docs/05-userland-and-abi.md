# 05 — Userland and syscall ABI

## 1. Execution model

| Concept | Decision |
|---|---|
| Binaries | static ELF64 `ET_EXEC`; `PT_INTERP` is rejected (US-01) |
| Processes | own address space, one main thread, isolation from the start (US-02) |
| Creation | `proc_spawn(ruta, argv, entorno)`; **there is no `fork`** (US-03) |
| Threads | `thread_create(funcion, argumento)` with its own 64 KiB stack |
| I/O | synchronous with a time limit; the event loop multiplexes over channels |
| IPC | message passing channels (`chan_*`) |
| Identity | a single user, `uid=1000`; no `setuid` |
| Libraries | static; there is no dynamic linker and no `dlopen` |

## 2. Syscall ABI

| Resource | Convention |
|---|---|
| Number | `rax` |
| Arguments | `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9` |
| Return | `rax`: `>= 0` success; `-1 … -4095` is `-CodigoError` |
| Clobbered | `rcx`, `r11` (managed by the *trampoline*) |
| Stack | no red zone; aligned to 16 on entry |

The syscall ABI uses `r10` as the fourth argument because `syscall` clobbers `rcx`. The function ABI uses `rcx` (§3.1 of [01](01-architecture.md#31-function-call)). They are two conventions documented separately.

Two forms of invocation, both in `Planet.Sistema`:

```vala
// fast path: up to 6 scalars
public extern int64 sys_llamar(uint64 numero, uint64 a1, uint64 a2, uint64 a3,
                               uint64 a4, uint64 a5, uint64 a6);

// extensible path: versioned structure
public extern int64 sys_llamar_v(uint64 numero, ArgsSys* args);
```

`ArgsSys` includes `abi_version` in its first word, which allows adding fields without breaking already compiled binaries.

### 2.1 Catalog

| Group | Calls |
|---|---|
| Process | `proc_spawn`, `proc_exit`, `proc_wait`, `proc_info` |
| Thread | `thread_create`, `thread_exit`, `thread_join`, `thread_yield` |
| Memory | `mem_map`, `mem_unmap`, `mem_protect`, `mem_brk` |
| File | `file_open`, `file_close`, `file_read`, `file_write`, `file_seek`, `file_stat`, `file_readdir`, `file_unlink`, `file_mkdir` |
| Channel | `chan_create`, `chan_send`, `chan_recv`, `chan_close` |
| Time | `time_mono`, `time_real`, `timer_sleep` |
| Debugging | `sys_info`, `sys_debug_write` |

There is no `socket`, `select`, BSD `signal` or `fork`. Readiness is reported per
handle by `SYS_POLL` (IO-06); blocking is `SYS_WAIT_ADDR` on a futex-like word or
`chan_recv` over channels, which is what the runtime event loop consumes.

The device calls of [08](08-io-data-path.md) (`handle_*`, `grant`, `ring_kick`)
are part of the numeric catalog below from 63 up; the `chan_*` and `mem_*`
names remain the design target. The catalog implemented today is the `switch` in
[kernel/syscall.vala](../kernel/syscall.vala); it is frozen per version by
`SYS_ABI_VERSION`.

### 2.2 Implemented integration calls (`int 0x80`)

The running kernel dispatches through `SYS_*` numbers in [kernel/syscall.vala](../kernel/syscall.vala); 1–53 are the original console/memory/file/GPU calls and these are the ones added for the GLib layer:

| Number | Call | Purpose |
|---|---|---|
| 54 | `SYS_ERRNO()` | errno of the calling task, set by the last failing syscall |
| 55 | `SYS_STAT_EX(path, len, out16)` | kind (1 file, 2 dir) and byte size; `SYS_STAT` keeps `0 = absent` |
| 56 | `SYS_KLOG_WRITE(cat, level, ptr, len)` | userland record into the kernel ring (category 7 = user) |
| 57 | `SYS_WAIT_ADDR(addr, expected, timeout_ms)` | futex-style park: returns when the word changes, `-1`/`ETIMEDOUT` on deadline |
| 58 | `SYS_WAKE_ADDR(addr, count)` | wakes blocked tasks parked on the same address |
| 59 | `SYS_POLL(fds, nfds, timeout_ms)` | ready bitmask for up to 30 handles (`0` = stdin console, `1/2` = console out) |
| 60 | `SYS_SLEEP_MS(ms)` | tick-accurate sleep (10 ms granularity) |
| 61 | `SYS_ABI_VERSION()` | integer the `.dlib` consumers compare at load |
| 62 | `SYS_TID()` | kernel task id of the caller |
| 63 | `SYS_GRANT(start, len)` | capability handle over a block the caller owns (A2) |
| 64 | `SYS_GRANT_SHARE(handle, tid)` | adds a task id to the grant's ACL |
| 65 | `SYS_RING_ATTACH(grant, entries, dev_kind)` | binds a `KIND_RING` handle to a validated header (`PLNR`) |
| 66 | `SYS_RING_KICK(ring)` | validates and runs the ready descriptors; `-1` on a malformed one |
| 67 | `SYS_BLK_READ(buf, sector, count)` | virtio-blk read through the validated ring (C2) |
| 68 | `SYS_BLK_STATS()` | `late << 24 \| wakes << 16 \| capacity` in MiB |
| 69 | `SYS_NET_MAC(out6)` | MAC of the virtio-net device (C3) |
| 70 | `SYS_HANDLE_SEND(tid, handle)` | sends a handle to another task, returns the receiver's value |
| 71 | `SYS_HANDLE_RECV()` | receives a handle sent to the caller |
| 72 | `SYS_HANDLE_INFO(handle, out16)` | kind plus rights of a handle the caller owns |

Failures still return `-1` (the existing `== -1` checks keep working); the cause is read with `SYS_ERRNO` and mirrors Linux numbering (`ENOENT = 2`, `EACCES = 13`, `EISDIR = 21`, `ETIMEDOUT = 110`, …). `Planet.Sys` exposes them as `Sys.ENOENT`, `Sys.errno_code ()` and `Sys.strerror ()`.

## 3. Userland `_start`

```vala
namespace Planet.Sistema.Arranque {

    [AsmBody(@"
        .global _start
    _start:
        xor     %rbp, %rbp
        mov     (%rsp), %rdi          # argc
        lea     8(%rsp), %rsi         # argv
        lea     16(%rsp,%rdi,8), %rdx # environment
        and     $-16, %rsp
        call    planet_iniciar_usuario
        mov     %rax, %rdi
        call    planet_salir
        hlt
    ")]
    private static extern void _start();
}
```

`planet_iniciar_usuario` (Vala, `user` profile) initializes the environment, the per-thread error code, the allocator and calls the application's `main`. There is no `__libc_start_main` or equivalent.

## 4. ELF loader

```
1. Read the ELF64 header. Verify ET_EXEC, EM_X86_64, absence of PT_INTERP.
2. Create a PML4 by copying the kernel's upper half.
3. For each PT_LOAD:
     - round to pages;
     - reserve frames;
     - map with p_flags permissions (R, W, X, NX);
     - copy content and zero the rest of the segment.
4. Create the stack: 8 MiB of virtual space, guard page below.
5. Write argv, environment and ArgsArranque.
6. Create the main thread with rip = e_entry and rsp at the top of the stack.
```

User space layout:

```
0x0000_0000_0000_0000  ┌──────────────────────────┐
                       │ reserved                 │  64 KiB, unmapped
0x0000_0000_0001_0000  ├──────────────────────────┤
                       │ .text / .rodata          │  R-X / R--
                       ├──────────────────────────┤
                       │ .data / .bss             │  RW-
                       ├──────────────────────────┤
                       │ heap (brk) ↑             │
                       │        …                 │
                       │ mmap ↓                   │
                       ├──────────────────────────┤
                       │ stack ↓   guard page     │
0x0000_7fff_ffff_ffff  ├──────────────────────────┤
0xffff_8000_0000_0000  ├──────────────────────────┤
                       │ kernel (shared)          │
0xffff_ffff_ffff_ffff  └──────────────────────────┘
```

```vala
public struct ArgsArranque {
    public uint32 abi_version;
    public uint32 tamano_pagina;
    public char[16] sistema;      // "PlanetOS"
    public char[16] version;
    public int64 monotono_al_inicio_ns;
}
```

## 5. Processes and threads

```vala
public class Proceso : Object {
    public int32        pid        { get; }
    public string       ruta       { get; }
    public Estado       estado     { get; }
    public signal void  termino(int codigo);
}

public class Hilo : Object {
    public int32        tid        { get; }
    public Proceso      proceso    { get; }
    public signal void  termino(int codigo);
}
```

- `proc_wait` notifies whoever waits; there are no orphan processes without a destination: when `init` exits, the system stops in an orderly fashion.
- A process that dies releases its frames, its channels and its threads.
- There are no process groups or sessions: the shell keeps its own table of children.

## 6. Channels

```vala
public class Canal : Object {
    public static Canal crear(uint32 capacidad) throws Error;
    public void enviar(uint8[] mensaje) throws Error;
    public ssize_t recibir(uint8[] destino, int64 timeout_ns) throws Error;
    public void cerrar();
}
```

- Messages of a size bounded by the channel capacity; no copying between processes when the receiver already has the buffer mapped.
- The closed write end makes `recibir` return 0, just like an end of file.
- It is the mechanism on top of which the shell implements pipes and on top of which the runtime implements futex.

## 7. `init` and services

`/system/bin/init` is the first process. There is no external dependency tree: the service model is an object tree.

```vala
public class Servicio : Object {
    public string nombre { get; construct; }
    public string ruta   { get; construct; }
    public bool   activo { get; private set; default = false; }
    public signal void cayo(int codigo);

    public void arrancar() throws Error {
        var p = Proceso.crear(ruta, null);
        p.termino.connect((c) => { activo = false; cayo(c); });
        activo = true;
    }
}

public static int main(string[] args) {
    var registro = new Registro();
    registro.cargar("/system/etc/servicios.conf");
    registro.arrancar_todos();

    var shell = new Servicio("shell", "/system/bin/shell");
    shell.cayo.connect(() => Sistema.detener());
    shell.arrancar();

    Planet.Eventos.Principal.ejecutar();
    return 0;
}
```

## 8. Shell

`/system/bin/shell`, in Vala, on top of `Planet.Shell`:

| Capability | Detail |
|---|---|
| Line reading | in-memory history, basic editing |
| Execution | `proc_spawn` with arguments |
| *Builtins* | `cd`, `export`, `exit`, `set` |
| Redirection | `<`, `>`, `>>` over file descriptors |
| Pipes | `\|` over channels |
| Expansion | globs `*`, `?`, variables `$VAR` |
| Sequences | `;`, `&&`, `\|\|` |
| Quoting | single, double and escapes |
| Job control | suspend, continue, background |

The command-line parser is its own (`Planet.Shell`), it does not lean on any external library: it produces an AST of pipes and redirections, and variables are expanded in the shell process.

## 9. Filesystems

Own layout, without FHS:

```
/                    root (pfs)
├── system/
│   ├── bin/         system executables
│   ├── lib/         static SDK libraries
│   └── etc/         key-value configuration
├── apps/
│   └── <name>/      application, data and manifest
├── data/            user data
├── dev/             devices
├── tmp/             ramfs
└── info/            introspection
    ├── version
    ├── mem
    ├── irq
    └── <pid>/
```

`/info` replaces `/proc` and `/sys` together, with a single stable format (`key: value`) consumable by `Planet.Config` (US-07).

### 9.1 `/dev` and device handles (implemented for byte devices)

`/dev` is a devfs view generated on enumeration, never a stored tree. Opening
`/dev/<name>` returns a **per-process handle with rights**, not a global integer
([08](08-io-data-path.md)). The handle is the only way to reach the device: a
process that was not granted it cannot name it.

- Byte devices (`/dev/serial0`, `/dev/console`, `/dev/null`) are
  `Gio.InputStream`/`OutputStream` objects that also implement
  `PollableInputStream`/`PollableOutputStream` and `FileDescriptorBased`. Filter
  chains and line discipline run in the library, not in ring 0.
- Framed devices (block, network, GPU) are a descriptor ring plus a doorbell.
  The kernel validates every descriptor; userland owns buffers and protocol.

Current state: `SYS_OPEN` resolves `/dev/console`, `/dev/serial0` and `/dev/null`
to `KIND_DEV` handles that carry no seek right; create, mkdir and rename are
refused inside `/dev`
([kernel/vfs.vala](../kernel/vfs.vala), [kernel/syscall.vala](../kernel/syscall.vala)).
The fd table is per process with ownership, generation and rights
(`kernel/syscall.vala`). Remaining from B1 of [08](08-io-data-path.md): `cat`
through `/dev/serial0` driven by readiness instead of a blocking read.

## 10. SDK

The SDK is the toolchain itself (US-05):

```
planet-sdk/
├── bin/planc
├── lib/planetrt-<profile>.a
├── vapi/planet-*.vapi
└── docs/dialecto/
```

### 10.1 Minimal program

```vala
using Planet;

public class Hola : Aplicacion {
    public override int activar(string[] args) {
        print(@"hello from PlanetOS, $args.length arguments");
        return 0;
    }
}

public static int main(string[] args) {
    return new Hola().ejecutar(args);
}
```

```bash
planc build hola.vala -o hola --perfil user
planc install hola --destino /apps/hola
hola uno dos
```

### 10.2 `Aplicacion`

Minimal replacement for `GApplication`, without GIO:

```vala
namespace Planet {
    public abstract class Aplicacion : Object {
        public abstract int activar(string[] args);
        public virtual void terminar() {}
        public int ejecutar(string[] args) {
            int codigo = activar(args);
            terminar();
            return codigo;
        }
        public signal void abrir(string[] archivos);
    }
}
```

## 11. Packages

`ppkg` format: a single file with manifest and content.

```
manifiesto.plan
  nombre = hola
  version = 1.0
  ejecutable = bin/hola
  depende = planetrt >= 0.1
bin/hola
share/…
```

`ppkg instalar` unpacks into `/apps/<name>/`, checks dependencies against `/system/lib` and leaves the executable in `/apps/<name>/bin`. `ppkg listar` walks `/apps`. There is no central database: the manifest is the database.

## 12. Graphical interface

Outside the scope of the current specification, but with the decisions that must not be contradicted later:

| Aspect | Decision |
|---|---|
| Backend | virtio-gpu or VBE framebuffer; no acceleration |
| Model | object tree with properties and signals, like the rest of the system |
| Compositing | one compositor process; applications draw on surfaces shared through `mem_map` |
| Widget kit | own Vala library on top of `planetrt` |
| Rejected | Wayland, X11, GTK, and any toolkit that depends on C |

### 12.1 Shared window surfaces (implemented)

The compositor allocates one block per external window and exports its base
address as `PLANET_WIN_SHM`; the kernel identity-maps user frames, so the client
attaches the very same address with `SYS_MAP_USER_AT` and both processes see the
same bytes. The block is one 4 KiB header page followed by `w * h * 4` ARGB
pixels (`Gdk.SharedSurface`):

| Offset | Word | Meaning |
|---|---|---|
| `+0` | magic | `0x4D48534F` ("OSHM") |
| `+4` / `+8` | width / height | pixel dimensions of the client surface |
| `+12` | seq | frame counter, written last by the client |
| `+16` / `+20` | dx / dy | damage origin of rectangle 0, window-local |
| `+24` / `+28` | dw / dh | damage size of rectangle 0 |
| `+32` | dcount | rectangles in this frame (1..4) |
| `+36`..`+80` | rect 1..3 | three more `x, y, w, h` groups, 16 bytes each |
| `+84` | ev seq | last input event the compositor wrote |
| `+88` | ev ack | last input event the client consumed |
| `+92` | ev slots | 16 slots x `type, p1, p2, p3` (16 bytes each) |

The client draws straight into the pixels and only publishes its damage
rectangles plus a new `seq`; the compositor samples the header every frame (no
syscalls) and damages exactly those rectangles. Rectangles are kept apart when
they are far from each other (four at most, then they collapse into one bounding
box), so a keystroke repaints the edited line and the status label instead of the
whole window and the gap between them.

Input uses the same block: the compositor writes one ring slot and bumps
`ev seq`, the client copies everything up to that sequence and acknowledges it in
`ev ack`. A slot index is `seq % 16`, so the ring never allocates and neither side
needs a syscall per event. Overruns drop the oldest events, not the newest.

The PWIN file transports (`PLANET_WIN_FILE` for whole frames and
`PLANET_WIN_EV` for events) remain as the fallback when the block cannot be
allocated.

On the client side `Gtk` widgets queue damage rectangles
(`Widget.damage_box`/`gather_damage`): `GtkWindow.run` repaints and publishes the
accumulated rectangles (at most four), and falls back to a full repaint whenever
an input handler reports a change without damage, so a missed damage call costs
speed but never correctness.

There is no requirement of compatibility with existing graphical applications, and therefore there is no restriction that pushes towards a foreign toolkit.
