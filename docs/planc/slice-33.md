# Slice 33: File management — `SYS_UNLINK`/`SYS_RENAME`, `rm`/`cp`/`mv`/`touch`, `ls -l`

## Goal

Make the writable filesystem usable: delete and rename files in RAMFS, expose
it to userland through two new syscalls and Gio, and add the shell utilities
that need them. Until now `gio_demo` had to reuse its temp files because there
was no way to remove them.

## Changes

### 1. RAMFS operations (`kernel/ramfs.vala`)

- `unlink (name_ptr, name_len)`: frees the slot's pages, clears `in_use`, size
  and name length. Returns `0`, or `-1` when the name is not in RAMFS (XFS is
  read-only, so deleting a disk file is refused).
- `rename (old_ptr, old_len, new_ptr, new_len)`: validates the new name
  (1…64 bytes), refuses to overwrite an existing entry, copies the new name and
  clears the leftover bytes of a shorter name.

### 2. Syscalls (`kernel/syscall.vala`)

| Number | Call | Arguments |
|---|---|---|
| 28 | `SYS_UNLINK` | `rdi` name pointer, `rsi` name length |
| 29 | `SYS_RENAME` | `rdi` old pointer, `rsi` old length, `rdx` new pointer, `r8` new length |

`SYS_RENAME` is the first four-argument call, so `syscall_dispatch` now takes
`a3` and the `int 0x80` trampoline forwards it in `r8` (the project ABI already
uses `rdi`, `rsi`, `rdx`, `rcx`, `r8` for the first five integer arguments).
Three-argument calls are unchanged.

### 3. Gio (`stdlib/gio_compat.vala`)

- New `FileCopyFlags` enum (`NONE`, `OVERWRITE`, `BACKUP`, `ALL_METADATA`).
- `File.delete (cancellable)` → `SYS_UNLINK`; throws `IOError.FAILED` when the
  file does not exist or lives in XFS.
- `File.move (destination, flags, cancellable)` → `SYS_RENAME`; throws
  `IOError.EXISTS` when the target exists and `OVERWRITE` was not requested,
  and removes the target first when it was.
- Private `__gio_unlink`/`__gio_rename` assembly stubs that turn the Vala
  string (pointer + length at offset 8) into syscall arguments.

### 4. Shell (`user/shell.vala`)

| Command | Behaviour |
|---|---|
| `rm <file>...` | `SYS_UNLINK` per file; `rm: cannot remove '<file>'` and exit 1 on failure |
| `mv <src> <dst>` | `SYS_RENAME`; refuses to overwrite |
| `cp <src> <dst>` | reads the source (`FileUtils.get_contents`) and writes the copy (RAMFS) |
| `touch <file>...` | creates the file only when it does not exist (never truncates) |
| `ls -l` | lists `<size> <name>`, opening each entry with `SYS_OPEN` + `SYS_FILE_SIZE` |

### 5. Gio demo (`user/gio_demo.vala`)

The demo now cleans up after itself and checks the new API: 27 → **38** checks,
and the files it creates no longer survive a run, so `enumerate_children()`
returns the 13 image entries on every boot and repeated runs stay at 38/38.

## Verification

```
planet> write tmp1 hello
planet> cp tmp1 tmp2
planet> cat tmp2
hello
planet> mv tmp2 tmp3
planet> cat tmp3
hello
planet> ls -l
30 hello.txt
6 tmp1
6 tmp3
planet> rm tmp1
planet> cat tmp1
cat: not found
planet> touch tmp4
planet> ls
hello.txt
tmp4
tmp3
planet> rm hello.txt
rm: cannot remove 'hello.txt'
```

Second pass, including the error paths and a copy from XFS:

```
planet> write a one
planet> write b two
planet> mv a b
mv: cannot move 'a' to 'b'
planet> mv b c
planet> cp hello.txt copy1
planet> cat copy1
xfs:hello from PlanetOS disk!
planet> ls -l
30 hello.txt
10080 init.elf
76072 shell.elf
1753896 planc.elf
9632 banner.elf
9536 worker.elf
27128 wc.elf
45632 cairo_demo.elf
624 frag.spv
55696 spv_demo.elf
96896 gio_demo.elf
576 utf8.vala
642 class_basic.vala
4 a
4 c
30 copy1
planet> mv missing x
mv: cannot move 'missing' to 'x'
```

Gio, run twice in the same boot:

```
planet> gio_demo
gio:summary checks=38 failures=0
planet> gio_demo
gio:summary checks=38 failures=0
```

## Known limitations

- `unlink`/`rename` only touch RAMFS. XFS is mounted read-only, so `rm` on a
  disk file fails with `cannot remove` (the error is intentional).
- `cp` writes through `SYS_CREATE`, which always creates a RAMFS entry. Copying
  to a name that also exists in XFS therefore creates a RAMFS file that shadows
  the disk one (the VFS resolves RAMFS first).
- RAMFS still caps files at 80 KiB (`MAX_PAGES = 20` in a 256-byte slot), so
  `cp planc.elf big` stops at the short write and reports `cannot write`.
- There are no directories yet: all names live in the flat root.
