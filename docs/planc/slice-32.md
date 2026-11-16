# Slice 32: Windows-style command resolution in the shell (`user/shell.vala`)

## Goal

Run an `.elf` by naming it, the way `cmd.exe` runs `notepad` for
`notepad.exe`: no `exec` prefix, extension implied, case-insensitive, and a
`.\` prefix accepted. PlanetOS has no `PATH` (the VFS is flat), so resolution is
"the name as typed, then the same name with `.elf`, then a case-insensitive
match over the root directory".

The shell already had a fall-through that treated any unknown command as an ELF
path, but only an exact, case-sensitive, extension-complete name worked:
`gio_demo` and `GIO_DEMO.ELF` both answered `command not found`.

## Changes (`user/shell.vala`)

### 1. `resolve_command()` / `find_root_ci()`

- Strips a leading `./` or `.\` so `.\wc hello.txt` and `./wc hello.txt` work.
- Accepts the exact name when it ends in `.elf` (any case) and exists.
- Otherwise tries `<name>.elf`.
- Otherwise scans the root listing from `SYS_READDIR` (XFS + RAMFS) comparing
  names with ASCII case folding and returns the **on-disk** name, so a file
  stored as `Gio_Demo.elf` is found and opened with its real spelling.
- `exec` keeps its old behaviour first (an exact path of any name), then applies
  the same resolution, so `exec gio_demo` works too.

### 2. Backslash in the tokenizer

`.\prog` used to arrive as `.prog` because a backslash escaped the next
character unconditionally. Now a backslash only escapes shell metacharacters
(whitespace, quotes, `$`, `\`, `|`, `>`, `<`, `;`, `&`, `#`), which matches how
Windows paths are typed and keeps `\ `, `\"` and `\;` working.

### 3. Diagnostics and `help`

| Situation | Message |
|---|---|
| Nothing resolves | `<name>: command not found` (exit 127) |
| Resolved but not a loadable ELF | `<file>: cannot execute` |
| Background spawn fails | `<file>: cannot execute` |

`help` now documents the direct form:
`<prog> [args] runs <prog>.elf directly (case-insensitive, no exec needed)`.

## Behaviour

| Typed | Executes |
|---|---|
| `gio_demo` | `gio_demo.elf` |
| `gio_demo.elf` | `gio_demo.elf` |
| `GIO_DEMO.ELF` | `gio_demo.elf` |
| `giO_dEmO` | `gio_demo.elf` |
| `.\wc hello.txt` / `./wc hello.txt` | `wc.elf hello.txt` |
| `wc hello.txt` | `wc.elf hello.txt` |
| `wc hello.txt &` | `wc.elf hello.txt` in the background (`spawn: tid=N`) |
| `exec gio_demo` | `gio_demo.elf` |
| `hello.txt` | `hello.txt: command not found` (only `.elf` runs directly) |
| `exec hello.txt` | `hello.txt: cannot execute` |
| `notacmd` | `notacmd: command not found` |

Builtins (`ls`, `cat`, `ps`, …) still win over a same-named `.elf`, and
pipelines, redirections, `&&`, `&`, variables and quoting are unchanged.

## Verification

Booted with `./run-qemu.sh --headless` and drove the guest shell over the COM1
serial console:

```
planet> echo "a  b"
a  b
planet> test -f hello.txt && echo yes
yes
planet> wc hello.txt &
spawn: tid=1
planet> hello.txt: lines=1 words=4 bytes=30 chars=30 [has PlanetOS]
planet> gio_demo
gio:summary checks=27 failures=0
planet> GIO_DEMO.ELF
gio:summary checks=27 failures=0
planet> .\wc.elf hello.txt
hello.txt: lines=1 words=4 bytes=30 chars=30 [has PlanetOS]
planet> ./wc hello.txt
hello.txt: lines=1 words=4 bytes=30 chars=30 [has PlanetOS]
planet> giO_dEmO
gio:summary checks=27 failures=0
planet> notacmd
notacmd: command not found
planet> hello.txt
hello.txt: command not found
planet> exec hello.txt
hello.txt: cannot execute
```

`gio_demo` requires the Gio layer from [slice 31](slice-31.md) and is
idempotent, so running it repeatedly in one boot leaves 27/27.

## Known limitations

- There is no `PATH`: the root is the only search location, and there are no
  directories yet.
- An extensionless *non*-`.elf` file is not runnable directly; only `exec` with
  the exact path still accepts it.
- Resolution costs up to three `SYS_OPEN` probes plus one `SYS_READDIR` scan on
  an unknown command; builtins pay nothing.
