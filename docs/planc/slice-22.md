# Slice 22: `--target=planetos` Userland Target and Kernel ELF64 Loader

## Goal

Compile standalone Vala userland programs directly to PlanetOS ELF64 binaries using `planc --target=planetos`, load them from the XFS filesystem inside the kernel, and run them end-to-end in QEMU without Linux syscalls.

## Changes

### 1. Compiler target (`planc`)
- [`planc/src/main.vala`](../../planc/src/main.vala):
  - Added `--target=planetos` CLI option.
  - Passes `base_addr = 0x800000` (8 MiB) to `Elf.compute` so userland binaries do not collide with the kernel at `0x400000` or the PMM free pool starting at `0x600000`.
- [`planc/src/elf.vala`](../../planc/src/elf.vala):
  - Parameterized `Elf.compute(..., uint64 base_addr = BASE_ADDRESS)`.
- [`planc/src/codegen.vala`](../../planc/src/codegen.vala) & [`planc/src/emitter.vala`](../../planc/src/emitter.vala):
  - Added `target_planetos` codegen mode and `emitter.int80()` (`0xCD 0x80`).
  - `__planc_write_str` / `__planc_write_int` / panic handler invoke `SYS_CONSOLE_WRITE` (`1`) via `int 0x80`.
  - `__planc_alloc` requests 4 KiB pages from the kernel via `SYS_ALLOC_PAGE` (`3`, `int 0x80`) and sub-allocates from the current bump page.
  - `_start` and `exit(code)` invoke `SYS_EXIT` (`11`, `int 0x80`).

### 2. Kernel PMM & ELF64 loader (`kernel`)
- [`kernel/pmm.vala`](../../kernel/pmm.vala):
  - Added `Pmm.alloc_contiguous(num_pages)` and `Pmm.reserve_range(start_addr, size)` so loaded userland segments at `0x800000+` are marked used and protected from subsequent `SYS_ALLOC_PAGE` calls.
- [`kernel/elf_loader.vala`](../../kernel/elf_loader.vala):
  - Added `ElfLoader.load_and_run(buf, size)`: validates `\x7fELF` / `EM_X86_64`, iterates `PT_LOAD` program headers, reserves target physical ranges, copies `p_filesz`, zero-fills `p_memsz - p_filesz`, and transfers control to `e_entry`.
- [`kernel/main.vala`](../../kernel/main.vala):
  - Opens `init.elf` from XFS via `SYS_OPEN` (`6`), queries `SYS_FILE_SIZE` (`9`), reads the ELF image into contiguous PMM pages via `SYS_READ` (`7`), and executes `ElfLoader.load_and_run`.

### 3. Userland program & QEMU verification
- [`user/init.vala`](../../user/init.vala):
  - First PlanetOS userland Vala program exercising `print`, heap-allocated `Counter` class (`SYS_ALLOC_PAGE`), `@"..."` string interpolation, and `return 0` (`SYS_EXIT`).
- [`planc/tests/run.sh`](../../planc/tests/run.sh):
  - Compiles `user/init.vala` with `--target=planetos`, embeds both `hello.txt` and `init.elf` in the synthetic XFS disk image, boots QEMU, and verifies userland output on COM1.
