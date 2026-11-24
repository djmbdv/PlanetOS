# 10 — Dynamic Libraries (`library/`, `.dlib`, `.hlib`)

This document specifies PlanetOS's dynamic library architecture: the `library/<name>/` directory layout, the split between compiled binaries (`.dlib`) and type/generic interfaces (`.hlib`), implicit `glib` linking, O(1) hash-table ABI resolution, and selective `NEEDED` dependency loading.

---

## 1. Directory Layout (`library/`)

Each stdlib (or user) module lives in its own subdirectory under `library/`, containing both its compiled shared image and its compiler interface definition:

```text
library/
  glib/
    glib.dlib      # compiled PLAN shared library (.text, .rodata, .data/.bss, export hash table)
    glib.hlib      # Vala interface declarations + generic/AsmBody templates
  gee/
    gee.dlib
    gee.hlib
  gio/
    gio.dlib
    gio.hlib
  cairo/
    cairo.dlib
    cairo.hlib
  gdk/
    gdk.dlib
    gdk.hlib
  pango/
    pango.dlib
    pango.hlib
  spirv/
    spirv.dlib
    spirv.hlib
  venus/
    venus.dlib
    venus.hlib
  gsk/
    gsk.dlib
    gsk.hlib
  gtk/
    gtk.dlib
    gtk.hlib
  gobject/
    gobject.dlib
    gobject.hlib
  gmodule/
    gmodule.dlib
    gmodule.hlib
```

When `planc --target=planetos --format=dlib ... -o library/<name>/<name>.dlib` compiles a library, it emits **both** `<name>.dlib` and `<name>.hlib` side by side in the same directory.

On the PlanetOS XFS disk image, the same `library/<name>/` structure is mirrored at `/library/<name>/<name>.{dlib,hlib}` so both in-guest `planc` compilations and the kernel `ElfLoader` use identical paths.

---

## 2. `.dlib` vs `.hlib`

| Artifact | Consumer | Contents |
|---|---|---|
| `<name>.dlib` | Kernel (`ElfLoader`) & `planc` | `PLAN` v1/v2 binary image: `.text` (RO), `.rodata` (RO), `.data+.bss` template (private RW per process), `NEEDED` dependency list, and an FNV-1a 64-bit export hash table. |
| `<name>.hlib` | `planc` | Vala interface file: public `namespace`, `class` (with all fields in ABI-stable order), `struct`, `enum`, `interface`, `delegate`, `errordomain`, and bodyless function/method signatures, plus full bodies for generics (`Gee.ArrayList<T>`, etc.), `[AsmBody]` wrappers, and constants. |

Because `.hlib` uses Vala interface syntax, `planc` parses it with its existing `Lexer`/`Parser` without a separate binary AST format:
- Non-generic declarations from a `.hlib` are marked as imported from `<name>.dlib` (no code is emitted in the consumer).
- Generic templates and `[AsmBody]` functions from `.hlib` are instantiated/monomorphized directly in the consumer.

---

## 3. Implicit `glib` Linking

`glib` (`library/glib/glib.dlib` + `library/glib/glib.hlib`) is PlanetOS's foundational runtime library:
- **Runtime (Kernel)**: `ElfLoader` loads `/library/glib/glib.dlib` once into the reserved `0x1800000..0x2000000` window and maps its `.text+.rodata` read-only (`0x05`) and a private `.data+.bss` copy (`0x07`) into every user process.
- **Compile time (`planc`)**: When `--target=planetos` is active, `planc` implicitly loads `glib.hlib` / `glib.dlib` unless `--freestanding` or `--nostdlib` is passed (used when building the kernel, `init.elf`, or `glib.dlib` itself).

---

## 4. ABI Stability via Symbol Hash Table

To allow updating a `.dlib` without recompiling every consumer binary:

1. **Export Hash Table (`.dlib`)**:
   - `planc --format=dlib` builds an open-addressed hash table (FNV-1a 64-bit of the mangled symbol name, load factor `<= 50%`, stored right after the export list with `ht_buckets` at `PLAN` header `+36`) mapping `(hash64, symbol_vaddr)` in 16-byte buckets.
2. **GOT / Stubs in Consumers (`.elf`, `.plan`, `.dlib`)**:
   - Instead of hardcoding a `.dlib`'s absolute `.text` address in `call rel32` or `.rodata` vtables, the consumer allocates an 8-byte GOT slot in `.data` and emits a 6-byte `jmp *slot(%rip)` (`FF 25 rel32`) stub in `.text` for each imported symbol actually referenced.
   - Consumers record 24-byte import entries `(dlib_hash64, sym_hash64, got_slot_vaddr)` in `PT_PLANET_IMPORTS` (`0x70000001`) for ELF64 binaries or in the `PLAN` metadata (`import_count` at `+32`) for `.plan`/`.dlib` images.
3. **O(1) Load-Time Binding (`ElfLoader`)**:
   - `ElfLoader` loads each `.dlib`'s hash table from `/library/*/` and resolves every GOT slot in O(1) at load time (for executables and cross-`.dlib` dependencies) before entering userland.

---

## 5. Selective Dependency Linking (`NEEDED`)

Programs should neither declare nor map libraries they do not use:

- **Compile time (`planc`)**: After codegen, `planc` inspects `emitter.calls` and `rodata_patches` and emits GOT/import records only for symbols that were actually referenced.
- **Runtime (`ElfLoader`)**: `ElfLoader` computes the transitive closure of `.dlib` dependencies (`shared_deps_mask`) and records each binary's `NEEDED` bitmask from its import records. `map_shared_dlibs_into` maps `glib.dlib` (implicit) plus only the `.dlib`s in that binary's `NEEDED` mask and their transitive dependencies. Processes like `wc.elf` or `worker.elf` never receive private `.data+.bss` pages for `gtk.dlib` or `pango.dlib`.
