# Slice 23: VGA & COM1 RX Drivers, `SYS_READDIR` / `SYS_EXEC`, and Interactive Shell

## Goal

Add interactive console drivers (VGA `80x25` text output + COM1 serial RX input), directory listing and child ELF execution syscalls, and an interactive PlanetOS userland shell (`user/shell.vala`).

## Changes

### 1. Kernel drivers
- [`kernel/vga.vala`](../../kernel/vga.vala):
  - Added VGA `80x25` color text console at `0xB8000` with scrolling, `\n`, `\r`, and backspace (`8`).
  - `SYS_CONSOLE_WRITE` (`1`) mirrors output to both COM1 serial and VGA text mode.
- [`planetrt/serial.vala`](../../planetrt/serial.vala):
  - Added `serial_try_read()` polling COM1 LSR (`0x3FD` bit 0) and reading `0x3F8`.
- [`kernel/keyboard.vala`](../../kernel/keyboard.vala):
  - Added `.`, `-`, `/` scancodes to `Keyboard.scancode_to_ascii`.
  - `SYS_READ_KEY` (`5`) returns ASCII from PS/2 `IRQ1` ring buffer, falling back to `serial_try_read()`.

### 2. XFS directory listing, synchronous `SYS_EXEC`, and `--image-base`
- [`kernel/xfs.vala`](../../kernel/xfs.vala):
  - Added `Xfs.list_root(buf, max_bytes)` to list root directory entries.
- [`kernel/elf_loader.vala`](../../kernel/elf_loader.vala):
  - Added `exec_trampoline` and `exec_return_to_parent` so `SYS_EXEC` (`13`) loads a child ELF from XFS with its own 16 KiB stack and returns its exit code to the caller when the child invokes `SYS_EXIT` (`11`).
- [`kernel/syscall.vala`](../../kernel/syscall.vala):
  - Added `SYS_READDIR` (`12`) and `SYS_EXEC` (`13`).
- [`planc/src/main.vala`](../../planc/src/main.vala):
  - Added `--image-base=0xHEX` so `user/shell.vala` links at `0xA00000`, keeping `0x800000` free for child binaries (`init.elf` and future `planc` outputs).

### 3. Userland shell & QEMU verification
- [`user/shell.vala`](../../user/shell.vala):
  - Interactive shell (`planet> `) supporting `help`, `ls`, `cat <file>`, `exec <file>`, `ticks`, `mem`, and `exit`.
- [`kernel/main.vala`](../../kernel/main.vala):
  - Initializes `Vga.init()` and boots `shell.elf` from XFS (falling back to `init.elf`).
- [`planc/tests/run.sh`](../../planc/tests/run.sh):
  - Compiles `user/init.vala` (`0x800000`) and `user/shell.vala` (`0xA00000`), embeds them in XFS alongside `hello.txt`, feeds `help`, `ls`, `cat hello.txt`, `exec init.elf`, `ticks`, `exit` over QEMU serial stdin, and verifies all outputs.
