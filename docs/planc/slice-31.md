# Slice 31: Gio Compatibility Layer in Userland (`stdlib/gio_compat.vala`, `user/gio_demo.vala`)

## Goal

Make the pure-Vala `Gio` layer reachable from PlanetOS userland and prove it on
the real syscall ABI: `File`/`FileInfo`/`FileEnumerator`, `InputStream`/
`OutputStream` and their file/memory/data subclasses, `Cancellable`, `IOError`
and `Application` (with signals) running on `int 0x80`, no C and no `.vapi`.

The layer already existed in [`stdlib/gio_compat.vala`](../../stdlib/gio_compat.vala)
but nothing compiled it, nothing exercised it, and two stream bugs made partial
reads and appends return wrong data. This slice closes both.

## Changes

### 1. Streaming reads on XFS (`kernel/xfs.vala`, `kernel/syscall.vala`, `kernel/elf_loader.vala`)

`SYS_READ` tracked a read position per file descriptor, but `Xfs.read_file()`
ignored it and always restarted at offset 0. A 30-byte file read one byte at a
time (what `DataInputStream.read_line()` does) returned the **first byte thirty
times**, and any `seek()` had no effect on the data returned.

- [`kernel/xfs.vala`](../../kernel/xfs.vala): `read_file (ino, offset, dst_buf, max_bytes)`
  now skips whole 512-byte sectors without touching the disk, copies the first
  chunk from `offset & 511`, and clamps the transfer to `file_size - offset`.
- [`kernel/syscall.vala`](../../kernel/syscall.vala): `SYS_READ` passes the FD's
  stored position to `Xfs.read_file()`, matching the RAMFS path.
- [`kernel/elf_loader.vala`](../../kernel/elf_loader.vala): the ELF load path
  passes `offset = 0` explicitly.

### 2. Append without truncation (`stdlib/gio_compat.vala`)

`File.append_to()` called `SYS_CREATE`, which truncates an existing RAMFS file,
so appending to `x` produced a file containing only the new bytes.

- `append_to()` now opens the file first; only when it does not exist does it
  create it. An existing file is seeked to EOF (`SYS_SEEK` with `-1`).

### 3. Gio demo (`user/gio_demo.vala`)

New userland program that runs 27 checks and prints one deterministic line per
check (`gio:check <name> ok|FAIL`), finishing with
`gio:summary checks=N failures=M` and exit status `1` when any check failed:

| Group | Exercises |
|---|---|
| File | `new_for_path`, `get_path`, `get_basename`, `query_exists`, `query_info` (`FileInfo` size/type/content type) |
| Read | `File.read()` → `FileInputStream` → `DataInputStream.read_line()` loop, closed-stream `IOError.CLOSED` |
| Seek | `seek(END)`, `tell()`, `seek(SET)` against `FileInfo.get_size()` |
| Cancellable | `cancel()`, `is_cancelled()`, throwing calls, `set_error_if_cancelled()` |
| Memory | `MemoryOutputStream` → `DataOutputStream.put_string/put_byte` → `MemoryInputStream.from_data` → `read_line`/`read_byte` |
| Write | `replace()` truncation, `FileUtils.get_contents` round trip, `append_to()` + 2-line reread, `IOError` propagation |
| Contents | `create()` (and `IOError.EXISTS` on the second call), `replace_contents()`, `load_contents()`, `get_child()` path, `append_to()` creating a missing file |
| Enumerate | `enumerate_children()`/`next_file()` over the XFS + RAMFS root |
| Application | `activate` signal handler and `run()` |

### 4. Build and image integration (`run-qemu.sh`)

- Builds `gio_demo.elf` against [`stdlib/glib_compat.vala`](../../stdlib/glib_compat.vala)
  and [`stdlib/gio_compat.vala`](../../stdlib/gio_compat.vala).
- Adds `gio_demo.elf` to the XFS image, which now holds 13 entries.

## Verification

Built and booted with `./run-qemu.sh --headless`; the guest shell ran
`exec gio_demo.elf`:

```
planet> exec gio_demo.elf
gio:demo target=hello.txt
gio:path hello.txt base=hello.txt
gio:check exists ok
gio:info name=hello.txt size=30 type=1 ctype=text/plain
gio:check info-regular ok
gio:check info-content-type ok
gio:line[0] len=29 xfs:hello from PlanetOS disk!
gio:check read-lines ok
gio:check closed-stream ok
gio:check seek-end ok
gio:check seek-set ok
gio:check cancellable-flag ok
gio:check cancellable-query ok
gio:check cancellable-error ok
gio:memory size=15
gio:check memory-size ok
gio:check memory-line ok
gio:check memory-byte ok
gio:check write-exists ok
gio:written size=20
gio:check write-content ok
gio:file[0] written by gio_demo
gio:file[1] appended line
gio:check append-lines ok
gio:check create-new ok
gio:check create-exists ok
gio:check replace-contents ok
gio:check replace-read ok
gio:check load-contents ok
gio:check child-path ok
gio:check append-create ok
gio:children count=16
gio:check enumerate-count ok
gio:check enumerate-hello ok
gio:signal activate
gio:check app-run ok
gio:app-id org.planetos.GioDemo
gio:check app-id ok
gio:summary checks=27 failures=0
exec: exit=0
planet> cat hello.txt
xfs:hello from PlanetOS disk!
planet> exec wc.elf hello.txt
hello.txt: lines=1 words=4 bytes=30 chars=30 [has PlanetOS]
exec: exit=0
```

`cat` and `wc.elf` are included because they go through the same file-descriptor
position that `Xfs.read_file()` used to ignore.

`gio:line[0] len=29` is the regression witness for the XFS fix: before it the
same call printed 30 `x` bytes.

Manual run:

```sh
./run-qemu.sh              # opens the QEMU window
# inside the guest:
planet> exec gio_demo.elf
planet> exec gio_demo.elf hello.txt
```

## Known limitations

- The VFS is flat: `File.enumerate_children()` lists the root regardless of the
  `File` it is called on, and every enumerated entry is reported as
  `FileType.REGULAR` (there is no `stat`-by-name syscall yet).
- `File.replace()`/`append_to()` only persist to RAMFS: `SYS_WRITE` writes RAMFS
  slots, so writes to XFS-backed files are rejected by the kernel as before.
- `Application` does not dispatch an event loop; `run()` emits `activate` and
  returns 0, which is enough for userland tools that use it as a lifetime hook.
