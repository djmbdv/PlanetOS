# Slice 24: Native UTF-8 (`planc` + PlanetOS) and Writable RAMFS (`SYS_CREATE` / `SYS_WRITE`)

## Goal

Add native UTF-8 support across both the `planc` compiler/runtime and PlanetOS console/shell, and add a writable PMM-backed RAMFS (`SYS_CREATE`, `SYS_WRITE`) so userland programs (including `planc.elf` in the next slice) can create, write, read, and execute files inside QEMU.

## Changes

### 1. Native UTF-8 in `planc`
- [`planc/src/parser.vala`](../../planc/src/parser.vala) & [`planc/src/codegen.vala`](../../planc/src/codegen.vala):
  - Added `unichar` as a built-in 32-bit unsigned codepoint type (`uint32` alias).
- [`planc/src/lexer.vala`](../../planc/src/lexer.vala):
  - Added `\xXX`, `\uXXXX`, and `\UXXXXXXXX` escape sequences in string literals, encoding Unicode codepoints directly into UTF-8 bytes.
- [`planc/src/emitter.vala`](../../planc/src/emitter.vala) & [`planc/src/codegen.vala`](../../planc/src/codegen.vala):
  - Added `string.char_count()` (`__planc_utf8_char_count`), `string.get_char(byte_index = 0)` (`__planc_utf8_get_char`), and `string.validate()` (`__planc_utf8_validate`) working identically on Linux, `--freestanding`, and `--target=planetos`.
- [`planc/tests/valid/utf8.vala`](../../planc/tests/valid/utf8.vala) & [`planc/tests/valid/utf8.out`](../../planc/tests/valid/utf8.out):
  - Verifies UTF-8 literals, `\u`/`\U` escapes, `unichar`, `char_count()`, `get_char()`, and `validate()`.

### 2. Native UTF-8 in PlanetOS
- [`kernel/vga.vala`](../../kernel/vga.vala):
  - Added a stateful UTF-8 decoder in `Vga.write_byte()` mapping multi-byte UTF-8 sequences (including Spanish `áéíóúüñÁÉÍÓÚÜÑ¿¡°`) to CP437 glyphs on VGA `80x25` text mode while COM1 serial remains 8-bit UTF-8 clean.
- [`user/shell.vala`](../../user/shell.vala):
  - Updated backspace handling to delete full multi-byte UTF-8 characters (`0x80..0xBF` continuation bytes + leading byte) in one keystroke.

### 3. Writable RAMFS & VFS integration
- [`kernel/ramfs.vala`](../../kernel/ramfs.vala):
  - Added an in-memory writable RAMFS (`0x120000`, up to 32 files, dynamically backed by 4 KiB PMM pages).
- [`kernel/syscall.vala`](../../kernel/syscall.vala), [`kernel/elf_loader.vala`](../../kernel/elf_loader.vala), & [`kernel/main.vala`](../../kernel/main.vala):
  - Added `SYS_CREATE` (`14`) and `SYS_WRITE` (`15`, supporting both console `fd 1/2` and RAMFS `fd >= 3`).
  - `SYS_OPEN` (`6`), `SYS_READDIR` (`12`), and `SYS_EXEC` (`13`) check RAMFS alongside XFS.
- [`user/shell.vala`](../../user/shell.vala) & [`user/init.vala`](../../user/init.vala):
  - Added `write <file> <text>` shell command and UTF-8 runtime verification inside `init.elf`.
