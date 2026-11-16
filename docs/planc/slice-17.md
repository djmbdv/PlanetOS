# Slice 17 — `--freestanding`, `planetrt`, and QEMU x86-64 Kernel Boot

Slice 17 adds `--freestanding` mode to `planc`, the initial `planetrt`
freestanding runtime (`boot_mb2.vala` + `serial.vala`), and a minimal PlanetOS
kernel (`kernel/main.vala`) that boots directly in `qemu-system-x86_64` into
64-bit Long Mode without `libc` or Linux syscalls (`I1`, `I2`, `I5`, `I6`).

## 1. Compiler (`--freestanding`)

- [asm.vala](../../planc/src/asm.vala): adds x86 port I/O instructions
  (`in %dx, %al/%ax/%eax`, `out %al/%ax/%eax, %dx`, and immediate port forms).
- [codegen.vala](../../planc/src/codegen.vala) &
  [emitter.vala](../../planc/src/emitter.vala):
  - `print(...)` and runtime panics route to `__planet_console_write` and
    `__planet_panic` instead of Linux `SYS_write` / `SYS_exit`.
  - `_start` and `exit(...)` halt with `cli; hlt` instead of `SYS_exit`.
  - `__planc_alloc` uses a static 256 KiB `.bss` heap arena instead of
    `SYS_mmap` / `SYS_mprotect`, enabling `class`, `string`, `@"..."`
    templates, and ARC inside the freestanding kernel.
- [main.vala](../../planc/src/main.vala) & [elf.vala](../../planc/src/elf.vala):
  - Emits `_kstart32` first in `.text` (`0x4000E8`), sets ELF `e_entry` to
    `_kstart32`, and patches Multiboot1 `load_end_addr` / `bss_end_addr` in
    `.text` so QEMU loads through `.data` and zero-initializes `.bss`.

## 2. `planetrt` & `kernel`

- [planetrt/boot_mb2.vala](../../planetrt/boot_mb2.vala): Multiboot1 (a.out
  kludge) header + 32-bit protected-mode trampoline that identity-maps the first
  1 GiB with 2 MiB pages, enables `CR4.PAE`, `EFER.LME`, `CR0.PG`, loads a
  64-bit GDT, far-jumps to `_kstart64`, sets `rsp`, and calls `main`.
- [planetrt/serial.vala](../../planetrt/serial.vala): COM1 (`0x3F8`, 115200 8N1)
  serial driver implementing `__planet_console_write`, `__planet_panic`, and
  `qemu_debug_exit`.
- [kernel/main.vala](../../kernel/main.vala): initializes COM1, allocates a
  `KernelBanner` object on the freestanding heap, prints the boot banner and
  `kernel:ok` over serial, and exits QEMU via `isa-debug-exit`.

## 3. Verification

- `freestanding_qemu` in [run.sh](../../planc/tests/run.sh) compiles
  `planetrt/boot_mb2.vala`, `planetrt/serial.vala`, and `kernel/main.vala` with
  `--freestanding`, boots in `qemu-system-x86_64 -kernel`, and verifies the
  COM1 serial output (`PlanetOS v0.1 booted in x86-64 Long Mode`, `kernel:ok`).
- 3-stage self-hosted fixed-point bootstrap (`./planc/bootstrap.sh`):
  `sha256(planc2) == sha256(planc3)` (`8bb9612d1803179d809e6afeab0bbe8d390faa26643d28e6a5718d226b758891`, `1680320 bytes`),
  `174 cases, 174 pass, 0 fail`.
