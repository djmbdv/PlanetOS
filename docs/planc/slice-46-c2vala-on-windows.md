# Slice 46: running the native C → Vala translator on Windows

## Goal

`tools/c2vala/` is a pure-Vala C → Vala translator, but it is built with
`planc`, and planc emits **ELF**. On Windows that binary cannot even be
started (`WinError 193: not a valid Win32 application`), so the harness — which
defaults to testing the native implementation — could not run outside the guest.
This slice makes the *same sources* build for the host with `valac`, so the
translator is testable natively on Windows, and fixes the places where the
emitted Vala was only valid because planc is more permissive than valac.

## Two toolchains, one translator

| Build | Command | Output | Host primitives |
|---|---|---|---|
| guest | `tools/c2vala/build.sh` | ELF (`build/c2vala`) | [planc/src/host_native.vala](/C:/Users/Lenovo/PlanetOS/planc/src/host_native.vala) + [planc/src/buffer.vala](/C:/Users/Lenovo/PlanetOS/planc/src/buffer.vala) |
| host | `tools/c2vala/build_host.sh` | `.exe` on Windows, ELF elsewhere | [tools/c2vala/host_glib.vala](/C:/Users/Lenovo/PlanetOS/tools/c2vala/host_glib.vala) |

Only two things are swapped: `Planc.Host` (file I/O, stdout, exit) and
`Planc.StrBuilder`. Everything else — preprocessor, lexer, parser, translator —
is the same file for both builds, because the planc dialect is a subset of Vala.

`host_glib.vala` does **not** link `buffer.vala`: that file declares
`Planc.FileError`, and with GLib's `FileError` also in scope every
`catch (FileError e)` in the translator becomes `error: FileError is an
ambiguous reference`. The host build therefore uses GLib's error domain
directly, which is what `FileUtils` throws anyway.

## What valac rejects that planc accepted

Running the suite against the host build turned up four real emission bugs. All
of them are fixed in the shared source, so the guest output improves too:

| Symptom | Cause | Fix |
|---|---|---|
| `int start = parser.pos;` — cannot convert `uint32` to `int` | declarations emitted the initializer without the target type | `coerce_value ()` on scalar/enum declarators |
| `token.start = parser.pos;` | assignments emitted both sides verbatim | `coerce_assign ()` casts to the target's Vala type (identifiers, array elements, struct members) |
| `buf[i] = 'A' + i;` into `uchar[]` | element type of a `char *` buffer is `uchar`, not `char` | array-element targets map `char` → `uchar`, matching the declaration |
| `jsmn_fill_token (…, (start + 1), parser.pos)` | call arguments were never converted to the parameter type | arguments are coerced to the declared parameter type |

Two language differences needed a source-level workaround instead:

- `GenericArray<int64>` — valac rejects value types as generic arguments and
  demands `int64?`; planc rejects nullable value types. The field became an
  `int64[]` with a `push_enum_val ()` helper, which both compilers accept.
- `throw` at the end of a function whose every path falls through a
  `void … throws` helper (e.g. `refuse_loc`): valac requires a terminator,
  planc does not care. Four methods now end with an explicit
  `throw new RefuseError.FAILED ("unreachable");`.

## Unions are planc-only

The native translator maps a C union to a Vala `union`, which is a **planc
extension** — valac has no union type. The `unions` case therefore carries a
`planc_only.txt` marker and the harness skips it when the generated code will be
compiled by valac. `c2vala.py` refuses unions outright, so that implementation
skips the case from the other side.

## Harness

`tools/c2vala_tests/run.py` now finds the translator itself:

- `build/c2vala.exe` or `build/c2vala`, whichever exists (`find_native ()`);
- `use_planc` is only true when the *planc binary itself* can run here
  (`runs_here ()` checks for a PE header on Windows), so the harness never
  tries to execute a Linux ELF on Windows;
- a case directory with `planc_only.txt` is skipped unless planc is the
  compiler for the generated code.

```
python tools/c2vala_tests/run.py --translator vala   # native build (Windows .exe here)
   5 passed, 0 failed   (arith, jsmn, malloc_arrays, partial, structs;
                         refused_union += unions skipped: they need planc)
python tools/c2vala_tests/run.py --translator py     # the Python implementation
   6 passed, 0 failed
```

## Still open

- `planc` itself has no Windows target: it emits ELF only, which is why this
  slice went through valac. A `--target=windows` would need a PE32+ writer and a
  Win32 replacement for the `__planc_host_*` routines (they emit `syscall`
  today); see slice 45 for the same problem on the graphics side.
- The strictness fixes are driven by the cases we have. Wider C corpora will
  find more implicit conversions (e.g. `unsigned` ↔ `int` in compound
  assignments, which are still emitted verbatim).
