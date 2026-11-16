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

There is no `socket`, `poll`, `select`, `signal` or `fork`. I/O waiting is resolved with `chan_recv` over multiple channels, which is what the runtime event loop consumes.

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

There is no requirement of compatibility with existing graphical applications, and therefore there is no restriction that pushes towards a foreign toolkit.
