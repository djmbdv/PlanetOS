# Slice 27: Pure-Vala `GLib` & `Gee` Compatibility Layer (`stdlib/glib_compat.vala`)

## Goal

Allow existing pure-Vala code (`using GLib;`, `using Gee;`, `StringBuilder`, `FileUtils`, `ArrayList<T>`, `string.contains`, `string.index_of`) to compile and run directly on PlanetOS with **zero C code and zero `.vapi` files**.

## Changes

### 1. Built-in `string.index_of` and `string.contains` (`planc`)
- [`planc/src/emitter.vala`](../../planc/src/emitter.vala) & [`planc/src/codegen.vala`](../../planc/src/codegen.vala):
  - Added `__planc_str_index_of(haystack, needle, start)` and wired `string.index_of(needle, start = 0)` and `string.contains(needle)` across all targets (Linux, `--freestanding`, `--target=planetos`).

### 2. Pure-Vala compatibility library (`stdlib/glib_compat.vala`)
- [`stdlib/glib_compat.vala`](../../stdlib/glib_compat.vala):
  - `GLib.StringBuilder` (`append`, `append_c`, `append_unichar` UTF-8 encoder, `truncate`, `.str`, `.len`).
  - `GLib.FileUtils` (`test`, `get_contents`, `set_contents`) & `GLib.FileTest` backed directly by PlanetOS `int 0x80` syscalls (`SYS_OPEN`, `SYS_CREATE`, `SYS_READ`, `SYS_WRITE`, `SYS_FILE_SIZE`, `SYS_CLOSE`).
  - `GLib.Environment`, `GLib.printerr`, `GLib.Str` (`strip`, `replace`, `joinv`), and `Gee.ArrayList<T>`.

### 3. Real-world pure-Vala utility & QEMU verification
- [`user/wc.vala`](../../user/wc.vala):
  - Word/line/byte/UTF-8-char counter written in pure Vala using `using GLib;` and `using Gee;` (zero C, zero `.vapi`, zero inline assembly).
- [`run-qemu.sh`](../../run-qemu.sh) & [`planc/tests/run.sh`](../../planc/tests/run.sh):
  - Compiles `wc.elf`, embeds it in XFS, and verifies `exec wc.elf hello.txt` (`hello.txt: lines=1 words=4 bytes=30 chars=30 [has PlanetOS]`) in QEMU.
