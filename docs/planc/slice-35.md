# Slice 35: Asm audit, shared syscall layer and syscall hardening

## Goal

Review every `[AsmBody]` in the tree, move the ones that do not need machine
code into Vala, keep the rest in one place with a documented reason, and make
the syscall boundary validate what userland passes to the kernel.

## Audit

| Location | Before | Verdict |
|---|---|---|
| `kernel/cpu.vala` (14) | `cli`/`sti`/`hlt`, GDT/IDT, MSRs, CR3, `cpuid`, `rdtsc`, IRQ stubs | **stays** — privileged instructions (invariant I5) |
| `kernel/ata.vala` (4), `keyboard.vala` (3), `mouse.vala` (8), `vga.vala` (1), `fb.vala` (7) | `in`/`out`, `rep insw/outsw`, `invlpg`, PCI config, Bochs VBE registers | **stays** — port I/O and MMIO |
| `kernel/pmm.vala` (3), `cairo_gdk_compat.vala` (4) | `mmio_read/write`, `zero_page_4k`, `fill32`, `poke32`/`peek32`, `peek64` | **stays** — raw physical memory; the dialect has no pointer types |
| `kernel/elf_loader.vala` (3), `sched.vala` (2), `keyboard/mouse` IRQ addresses, `spv_demo` `addr_orbit_worker` | stack switch, `iretq`, ISR entry, address of a Vala function | **stays** — no function pointers in the dialect |
| `planetrt/serial.vala` (6), `boot_mb2.vala` (1) | COM1 port I/O, Multiboot entry, 32→64 bit switch | **stays** — port I/O and boot |
| `stdlib/glib_compat.vala` (5), `gio_compat.vala` (10), `cairo_gdk_compat.vala` (2 of 6), `user/shell.vala` (7), `spv_demo.vala` (3), `banner.vala` (1), `worker.vala` (1), `cairo_demo.vala` (1), `planc/src/host_planetos.vala` (5) | each re-implemented the `int 0x80` trampoline and pointer arithmetic | **converted** — 35 blocks removed |
| `planc/src/asm.vala`, `emitter.vala`, `parser.vala` | the assembler and its error messages | **stays** — it *is* the assembler |

## Changes

### 1. One syscall layer (`stdlib/planet_sys.vala`, new, namespace `Planet`)

Three primitives, all documented:

- `__sys4(num,a0,a1,a2,a3)` — the only `int 0x80` trampoline in userland.
- `__str_data(s)` / `__arr_data(a)` — data pointer of a Vala string/array
  (skips the 16-byte header).

Everything else is Vala in `Planet.Sys`: `open`, `create`, `read`, `write`,
`write_str`, `close`, `file_size`, `seek`, `unlink`, `mkdir`, `stat`, `rename`,
`readdir_path`, `exec`, `spawn`, `wait`, `list_tasks`, `set_stdio`,
`alloc_pages`, `free_page`, `ticks`, `yield_cpu`, `read_key`, `console_write`.
Each wrapper checks its arguments before the syscall:

| Check | Rule |
|---|---|
| path | `1 … 512` bytes |
| transfer | `0 ≤ count ≤ buffer.length` and `≤ 64 KiB` |
| fd | `close`/`seek`/`file_size` need `fd ≥ 3` |
| pages | `1 … 256` per allocation |

The shell, `glib_compat`, `gio_compat`, Cairo/Gdk, `spv_demo`, `banner`,
`worker`, `cairo_demo` and planc's host adapter all use this layer now.

### 2. Shell without raw memory (`user/shell.vala`)

`poke8`/`peek8` and the scratch physical page are gone. The line editor keeps a
`uint8[]`, echoes through `Sys.write(1, ...)`, and handles backspace by
inspecting the array. `ls`, `ps`, `cat`, `rename`, `mkdir`, `stat`, `open` and
the redirections use the typed layer, so no command writes to an address it
computed by hand.

Three partial-read loops (`glib_compat`, `spv_demo`, `host_planetos`) read into
a temporary chunk and copied it at `got`; before, a short read overwrote the
beginning of the buffer. This is what `SYS_READ` returning a real offset made
visible.

### 3. Kernel syscall validation (`kernel/syscall.vala`)

Userland and the kernel share an address space, so `int 0x80` now checks every
pointer before dereferencing it:

- `user_ok(ptr,len)`: `ptr ≥ 0x1000`, no overflow, end `≤ 64 MiB`, `len ≤ 1 MiB`.
- `path_ok(ptr,len)`: `1 … 512` bytes inside that range.
- `fd_ok(fd)`: `-1` or `3 … 15` for `SYS_SET_STDIO`.
- `SYS_ALLOC_PAGE` caps at 256 pages; `SYS_THREAD_SPAWN` checks the entry point;
  `SYS_MOUSE_READ`/`SYS_FB_INFO` check their output buffers.

`kernel/main.vala` runs three probes at boot with deliberately invalid
arguments and prints `sysguard:ok=1` when all of them are rejected:

```
planet> ...
sysguard:ok=1
```

The `sysguard` line is asserted by `tests/cases/errors.expect`, so a regression
in the guard fails the suite.

## Verification

```
== case compiler  == PASS
== case directories == PASS
== case errors == PASS
== case exec == PASS
== case gio == PASS
5/5 cases passed
```

The new `compiler` case runs `planc.elf` inside the guest, compiles
`utf8.vala` and `class_basic.vala` from XFS and executes the results, which
exercises the migrated host adapter end to end.

## Remaining machine code

| Reason | Blocks |
|---|---|
| Privileged instructions, port I/O, MMIO | `cpu`, `ata`, `keyboard`, `mouse`, `vga`, `fb`, `serial`, `boot_mb2` |
| Raw physical memory (no pointer types in the dialect) | `pmm`, Cairo pixel helpers, Gdk mouse read |
| Function addresses / stack switching | ELF entry, ISR entries, `addr_orbit_worker` |
| `int 0x80` trampoline and string/array data pointers | `stdlib/planet_sys.vala` (3) |
| The assembler itself | `planc/src/asm.vala`, `emitter.vala`, `parser.vala` |

Adding pointer types (or `ref`-returning builtins) to the dialect would let
`__str_data`/`__arr_data` and the raw-memory helpers move to Vala; that is a
compiler change, not a runtime one.
