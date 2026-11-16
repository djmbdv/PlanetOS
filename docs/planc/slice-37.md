# Slice 37: GLib main loop (`MainContext`, timeouts, idle, `Application.run`)

## Goal

Give userland a real event loop: `GLib.MainLoop`, the default `MainContext`,
`idle_add`/`timeout_add`/`source_remove` sources, and an `Application.run()`
that actually drives it. Until now `Application.run()` emitted `activate` and
returned immediately, so nothing could stay alive waiting for a timer.

## Changes

### 1. Sources and context (`stdlib/glib_compat.vala`)

- `public delegate bool SourceFunc ()` — returning `false` removes the source.
- `Source` (private): `id`, `kind` (idle/timeout), `interval`, `due`, `removed`,
  `func`.
- `MainContext`:
  - `default_()` returns the process-wide context.
  - `add_idle(func)` / `add_timeout(interval_ms, func)` allocate increasing ids.
  - `iteration(may_block)` runs **one** ready source: idle sources first, then
    timeouts whose deadline is due; `may_block` yields the CPU once with
    `SYS_YIELD`.
  - `remove(id)`, `exists(id)`, `pending()`, `has_sources()`.
- Free functions mirroring GLib: `idle_add`, `timeout_add`, `source_remove`,
  `source_exists`.
- `MainLoop(context = null)` with `run()`, `quit()`, `is_running()` and
  `get_context()`.

Time comes from `SYS_TICKS` (100 Hz), so intervals are rounded up to the next
10 ms tick. A timeout is rescheduled before its callback runs, so a callback
that returns `true` keeps firing until it returns `false` or is removed.

`run()` stops when `quit()` is called **or when the last source removes
itself**. GLib would block forever in that second case; stopping instead keeps
a stray `run()` from hanging the machine, and it is documented here as a
deliberate difference.

### 2. `Gio.Application` (`stdlib/gio_compat.vala`)

`hold()`/`release()` are now a reference count:

- `run(args)` emits `activate`. If no `hold()` is active it returns `0`
  immediately (the previous behaviour, so existing tools are unaffected).
- With a hold, it creates a `MainLoop` and runs it; `release()` stops the loop
  when the count reaches zero. This is what keeps a window or a timer alive.

### 3. Demo (`user/mainloop_demo.vala`)

**17 checks**: default context identity, empty/pending states, distinct source
ids, idle runs once, three timeout ticks, idle before timeout, `quit()` stops
the loop, removed sources are gone, `source_remove` twice returns false, and
`Application.run()` drives the loop until `release()`.

The demo is part of the XFS image (16 files) and runs from the shell:

```
planet> mainloop_demo
mainloop:summary checks=17 failures=0
```

## Verification

```
== case compiler == PASS
== case directories == PASS
== case errors == PASS
== case exec == PASS
== case gio == PASS
== case mainloop == PASS
== case objects == PASS
7/7 cases passed
```

## Known limitations

- Single-threaded and no priorities: sources run in loop order, idle before
  timeouts; there is no `GSource` hierarchy or fd source yet.
- Resolution is one tick (10 ms); `timeout_add` with 0 is treated as 1 ms.
- No nested loops and no `MainContext.iteration(true)` blocking wait beyond one
  `SYS_YIELD` per call.
- `Application.run()` without `hold()` still returns immediately, by design.
- The XFS image now uses all 16 inodes of its first inode block; adding more
  files requires extending the image builder and checking the XFS inode
  addressing.
