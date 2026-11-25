# 03 — `planetrt`: runtime and standard library

## 1. Boundary with the compiler

The separation is strict:

| Belongs to `planc` | Belongs to `planetrt` |
|---|---|
| Type layout, vtables, itables, *mangling* | Implementation of `ref`/`unref`, type descriptors |
| Insertion of `ref`/`unref` | Counters, weak reference table |
| Generated signal dispatch | Handler storage, high-level connection and emission |
| `async` state machine | Coroutine scheduler, timers |
| Construction of `PlanetError` in `throw` | `PlanetError` type, domains, formatting |
| Calls to `alloc`/`free` | Per-profile allocators |

`planc` does **not** contain runtime business logic, and `planetrt` does **not** contain generated code. If a responsibility is in the wrong place, it appears duplicated in the three profiles and the three versions diverge.

## 2. Object model

### 2.1 Instance and descriptor

```
class instance                        type descriptor
┌──────────────────────┐              ┌───────────────────────────┐
│ vtable*              │─────────────▶│ padre*                    │
│ refcount   uint32    │              │ nombre                    │
│ banderas   uint32    │              │ tamano_instancia          │
│ fields…              │              │ interfaz*[]               │
└──────────────────────┘              │ senal[]                   │
                                      │ propiedad[]               │
                                      │ finalizar                 │
                                      └───────────────────────────┘
```

- The descriptor is **static**, in `.rodata`. There is no runtime registration.
- `finalizar` is emitted only if the type declares `~destructor` or has fields that need it.
- The flags include `COMPACTO`, `SIMPLE`, `TIENE_SENALES`, `TIENE_DEBILES`, which allow the runtime to skip work.

### 2.2 Reference counting

```vala
public void* planet_ref(void* obj) {
    if (obj != null) {
        var i = (Instancia*) obj;
        atomic_inc(&i->refcount);
    }
    return obj;
}

public void planet_unref(void* obj) {
    if (obj == null) return;
    var i = (Instancia*) obj;
    if (atomic_dec_y_cero(&i->refcount)) {
        debiles_notificar(i);          // nulls the weak references before freeing
        if (i->vtable->finalizar != null) i->vtable->finalizar(i);
        planet_liberar(i);
    }
}
```

Invariants:

- The counter never reaches zero while an `owned` reference exists.
- `unref` is **not** called with the object's locks held.
- `debiles_notificar` runs before `finalizar`: a `weak` never sees freed memory.
- Cycles are filtered out by design (§5 of [02](02-compiler.md#5-memory-model)).

### 2.3 Weak references

Every object with the `TIENE_DEBILES` flag carries a list of slots. On free, they are walked and set to `null`. The operation is O(n) in the number of weak references of the object, not global.

## 3. Text

### 3.1 Strings

```
string → ┌──────────┬──────────┬──────────┬─────────────────────────────┐
         │ refcount │ hash     │ length   │ bytes UTF-8 … 0x00          │
         └──────────┴──────────┴──────────┴─────────────────────────────┘
```

| Operation | Behaviour |
|---|---|
| `+` | concatenation with a new refcount |
| `longitud` | O(1) read of the header `length` field (`uint64`) |
| `sub` | new string; never a view over the original |
| `comparar` | byte by byte, not by *code point* |
| `hash` | 64-bit FNV-1a, cached in the `hash` field; `0` means "not computed" |

The encoding is UTF-8 and it is validated when constructing from external bytes. A `string` can contain invalid sequences if the programmer forces it; the iteration functions treat them as bytes.

### 3.2 Formatting

Without `va_list` (VL-11), formatting is a **compiler intrinsic**:

```vala
print(@"hola $nombre, $n elementos");
```

it is lowered to a sequence of typed calls:

```vala
salida.escribir("hola ");
salida.escribir(nombre);
salida.escribir(", ");
salida.escribir_entero(n);
salida.escribir(" elementos");
```

Consequences:

- There is no format analysis at runtime: a type error is a compile error.
- There is no `%f`, `%s` or conversion table on the execution path.
- The only delicate point is **`escribir_flotante`**: correct decimal conversion with exact round-trip (RT-08). It is implemented once, tested against an oracle and shared with introspection.

### 3.3 Unicode

Tables generated at build time from `UnicodeData.txt` (RT-09), with compressed ranges. Character properties and classification are offered. **There is no normalization** (NFC/NFD) and no grapheme segmentation: they are not requirements and their cost is disproportionate.

## 4. Arrays and containers

```
T[] → ┌──────────┬──────────┬──────────────────────────────┐
      │ refcount │ longitud │ elementos …                  │
      └──────────┴──────────┴──────────────────────────────┘
```

- `longitud` is `size_t` and is queried in O(1).
- An array can be `unowned`: then the pointer points directly to the elements and the header does not exist. The compiler distinguishes both cases in the type.
- Array literals are materialized in `.rodata` if they are constant.

Container library, all in Vala on top of the profile allocator:

| Type | Structure | Notes |
|---|---|---|
| `Lista<T>` | dynamic array | 1.5× growth, O(1) index |
| `ListaEnlazada<T>` | doubly linked | no block allocation |
| `Diccionario<K,V>` | open hash table with *tombstones* | iteration order not defined |
| `Conjunto<T>` | hash table | — |
| `Cola<T>` / `Pila<T>` | circular array | — |
| `BufferBytes` | `uint8` array with length and capacity | I/O |

Hash and equality are resolved at compile time: for types with their own `hash()`/`igual()` those are used; for integers, their value; for strings, FNV-1a.

## 5. Signals

The compiler generates emission (§7 of [02](02-compiler.md#7-signals)); the runtime provides:

```vala
public class NodoSenal {
    public void*  codigo;      // typed function pointer
    public void*  destino;
    public void*  datos;
    public uint32 banderas;    // BLOQUEADO, DESCONECTADO_AL_EMITIR, UNO_SOLO
    public NodoSenal? siguiente;
}
```

| Operation | Requirement |
|---|---|
| `conectar` | inserts before the `RUN_LAST` ones; returns a stable identifier |
| `desconectar` during emission | marks `DESCONECTADO_AL_EMITIR`; it is freed when the traversal ends |
| `bloquear` | prevents the call without altering the order |
| recursive emission | depth counter per signal, configurable limit |
| emission without allocating | the traversal does not reserve memory (RT-06) |

## 6. Main loop and coroutines

### 6.1 Event sources

```vala
public abstract class Fuente : Object {
    public abstract bool preparar(out int64 timeout_ns);
    public abstract bool comprobar();
    public abstract bool despachar();
}
```

`Planet.Eventos.Principal` keeps a queue of ready sources and a list of sources with a timer. Its loop is:

```
while there are sources:
    prepare all → minimum timeout
    if there are ready ones: dispatch
    if not: sleep until the minimum or until an IRQ/channel wakes it up
```

In the `kernel` profile, sleeping is `sti; hlt`; in `user`, `chan_recv` with a timeout; in `host`, the host's `poll`.

`Gio.InputStream` and `OutputStream` are synchronous: there is no `read_async`.
A stream pipeline inside `MainContext` therefore runs each stage as a coroutine
that yields on readiness (VL-08); a blocking `read` in the loop stalls every
source. Readiness is reported per handle, not per global fd
([08](08-io-data-path.md)).

### 6.2 Coroutines

The compiler generates the state machine (§8 of [02](02-compiler.md#8-coroutines-and-errors)); the runtime provides the `Tarea` object, the ready task queue and the integration with sources:

| Piece | Responsibility |
|---|---|
| `Tarea` | result, error, continuations, state |
| `esperar(tarea)` | suspends the current coroutine and resumes it when it completes |
| `FuenteTarea` | adapts a `Tarea` to a `Fuente` so that it can be awaited in the loop |
| timer | `FuenteTemporizador` with 1 ms resolution in kernel and `user` |

Without `GTask`, without hidden threads, without thread pools: a coroutine runs on the thread that resumes it.

## 7. Errors

```vala
public class Error : Object {
    public string dominio { get; construct; }
    public int    codigo  { get; construct; }
    public string mensaje { get; construct; }
}
```

As in Vala, an `errordomain` groups codes. The difference is the transport: a hidden out parameter, not `GError**` with a C ABI (§8.2 of [02](02-compiler.md#82-throws)). The type is ours and so is its symbol name.

## 8. Profiles

The profile is selected with `--perfil` and changes only the `planetrt/perfil/` package.

### 8.1 `host`

| Service | Implementation |
|---|---|
| allocator | host allocator |
| locking | host threads |
| time | host monotonic clock |
| I/O | host descriptors |
| startup | host `main` function |

This profile is **for development and testing** (VE-01). It is the only place where the runtime talks to a foreign operating system. The directory is excluded from the `kernel` and `user` builds, and VE-02 fails if a host symbol appears outside it.

### 8.2 `kernel`

| Service | Implementation |
|---|---|
| allocator | slab by size + buddy for large blocks |
| locking | spinlock with local `cli`/`sti` |
| time | invariant TSC, HPET as fallback |
| log I/O | 1650 UART and framebuffer |
| panic | `Asignador` does not return `null`: it panics with a diagnostic |

In this profile **`alloc` never fails silently**. An allocation failure in the kernel is a bug, not a recoverable condition, and it is treated as such.

### 8.3 `user`

| Service | Implementation |
|---|---|
| allocator | arena over `mem_brk` + `mem_map` for large blocks |
| locking | futex on channel |
| time | `time_mono` |
| I/O | `file_read`/`file_write` and `chan_*` |
| startup | `_start` in `[AsmBody]` → `planet_iniciar` |

## 9. Standard library

Everything is Vala compiled by `planc` (RT-07). No third-party binaries, no external headers.

| Package | Content |
|---|---|
| `Planet.Nucleo` | `Object`, `ref`/`unref`, descriptors, allocator, panic |
| `Planet.Texto` | strings, formatting, UTF-8, string builder |
| `Planet.Colecciones` | lists, dictionaries, sets, queues, buffers |
| `Planet.Eventos` | sources, main loop, timers |
| `Planet.Corrutinas` | `Tarea`, `esperar`, adapters |
| `Planet.Errores` | `Error`, domains, propagation |
| `Planet.Sistema` | processes, files, channels, environment, time |
| `Planet.Shell` | command-line parsing, quoting, expansion |
| `Planet.Config` | reading and writing of key-value manifests |
| `Planet.Pruebas` | assertions and suite execution, usable inside the system |

The `Planet.Pruebas` package is not a luxury: without it, verification inside the system (VE-05) does not exist.

### 9.1 Implemented subset (slices 27–35)

| Package / file | Content |
|---|---|
| `Planet.Sys` ([stdlib/planet_sys.vala](../../stdlib/planet_sys.vala)) | the only userland `int 0x80` trampoline plus typed wrappers for files, directories, processes, memory and console, validated before the call |
| `GLib` ([stdlib/glib/](../../stdlib/glib/core.vala)) | `StringBuilder`, `FileUtils`, `Str`, `Environment`, `Math` (`stdlib/glib/math.vala`), `Process`/`SpawnError`/`SpawnFlags` (`stdlib/glib/process.vala`), `KeyFile` (`stdlib/glib/keyfile.vala`), `MainContext`/`MainLoop` (`stdlib/glib/mainloop.vala`), and memoized ReDoS-safe `Regex`/`MatchInfo` (`stdlib/glib/regex.vala`) |
| `Gee` ([stdlib/gee/](../../stdlib/gee/base.vala)) | `gee-0.8` generic delegates (`CompareDataFunc`, `HashDataFunc`, `EqualDataFunc`, `Predicate`, `ForallFunc`, `MapFunc`) and interfaces (`Iterator`, `Iterable`, `Collection`, `List`, `Set`, `Queue`, `Deque`), `ArrayList` (Introsort), `LinkedList`, `HashSet`/`HashMap` (Robin Hood hashing + backward-shift deletion), `ArrayQueue`, and `PriorityQueue` |
| `Gio` ([stdlib/gio/](../../stdlib/gio/file.vala)) | `File` (with bitmask flags, `make_backup`, safe `load_contents`), `FileInfo`, `FileEnumerator`, `InputStream`/`OutputStream` (`write_string`, `Memory*`, `Buffered*`, `Data*`), `Cancellable`, `ListStore` (`splice`), `SimpleAction`, `AppInfo`, `Application` |
| `Cairo` ([stdlib/cairo/](../../stdlib/cairo/context.vala)) | surfaces, context, AVX2 32-bit fill/blit, scanline + FMA3 polygon rasterizer |
| `Gdk` ([stdlib/gdk/](../../stdlib/gdk/window.vala)) | `RGBA`, `Event`/`EventType.SCROLL`, `Window`, `Display` (framebuffer, compositor `PWIN` files, and zero-copy shared compositor surfaces with damage rectangles and a shared input ring, IntelliMouse wheel) |
| `Gsk` ([stdlib/gsk/](../../stdlib/gsk/nodes.vala)) | `Rect`/`RoundedRect`, render nodes (including `ShaderNode`, which bakes a compiled SPIR-V module into Cairo blocks), `CairoRenderer`/`VulkanRenderer`, and `Gsk.Path` SVG parser with FMA3/hw sqrt |
| `Gtk` ([stdlib/gtk/](../../stdlib/gtk/window.vala)) | `GtkWindow`, `Box`, `Frame`, `ScrolledWindow` (draggable scrollbar + wheel), `Paned`, `Notebook`, `ListView`, `Switch`, `Scale`, `Entry`, `Button`; widgets queue damage rectangles so a repaint covers only what changed, and keys are routed to the single focus owner (`grab_focus`) before any legacy handler |
| `GObject` ([stdlib/gobject_compat.vala](../../stdlib/gobject_compat.vala)) | `Type` ids, `type_register`/`type_name` and the tagged `Value` container |
| `Spv` ([stdlib/spirv_compat.vala](../../stdlib/spirv_compat.vala)) | SPIR-V 1.0 module loader and pure-Vala SSA evaluator: fragment color, `GLSL.std.450` scalar math, push-constant params (`set_params`) and local-coordinate origin (`set_origin`), plus word/insn counts |
| `Pango` + `PangoCairo` ([stdlib/pango_compat.vala](../../stdlib/pango_compat.vala)) | font descriptions, layout metrics, word wrap, ellipsize, alignment and text drawing |
| `GModule` ([stdlib/gmodule_compat.vala](../../stdlib/gmodule_compat.vala)) | `Module` with `NOT_SUPPORTED` for `open()` (no dynamic linker) and a static module/symbol registry |
| `pluto` / `saturn` ([user/pluto.vala](../../user/pluto.vala), [user/saturn.vala](../../user/saturn.vala)) | native nano-style terminal editor (`pluto.elf`) and Geany-inspired GTK IDE (`saturn.elf`) |

The compatibility layers sit **above** `Planet.Sys`: they never issue a syscall
themselves, and `Planet.Sys` depends on nothing but the compiler. Keeping the
ABI in its own package is deliberate — `GLib`/`Gio`/`Cairo` are convenience
shims, not the contract with the kernel.

## 10. Source compatibility with existing Vala

**It is not a requirement.** A Vala program written for GLib uses `GLib.` and `GObject.` and will not compile.

Only one optional path is evaluated, on technical grounds:

| Option | Description | Cost |
|---|---|---|
| **No layer** | Only `Planet.*`. New code. | None |
| **`glib-src.vapi`** | A `.vapi` that declares `GLib.*` and an implementation in Vala that maps whatever has an equivalent form | Only the subset that is used is implemented; there is no ABI involved, only names |
| **Source translation** | Tool that rewrites `GLib.` to `Planet.` | Fragile; only for mechanical cases |

The middle option is viable precisely because there is no ABI: `GLib.StringBuilder` can be an alias of `Planet.Texto.Constructor` with no binary consequence. It is decided in [07](07-risks-and-decisions.md#4-open-decisions) and it blocks nothing.

## 11. Runtime risks

| Risk | Signal | Mitigation |
|---|---|---|
| Refcount imbalance | Objects that are freed too early or never | Exact counters in the `host` profile; `alloc_count == free_count` at the end of each suite (RT-04) |
| `unref` with a lock held | Sporadic deadlock | The compiler cannot detect it: it is audited in review and the rule is documented |
| Race in `refcount` | Corruption only with several threads | Stress test; `lock` mandatory unless explicitly annotated |
| Signal emission allocates memory | Failure in IRQ context | Test with the allocator blocked (RT-06) |
| Inexact floating-point formatting | Numbers that do not return to their original value | Round-trip test against an oracle (RT-08) |
| Disproportionate Unicode tables | Bloated binary | Compressed ranges generated at build time (RT-09) |
| The `host` profile leaks dependencies into the target | Host symbol in a system binary | Per-directory symbol audit (VE-02) |

## 12. GLib API expansion (runtime quality and throughput)

The compatibility layer now covers the GLib pieces that mapped directly to existing
hot paths, without importing the C ABI:

- **`GLib.HashTable`** ([stdlib/glib/hashtable.vala](../../stdlib/glib/hashtable.vala)):
  `HashTableIter`, `lookup_extended`, `steal`, `steal_extended`, `foreach_remove`,
  `foreach_steal`, `get_keys`/`get_values`, `length`, `@get`/`@set` and
  `steal_all`. `KeyFile` uses it for group/key lookup and `c2vala`'s host
  `NameIndexMap` is backed by it.
- **`GLib.Source` / `MainContext`** ([stdlib/glib/mainloop.vala](../../stdlib/glib/mainloop.vala)):
  public `Source`, `TimeoutSource`/`IdleSource`/`IOSource` semantics through
  `Source.attach`, `set_priority`, `destroy`, `find_source_by_id`,
  `MainContext.invoke`, `push_thread_default`/`pop_thread_default` and
  `child_watch_add`. Timeouts and fd watches (priority 0) now run before idle
  sources (priority 200), so a permanently-ready idle callback cannot starve a
  timer. The fd-watch buffer grows instead of being capped at eight entries.
- **`GLib.Private`, `GLib.ThreadPool`** ([stdlib/glib/thread.vala](../../stdlib/glib/thread.vala)):
  per-task slots through `SYS_TID` (syscall 62) and a fixed worker pool over
  `AsyncQueue`. `AsyncQueue` now parks on `Cond` instead of spinning on
  `SYS_YIELD`.
- **`GLib.Thread` is a kernel task on `--target=planetos`** ([planc/src/emitter.vala](../../planc/src/emitter.vala),
  [stdlib/glib/thread.vala](../../stdlib/glib/thread.vala)): `__planc_thread_spawn`
  lowers to `SYS_THREAD_SPAWN` (27) and `__planc_thread_join` to `SYS_WAIT` (17).
  The trampoline ends the task with `SYS_EXIT` because a kernel task has no
  return address; `ThreadPool` therefore has real workers.
- **Thread stack lifecycle** ([kernel/sched.vala](../../kernel/sched.vala),
  [kernel/vmm.vala](../../kernel/vmm.vala)): the stack name is written only
  after the range is mapped, and a reaped stack is remapped supervisor-RW before
  `Pmm` writes its free-list metadata into the frames.
- **`GLib.PathBuf`, `GLib.StrvBuilder`, `GLib.ByteOrder`, `GLib.Aligned`**
  ([stdlib/glib/core.vala](../../stdlib/glib/core.vala)): path joins in
  `Gio.File`, argv construction in `Shell.parse_argv`, byte-order helpers in
  `Gio.DataInputStream`, and explicit 32/64-byte allocations for SIMD users.
  `Str` gained `strv_length`, `strfreev`, `strsplit_set` and `strescape`;
  `StringBuilder.append` uses `Memory.copy` and exposes `steal ()`.
- **`GLib.VariantBuilder`, `VariantDict`, `VariantIter`**
  ([stdlib/glib/variant.vala](../../stdlib/glib/variant.vala)): container
  construction and mutation on top of the existing immutable `Variant`.
- **Allocator and I/O alignment** ([stdlib/glib/memory.vala](../../stdlib/glib/memory.vala),
  [stdlib/planet_sys.vala](../../stdlib/planet_sys.vala),
  [stdlib/gio/file.vala](../../stdlib/gio/file.vala)): `Memory.malloc` returns
  32-byte aligned blocks; `Sys.read_into`/`write_from` fill or drain a buffer
  slice in place, and `Gio.File.load_contents` no longer allocates a temporary
  chunk per read. `planc`'s PlanetOS host adapter uses the same primitives.
- **`DateTime`** ([stdlib/glib/time.vala](../../stdlib/glib/time.vala)): local
  conversion, day-of-week/day-of-year and custom `strftime` formatting.
- **`AtomicUint`** ([stdlib/glib/atomic.vala](../../stdlib/glib/atomic.vala)):
  32-bit atomic get/set/add/decrement/CAS.

### 12.1 Time zones, dates, URIs and markup (slice 54)

| API | File | Used by |
|---|---|---|
| `GLib.Date` (+ `DateMonth`, `DateWeekday`, `DateDMY`) and `GLib.TimeZone` | [stdlib/glib/time.vala](../../stdlib/glib/time.vala) | compositor calendar, top-bar clock |
| `GLib.Uri`, `UriFlags`, `UriError` | [stdlib/glib/uri.vala](../../stdlib/glib/uri.vala) | places list, bookmark validation |
| `GLib.BookmarkFile`, `BookmarkFileError` | [stdlib/glib/bookmark.vala](../../stdlib/glib/bookmark.vala) | compositor `places` window |
| `GLib.MarkupParser` + `MarkupParseContext` | [stdlib/glib/utils.vala](../../stdlib/glib/utils.vala) | `cursor.svg` `<path d>` extraction |
| `GLib.OptionGroup` | [stdlib/glib/test_option.vala](../../stdlib/glib/test_option.vala) | `wc --help` sections |
| `GLib.Hmac`, `Checksum.get_digest` | [stdlib/glib/codec.vala](../../stdlib/glib/codec.vala) | `places.gbk` signature |
| `GLib.Datalist` | [stdlib/glib/core.vala](../../stdlib/glib/core.vala) | per-window month state (`Win.set_data`) |

`get_real_time ()` now decodes the packed `SYS_RTC_TIME` fields into epoch
seconds, so `DateTime.now_utc ()`, `Date.today ()` and `TimeZone.get_offset`
see a real clock instead of the packed word.

Two dialect limits shaped the shim and are documented in
[slice 54](../planc/slice-54-calendar-and-uri.md): `planc` passes struct `this`
by value, so `GLib.Date` is a class here; and default arguments are only filled
for a call that initialises a `var`, so call sites spell out `UriFlags.NONE` /
`-1` explicitly.

Deliberately deferred: `MappedFile` (needs a file-backed mmap syscall) and the
collection compatibility classes `List`/`SList`/`Sequence`/`Tree`/`PtrArray`/
`GenericSet` (Gee already provides these containers; `GLib.List`'s
`[ReturnsModifiedPointer]` and null-receiver idiom do not map cleanly onto the
`planc` dialect).

## 13. Recent GLib & `c2vala` runtime additions

- **`GLib.StringChunk` & `GLib.ByteArray`** ([stdlib/glib/core.vala](../../stdlib/glib/core.vala), [stdlib/glib/bytes.vala](../../stdlib/glib/bytes.vala), [stdlib/gio/streams.vala](../../stdlib/gio/streams.vala)): `StringChunk` provides `insert`, `insert_len`, `insert_const` (FNV-1a deduplication), `clear`, and `free`. `ByteArray` provides `ByteArray.sized`, `ByteArray.take`, `append`, `append_byte`, `get_byte`, `copy_to`, `write_at`, `to_string`, `prepend`, `remove_index`, `remove_index_fast`, `remove_range`, `set_size`, and `steal` (with null/overflow guards), alongside `Bytes.from_byte_array`. `MemoryInputStream`, `MemoryOutputStream`, and `DataInputStream.read_upto`/`read_line` use `ByteArray` internally.
- **`GLib.FileStream` & `GLib.Error` extensions** ([stdlib/glib/filestream.vala](../../stdlib/glib/filestream.vala), [planc/src/codegen.vala](../../planc/src/codegen.vala)): Pure-Vala `GLib.FileStream` and `GLib.FileSeek` over `Sys.*` syscalls with 4 KiB read buffering, `read_line`/`gets`, and lazy `get_stdin ()`/`get_stdout ()`/`get_stderr ()` accessors. `planc` adds `Error.matches (domain, code)` and `Error.copy ()` on `ValaType.ERROR`, fixes `ThrowStatement` code/message slots, and restores `rdi` (`args`) after `__planc_init_globals` in `_start`.
- **`GLib.Quark`, `PatternSpec`, `Shell`, `Markup`, `Test`, and `OptionContext`** ([stdlib/glib/utils.vala](../../stdlib/glib/utils.vala), [stdlib/glib/test_option.vala](../../stdlib/glib/test_option.vala)): Interned `Quark` table, `O(N*M)` glob `PatternSpec`, `Shell.parse_argv`/`quote`/`unquote` (reused by `Process.split_command_line`), `Markup.escape_text`/`unescape_text`/`strip_tags` (with Unicode bounds checks), `Test` unit-test harness, and `OptionContext`/`OptionEntry` CLI parser (used by `gtk_demo` and `wc`).
- **`Gtk` integration with `GLib`, `Gsk`, and `Gio`** ([stdlib/gtk/widget.vala](../../stdlib/gtk/widget.vala), [stdlib/gtk/widgets.vala](../../stdlib/gtk/widgets.vala), [stdlib/gtk/container.vala](../../stdlib/gtk/container.vala), [stdlib/gtk/listview.vala](../../stdlib/gtk/listview.vala), [stdlib/gtk/window.vala](../../stdlib/gtk/window.vala)): `Widget.render ()` applies `Widget.opacity` via `Gsk.OpacityNode`; `GtkWindow.run ()` dispatches `GLib.MainContext.default_ ()`, forwards pointer events to `titlebar`, runs `allocate_children ()` on `queue_resize ()`, and calls `close ()` on `Escape`; `GtkApplication` inherits `Gio.Application`; `ListView.set_model ()` binds `Gio.ListStore<string>` with incremental `append` updates; `Entry` adds `cursor_pos` navigation (`Left`/`Right`/`Home`/`End`/`Delete`) and cursor blink via `GLib.timeout_add`; `Label`/`Button`/`CheckButton` add `set_markup ()`; and `HeaderBar` provides a horizontal titlebar container.
- **Userland shell globs & `wc` flags** ([user/shell.vala](../../user/shell.vala), [user/wc.vala](../../user/wc.vala)): `shell.vala` expands `*`/`?` globs via `GLib.PatternSpec.match_simple ()`, and `wc.vala` supports `-l`/`-w`/`-c`/`-m` via `GLib.OptionContext`.
- **Consolidated `Sys.byte_arr_addr` & shared stdlib `.dlib`/`.hlib` modules** ([stdlib/planet_sys.vala](../../stdlib/planet_sys.vala), [run-qemu.sh](../../run-qemu.sh), [10-dynamic-libraries.md](10-dynamic-libraries.md)): `Sys.byte_arr_addr (uint8[] a)` replaces 9 duplicate per-file array-address helpers across `stdlib/glib/`, `stdlib/gio/`, and `stdlib/gtk/` without `__PlancPtr` boxing. All 12 stdlib modules (`glib`, `gee`, `gio`, `cairo`, `gdk`, `pango`, `spirv`, `venus`, `gsk`, `gtk`, `gobject`, `gmodule`) are built as `.dlib` shared libraries in `0x1800000..0x2000000` and imported by userland binaries via `planc --import-dlib` (keeping monomorphized generics per-app and `abi_stable_classes` for layout compatibility). See [10-dynamic-libraries.md](10-dynamic-libraries.md) for the `library/<name>/<name>.{dlib,hlib}` layout, implicit `glib` linking, hash-table ABI, and selective `NEEDED` loading design.
- **`c2vala` translation & `c2vala_rt` updates** ([tools/c2vala/translator.vala](../../tools/c2vala/translator.vala), [tools/c2vala_rt.vala](../../tools/c2vala_rt.vala), [tools/c2vala_rt_posix.vala](../../tools/c2vala_rt_posix.vala)): `c_is*` / `c_to*` delegate to `((char) c).* ()`; C `DateTime` maps to `_c2v_DateTime`; `struct tm` zero-initialization maps `tm_*` fields to `GLib.Time`; `memcmp` on structs supports fixed-size scalar/enum array fields; pointer relational comparisons (`<`, `<=`, `>`, `>=`) emit `uintptr.from_pointer`; and `memcpy`/`memmove`/`memset`/`memcmp` coerce `string` arguments to `uint8[]`. The runtime is now split by host:
  - `tools/c2vala_rt.vala` is the PlanetOS build: it has no `FileStream` and no raw `read`/`write`/`openat`/`unlinkat`/`renameat` syscalls of its own. `stdin`/`stdout`/`stderr`, `c_fclose`/`c_fread`/`c_fwrite`/`c_fgets` are expressed against `GLib.FileStream` from `stdlib/glib/filestream.vala`, which `glib.dlib` provides; `FileStream.close_now ()` was added there because the Vala vapi's `FileStream` has no public `close ()`.
  - `tools/c2vala_rt_posix.vala` holds the host-Linux shims (`[AsmBody]` `syscall` wrappers, a private `FileStream`, `c_remove`, `c_rename`, `c_init_stdio_host`). `tools/c2vala_tests/run.py` builds `planc` binaries with both files plus `stdlib/glib/utils.vala` (needed by `c2vala_rt`) and `planet_sys.vala`.
  - `tools/c2vala_rt.vala` also compiles with `valac` (the host build used by `--translator py` and by `run.py` on Windows, where `planc` emits ELF): the PlanetOS-only parts sit behind `#if PLANC`, with `#else`/`#if !PLANC` branches for the vapi's shapes — `Memory.copy/move/set/cmp` take `void*` (the host branches use loops), `FileStream` has no `close_now ()` (host calls `fclose` through a guarded `[CCode]` extern), `FileStream` is `[Compact]` so `stdin`/`stdout`/`stderr` get `c2v_std*` C names to avoid the `stdio.h` macros, the pthread shims are omitted (valac's `Thread<T>`/`Cond.wait (Mutex)` differ), and `c_remove`/`c_rename` are provided with `FileUtils.remove`/`rename`.
  - In-guest builds: the translator emits `c2vala_init_globals ()`, which calls `c_init_stdio ()`, so the QEMU `c2vala` case now compiles the translated file together with [c2vala_sdk.vala](../../tools/make_sdk.py). [tools/make_sdk.py](../../tools/make_sdk.py) concatenates `planet_sys.vala` + `GLIB_SRCS` + `c2vala_rt.vala` into that one file and both launchers ship it in the boot image: `planc` type-checks the GLib declarations it compiles, `glib.dlib` exports only addresses, and the guest shell's 480-byte line buffer cannot list ~20 sources.
  - Translator emission keeps both compilers happy: a C `char buffer[N]` becomes `uint8[]` (so `c_fgets`/`c_fread` accept it) and reading an element of a byte buffer into a Vala `char` gets the explicit `(char)` cast valac requires (C's implicit narrowing).
  - Verified state: `python tools/c2vala_tests/run.py` passes 14/14 on Windows plus `refused_union`/`unions` skipped by design (`unions` needs a runnable `planc`), `tests/qemu.py` passes 18/18 including the in-guest `c2vala` case, and `run-qemu.sh`'s `jsmn_demo` link (`GLIB_SRCS` + `c2vala_rt.vala`, importing `glib.dlib`) links against the shared `GLib.FileStream`, so the previous `GLIB_JSMN_SRCS` workaround that dropped `filestream.vala` is gone.
- **In-guest `planc` file I/O** ([planc/src/host_planetos.vala](../../planc/src/host_planetos.vala)): `Sys.read`/`Sys.write` reject a single transfer above `Sys.MAX_IO` (64 KiB). The guest host adapter issued one read/write per file, so a source over 64 KiB parsed as an empty file ("the program does not define main") and an output ELF over 64 KiB failed with a short write. `read_file`/`read_bytes`/`write_file` now stream in 64 KiB chunks, and a short read raises `FileError` instead of silently truncating.
- **GLib ↔ kernel integration** ([stdlib/planet_sys.vala](../../stdlib/planet_sys.vala), [stdlib/glib/](../../stdlib/glib/mainloop.vala), [stdlib/gio/types.vala](../../stdlib/gio/types.vala)): `Sys.read`/`write`/`write_str` now chunk every request internally, so no layer above them has to know about `MAX_IO`. `Sys.errno_code ()`/`strerror ()` expose the kernel errno, `FileStream.error ()` returns it, `FileUtils.remove`/`rename`/`mkdir` return `-errno` and `Gio` maps it to `IOError.NOT_FOUND`/`PERMISSION_DENIED`/… `Mutex`, `RecMutex` and `Cond` use `SYS_WAIT_ADDR`/`SYS_WAKE_ADDR` (park/wake instead of polling), `MainContext` gained `add_watch`/`io_add_watch` over `SYS_POLL` and blocks until the next timeout, `GLib.Dir` enumerates `SYS_READDIR`, and `log_message`/`log_error`/`warning`/`critical`/`debug` plus `printerr` write into the kernel ring (`Klog` category 7). `user/sys_demo.vala` and the `system` QEMU case cover all of it.- **`GLib.ascii_strcasecmp` & `GLib.ascii_strncasecmp`** ([stdlib/glib/core.vala](../../stdlib/glib/core.vala)): Added case-insensitive ASCII string comparison helpers both as `GLib.Str.ascii_strcasecmp` / `GLib.Str.ascii_strncasecmp` and as top-level `GLib.ascii_strcasecmp` / `GLib.ascii_strncasecmp` functions.
- **`tools/sqlite3` regeneration (WIP)**
 ([tools/sqlite3/sqlite3_new.vala](../../tools/sqlite3/sqlite3_new.vala), [tools/sqlite3/test_sqlite3.vala](../../tools/sqlite3/test_sqlite3.vala)): `sqlite3_new.vala` is a fresh `c2vala` run over the vendored SQLite 3.47.2 amalgamation. Relative to `sqlite3.vala` the pointer analyzer now emits `C2VBox<...>?` / `C2VBox<T[]>?[]` for `**` out-parameters and pointer arrays, `uint8[]` for `char*` buffers (`zText`, `z`, `zMalloc`), `Vdbe` in place of the opaque `sqlite3_stmt` forward declaration, and `sqlite3?[]`/`sqlite3_value?[]` for `sqlite3**`/`sqlite3_value**`. It is **not** wired into `run-qemu.sh` yet and it does not compile with `planc`: the current build stops after 200 semantic errors, concentrated in `uint8[]` vs typed-pointer signatures left by the new pointer analysis (`sqlite3VdbeAddOp4Dup8`, `sqlite3DbFree`, `sqlite3CreateFunc`, `renameTokenFind`, …). `test_sqlite3.vala` was already switched to `Vdbe?[] stmt_out`, matching the new header; `sqlite3.vala` is still the translation that builds, and `sqlite3.dlib` was produced from it.


