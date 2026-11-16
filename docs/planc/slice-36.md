# Slice 36: Cairo/Gdk split, GObject and GModule compatibility layers

## Goal

Finish the compatibility stack: separate the Cairo and Gdk layers (one file
held both namespaces), add the `GObject` runtime pieces that source code uses
(GType ids and `GValue`), and add a `GModule` layer that is honest about a
statically linked system instead of pretending there is a dynamic loader.

## Changes

### 1. Cairo and Gdk are separate files (`stdlib/cairo_compat.vala`, `stdlib/gdk_compat.vala`)

The 476-line `cairo_gdk_compat.vala` held `namespace Cairo` (lines 1–337) and
`namespace Gdk` (lines 339–476). They are now two files:

| File | Content |
|---|---|
| [stdlib/cairo_compat.vala](../../stdlib/cairo_compat.vala) | `Format`, `ImageSurface`, `Context`, pixel helpers |
| [stdlib/gdk_compat.vala](../../stdlib/gdk_compat.vala) | `RGBA`, `Event*`, `Window`, the input/draw loop (uses `Cairo`) |

`cairo_demo` and `spv_demo` build with both; anything that only needs one can
include just that file. `run-qemu.sh`/`run-qemu.ps1` were updated.

### 2. GObject (`stdlib/gobject_compat.vala`)

The language already provides `Object`, static signals, properties and ARC. The
missing part is the type system:

- `GObject.Type`: the well-known `GType` ids (`INVALID`, `NONE`, `INT`,
  `BOOLEAN`, `DOUBLE`, `STRING`, `OBJECT`, …) with the same numeric values as
  GLib, plus `FIRST_REGISTERED = 100` for user types.
- `type_register (name)` returns a stable id for a name (`100 + index`);
  registering the same name twice returns the same id.
- `type_name (gtype)` maps well-known ids to their GLib names (`gint`,
  `gchararray`, …) and registered ids to their name.
- `Value`: tagged container with `set_int`/`get_int`, `set_uint`/`get_uint`,
  `set_int64`/`get_int64`, `set_boolean`/`get_boolean`,
  `set_double`/`get_double`, `set_string`/`get_string`, `get_value_type`,
  `unset`. Setters check the tag and return `false` on a type mismatch instead
  of storing a value of the wrong type.

### 3. GModule (`stdlib/gmodule_compat.vala`)

PlanetOS links statically: there is no `PT_INTERP`, no dynamic linker and no
`dlopen` (docs/05). The layer does not pretend otherwise:

- `Module.supported ()` returns `false`.
- `Module.open (path, flags)` throws `ModuleError.NOT_SUPPORTED` with
  `"PlanetOS has no dynamic linker; register modules statically"`.
- **PlanetOS extension** for statically linked plugins:
  `register_static (name, description)`, `is_registered`, `module_count`,
  `module_description`, `open_static (name)` → `ModuleHandle`,
  `register_symbol (module, symbol, address)` and
  `symbol_address (module, symbol)`. `ModuleHandle.has_symbol/get_symbol`
  resolve through that table; unknown symbols return `-1`.

### 4. Demos and image

- [user/gobject_demo.vala](../../user/gobject_demo.vala): **19 checks** —
  type ids/names, every `Value` setter/getter, wrong-type rejection, stable
  registration and `unset`.
- [user/gmodule_demo.vala](../../user/gmodule_demo.vala): **14 checks** —
  `supported()` false, `open()` refused, static registration, duplicate
  rejection, symbol table and missing-module error.
- Both are added to the XFS image (15 entries) and to the harness.

## Verification

```
== case compiler == PASS
== case directories == PASS
== case errors == PASS
== case exec == PASS
== case gio == PASS
== case objects == PASS
6/6 cases passed
```

`objects` runs `gobject_demo` and `gmodule_demo` in one boot:

```
gobject:summary checks=19 failures=0
gmodule:summary checks=14 failures=0
```

## Known limitations

- There is no reflection: properties and signals are resolved by the compiler,
  so `GObject.Object.get_property("name")`, `ParamSpec` and dynamic signal
  lookup are not implemented.
- `GModule` cannot load shared objects. The static registry is an extension of
  this layer, not part of GLib's API, and symbols are plain addresses because
  the dialect has no function-pointer values.
- `Value` stores scalars and strings only; object/boxed/variant payloads would
  need the ARC-aware object slots that the compiler does not expose yet.
