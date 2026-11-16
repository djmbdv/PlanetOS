# Slice 34: Directories — VFS paths, `mkdir`/`cd`/`ls`, and the Gio directory API

## Goal

Replace the flat namespace with a real directory tree. Paths are resolved by the
kernel (`/`, `.`, `..`, nested names), RAMFS can hold directories, the shell
keeps a working directory and every file command is relative to it, and Gio
reports `FileType.DIRECTORY` and enumerates a directory instead of the root.

## Changes

### 1. RAMFS entries have a kind and a parent (`kernel/ramfs.vala`)

The 256-byte slot gained metadata in the space that was unused:

```
+0    kind       0 free, 1 file, 2 directory
+8    size
+16   name_len
+24   name[64]
+88   page_addrs[20]   (160 B)
+248  parent          RAMFS slot, -1 = root
```

New API: `find_in(parent, name)`, `create_in(parent, name, kind)`,
`unlink_slot(slot)`, `rename_to(slot, new_parent, name)`, `has_children(slot)`
and `list_children(parent, buf, max)`. `create_in` truncates an existing file,
refuses to turn a file into a directory and never overwrites a directory.
`read`/`write` reject directory slots.

### 2. Kernel path resolution (`kernel/vfs.vala`)

`Vfs.resolve(path)` walks the path from the root, skipping repeated `/`,
resolving `.` and `..`, and returning `KIND_XFS`, `KIND_FILE`, `KIND_DIR` or
`KIND_NONE` plus an inode/slot. Only the last component of a path that stays in
the root is looked up in XFS, which remains read-only. `Vfs.resolve_parent()`
splits a path into the parent directory and the final component for create,
mkdir, unlink and rename, and `Vfs.is_descendant()` stops a directory from being
moved inside itself.

### 3. Syscalls (`kernel/syscall.vala`)

| Number | Call | Notes |
|---|---|---|
| 6 | `SYS_OPEN` | resolves a path; directories cannot be opened as files |
| 14 | `SYS_CREATE` | creates in the resolved parent directory |
| 28 | `SYS_UNLINK` | files, or empty directories; XFS and non-empty dirs are refused |
| 29 | `SYS_RENAME` | path-aware move/rename, refuses descendants and existing targets |
| 30 | `SYS_MKDIR` | new; fails on `.`, `..`, existing names and XFS root names |
| 31 | `SYS_READDIR` | new; `(path, buf, max)`, lists RAMFS children and, for the root, XFS names |
| 32 | `SYS_STAT` | new; `0` missing, `1` file, `2` directory |

`kernel/elf_loader.vala` now resolves the program name with `Vfs.resolve`, so an
ELF can be executed from any directory.

### 4. Shell (`user/shell.vala`)

- `abs_path()` prefixes the working directory and `canonical_path()` removes
  `.`, `..` and duplicate separators.
- `cd <dir>` validates with `SYS_STAT` and canonicalizes; `cd` goes to `/`.
- `mkdir <dir>...`, `ls [dir]`, `ls -l [dir]` (`dir <name>` for directories,
  `<size> <name>` for files), `pwd`.
- `cat`, `write`, `rm`, `cp`, `mv`, `touch`, redirections (`>`, `>>`, `<`),
  `sh <script>` and command execution all build paths from the working
  directory; `../gio_demo` works.
- `test` gains `-d` and checks `-e`/`-f` through `SYS_STAT`.

### 5. Gio (`stdlib/gio_compat.vala`)

- `File.make_directory()`, `File.query_exists()` and `File.query_info()` use
  `SYS_STAT`; directories report `FileType.DIRECTORY` and size 0.
- `File.enumerate_children()` lists the `File`'s own directory, and
  `FileEnumerator` resolves each child's type and size.
- `delete()`, `move()`, `create()`, `read()` and `append_to()` accept paths, so
  they work inside directories.

### 6. Demo (`user/gio_demo.vala`)

New `demo_directories()` covers mkdir, type reporting, a child file, per
directory enumeration, cross-directory move, empty/non-empty deletion. The
suite is now **51 checks**, still fully idempotent.

## Verification

```
planet> pwd
/
planet> mkdir docs
planet> ls
docs
hello.txt
...
planet> cd docs
planet> pwd
/docs
planet> write note.txt hola
planet> ls -l
5 note.txt
planet> cat note.txt
hola
planet> cd ..
planet> cat docs/note.txt
hola
planet> mv docs/note.txt docs/note2.txt
planet> cat docs/note2.txt
hola
planet> rm docs
rm: cannot remove '/docs'
planet> rm docs/note2.txt
planet> rm docs
```

Nested directories, `..`, `test -d`, moving a directory and the guard against
moving it inside itself:

```
planet> mkdir a
planet> mkdir a/b
planet> touch a/b/c
planet> ls a/b
c
planet> cd a/b
planet> pwd
/a/b
planet> cd ../..
planet> pwd
/
planet> test -d hello.txt
planet> test -e hello.txt && echo file-exists
file-exists
planet> mv a a/b
mv: cannot move '/a' to '/a/b'
planet> mv a renamed
planet> test -d renamed && echo renamed-ok
renamed-ok
```

Executing through `..` and redirecting inside a directory:

```
planet> mkdir bin
planet> cd bin
planet> ../gio_demo
...
gio:summary checks=51 failures=0
planet> cd ..
planet> rm bin
planet> mkdir d
planet> cd d
planet> echo hi > out.txt
planet> cat out.txt
hi
```

## Known limitations

- Directories only exist in RAMFS. XFS contributes read-only files to the root
  and has no subdirectories.
- There are no permissions, owners or timestamps, and no symbolic links.
- A directory can only be removed when it is empty; there is no recursive
  delete.
- RAMFS still has 32 slots and 80 KiB per file; directories consume slots.
- `ls -l` prints `dir <name>` for directories and `<size> <name>` for files.
