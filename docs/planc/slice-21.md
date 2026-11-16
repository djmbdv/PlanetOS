# Slice 21 — XFS Filesystem Driver and Expanded Runtime Syscalls

Slice 21 adds a read-only XFS (v4/v5 on-disk format) filesystem driver over
ATA PIO and expands the `int 0x80` syscall table to cover console I/O, physical
page allocation, timer ticks, keyboard input, XFS file I/O (`open`/`read`/
`close`/`file_size`), `yield`, and `exit`.

## 1. XFS Driver ([kernel/xfs.vala](../../kernel/xfs.vala))

- `Xfs.mount()`: reads sector 0, validates `XFSB` (`0x58465342`), and parses
  `sb_blocksize`, `sb_agblocks`, `sb_agblklog`, `sb_inodesize`, `sb_inopblog`,
  and `sb_rootino`.
- `Xfs.lookup_root(name_ptr, name_len)`: reads the root inode (`0x494E` `"IN"`)
  and scans shortform directory entries (`di_format == 1`).
- `Xfs.read_file(ino, dst_buf, max_bytes)`: decodes 128-bit `bmbt_rec` extents
  (`di_format == 2`) and reads the backing sectors via `Ata.read_sector`.

## 2. Syscall ABI ([kernel/syscall.vala](../../kernel/syscall.vala))

| # | Name | Arguments | Returns |
|---|---|---|---|
| `1` | `SYS_CONSOLE_WRITE` | `buf, len` | bytes written |
| `2` | `SYS_TICKS` | — | `Hal.ticks()` |
| `3` | `SYS_ALLOC_PAGE` | — | 4 KiB physical addr |
| `4` | `SYS_FREE_PAGE` | `phys` | `0` |
| `5` | `SYS_READ_KEY` | — | scancode or `-1` |
| `6` | `SYS_OPEN` | `name_ptr, name_len` | `fd` (`3..15`) or `-1` |
| `7` | `SYS_READ` | `fd, buf, len` | bytes read |
| `8` | `SYS_CLOSE` | `fd` | `0` |
| `9` | `SYS_FILE_SIZE` | `fd` | size in bytes |
| `10` | `SYS_YIELD` | — | `0` (`hlt`) |
| `11` | `SYS_EXIT` | `code` | does not return |

## 3. Verification

- `freestanding_qemu` in [run.sh](../../planc/tests/run.sh) builds a 64 KiB XFS
  v4 disk image containing `hello.txt`, boots the kernel in QEMU, mounts XFS,
  opens/reads `hello.txt` via `int 0x80` (`SYS_OPEN`, `SYS_FILE_SIZE`,
  `SYS_READ`, `SYS_CONSOLE_WRITE`, `SYS_CLOSE`, `SYS_EXIT`), and passes
  (`174 cases, 174 pass, 0 fail`).
