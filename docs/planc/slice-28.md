# Slice 28: 100% Pure-Vala `dash`-Inspired Shell (`user/shell.vala`) & Stdio Redirection

## Goal

Upgrade PlanetOS's interactive shell to a 100% pure-Vala `dash`-inspired shell (using `stdlib/glib_compat.vala`, zero C, zero `.vapi`) with variables, quoting, pipelines, redirections, conditionals, loops, and `.sh` script execution.

## Changes

### 1. Kernel stdio redirection & seek (`kernel/syscall.vala`, `kernel/elf_loader.vala`)
- [`kernel/syscall.vala`](../../kernel/syscall.vala):
  - Added `SYS_SET_STDIO` (`19`, `in_fd`/`out_fd`) and `SYS_SEEK` (`20`, `-1` for EOF) so `SYS_CONSOLE_WRITE` (`1`) and `SYS_READ_KEY` (`5`) transparently redirect to/from RAMFS files for pipelines (`|`) and redirections (`>`, `>>`, `<`).
- [`kernel/elf_loader.vala`](../../kernel/elf_loader.vala):
  - `ElfLoader.load_and_run()` initializes a clean `argc=1, argv=["sh", NULL]` stack for `shell.elf`.

### 2. Pure-Vala `dash`-inspired shell (`user/shell.vala`)
- [`user/shell.vala`](../../user/shell.vala):
  - Tokenizer supporting `'...'` single quotes, `"..."` double quotes, `\` escapes, `#` comments, `$VAR` / `${VAR}` / `$?` / `$$` expansion, and operators `|`, `>`, `>>`, `<`, `;`, `&&`, `||`, `&`.
  - Lazy per-segment expansion on `;`, `&&`, `||`, `&` so `FOO=planet; echo "$FOO"` expands cleanly.
  - Built-ins: `echo [-n]`, `export`, `unset`, `env`, `pwd`, `cd`, `true`, `false`, `test` / `[ ... ]`, `if ...; then ...; [else ...;] fi`, `for ... in ...; do ...; done`, `sh <script.sh>`, `help`, `banner`, `ls`, `ps`, `cat`, `write`, `exec`, `wait`, `ticks`, `mem`, `exit [code]`, plus direct ELF invocation (`wc.elf hello.txt`).

### 3. Verification
- [`run-qemu.sh`](../../run-qemu.sh) & [`planc/tests/run.sh`](../../planc/tests/run.sh):
  - Compiles `shell.elf` with `stdlib/glib_compat.vala` and verifies `FOO=planet; echo "var=$FOO" > r.txt; cat < r.txt`, `true && echo ok-and`, `false || echo ok-or`, `ls | cat`, `wc.elf`, and preemptive `exec worker.elf &` in QEMU.
