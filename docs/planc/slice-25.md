# Slice 25: `planc.elf` Self-Hosted Inside PlanetOS (QEMU)

## Goal

Run the `planc` compiler natively inside PlanetOS (`planc.elf` at `0xC00000`), compiling Vala test programs from XFS into RAMFS ELF64 binaries and executing them via `SYS_EXEC` inside QEMU.

## Changes

### 1. PlanetOS userland host adapter (`planc/src/host_planetos.vala`)
- [`planc/src/host_planetos.vala`](../../planc/src/host_planetos.vala):
  - Implements `Planc.Host` (`eprint`, `eprintln`, `println`, `panic`, `read_file`, `write_file`, `chmod_755`, `bytes_to_string`, `hex_u8`, `hex_u32`) purely over PlanetOS `int 0x80` syscalls (`SYS_OPEN`, `SYS_FILE_SIZE`, `SYS_READ`, `SYS_CLOSE`, `SYS_CREATE`, `SYS_WRITE`, `SYS_EXIT`), with zero Linux syscalls or GLib dependencies.

### 2. Multi-page `SYS_ALLOC_PAGE` & large userland allocations
- [`planc/src/emitter.vala`](../../planc/src/emitter.vala):
  - Updated `__planc_alloc` in `target_planetos` mode so large allocations (`> 4096` bytes) invoke `SYS_ALLOC_PAGE(num_pages)` via `int 0x80` instead of Linux `mmap`/`mprotect`, and small-slab `l_new_slab` explicitly sets `edi = 1`.
- [`kernel/syscall.vala`](../../kernel/syscall.vala):
  - `SYS_ALLOC_PAGE` (`3`) accepts `a0 = num_pages`, calling `Pmm.alloc_contiguous(a0)` when `a0 > 1`.

### 3. Command-line arguments (`argc`/`argv`) in `SYS_EXEC`
- [`kernel/elf_loader.vala`](../../kernel/elf_loader.vala):
  - `ElfLoader.exec_from_xfs(name_ptr, name_len, cmdline_ptr)` allocates a 64 KiB child stack and pushes a Linux-compatible `argc`/`argv[]` layout for `_start` -> `__planc_build_args`.
- [`kernel/syscall.vala`](../../kernel/syscall.vala) & [`user/shell.vala`](../../user/shell.vala):
  - `SYS_EXEC` (`13`) forwards `a2 = cmdline_ptr` from `shell.vala`'s `exec <file> [args...]` command.

### 4. End-to-end QEMU test (`planetos_planc_qemu`)
- [`planc/tests/run.sh`](../../planc/tests/run.sh):
  - Compiles `planc.elf` (`--target=planetos --image-base=0xC00000`), embeds `utf8.vala` and `class_basic.vala` in XFS, boots QEMU, runs `exec planc.elf --target=planetos utf8.vala -o utf8.elf`, `exec utf8.elf`, `exec planc.elf --target=planetos class_basic.vala -o cls.elf`, and `exec cls.elf` inside PlanetOS, verifying outputs and exit codes.
