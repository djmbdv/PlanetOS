# Slice 38: Compositor (`compositor`, Openbox model + Gala visuals, SPIR-V accent)

## Goal

Give PlanetOS a real window manager of its own: an **Openbox-style interaction
model** (click to focus and raise, title-bar drag, maximize, close button, focus
cycling, dock buttons) with **Gala-inspired visuals** (soft drop shadows, accent
title bars, a top panel and a bottom dock), written in **100% Vala** and
painting the framebuffer directly. No Mutter, no X11, no Wayland.

The fragment pipeline is wired to the **SPIR-V** path: the compositor loads
`frag.spv`, evaluates it with the shared pure-Vala module evaluator and uses the
resulting RGBA as its accent color, so the same IR a Vulkan backend will upload
is already driving the UI.

## Changes

### 1. Shared SPIR-V runtime (`stdlib/spirv_compat.vala`)

`namespace Spv { public class Module }` moves the evaluator that used to live
inside `user/spv_demo.vala` into the stdlib:

- `Module.load(path) -> Module` (never `null`; check `valid` / `error`).
- Validates the header (`0x07230203` magic, `size % 4`, `bound`) and walks the
  module's SSA instructions: `OpConstant`, `OpFAdd`, `OpFSub`, `OpFMul`,
  `OpFDiv`, `OpCompositeConstruct` (vec4), `OpStore`, `OpLoad`.
- Exposes `words`, `insns`, `bound`, the fragment `r/g/b/a` and `ir()/ig()/ib()`.
- `Module.f32_bits_to_double` is the IEEE-754 decoder, now shared.

`user/spv_demo.vala` uses the module instead of its inline copy (~90 lines
removed) and prints the same `spv_demo: frag.spv words=… insns=… bound=…
rgb=(…)` line as before.

### 2. Compositor (`user/compositor.vala`)

Model (testable without a screen):

- `Wm.Win`: `id`, `title`, `kind` (`TERMINAL`/`CLOCK`/`SHADER`/`NOTES`), frame
  geometry, stack position `z`, `alive`, `maximized` + saved restore geometry,
  and hit tests (`contains`, `in_title`, `in_close`, `in_max`).
- `Wm.Compositor`: `add`, `find`, `nth`, `top_win`, `top_at`, `raise`, `focus`,
  `close_win`, `cycle`, `focus_nth`, `maximize`, `move_by` with clamping,
  `pointer_press/motion/release`, `drag_to`, `dock_index_at`, `key_press`.

Interaction (Openbox):

| Input | Action |
|---|---|
| click on content | focus + raise |
| click on title bar | focus + raise + start drag |
| drag | move window, clamped so 80 px stay on screen and the top bar is never covered |
| click on `□` | maximize / restore |
| click on `×` | close, focus falls back to the top window |
| click on dock button | focus + raise that window |
| `Tab` | cycle focus in stack order |
| arrows / `h` `j` `k` `l` | move the focused window 8 px |
| `1`..`9` | focus the n-th window |
| `m`, `c`, `n`, `q`/`Esc` | maximize, close, new window, quit |

Visuals (Gala):

- Vertical gradient desktop, accent glow line under the top bar.
- Right/bottom drop-shadow bands (blending only the visible band, not the whole
  window, which took the loop from ~9 fps to ~24 fps at 800×600).
- 1 px accent border and accent-tinted title bar on the focused window, muted
  colors otherwise; `□` and `×` glyphs drawn with line paths.
- Top panel: `PLANETOS`, focused title, window count, ticks.
- Bottom dock: one button per window, accent highlight + underline when focused.
- Per-kind content: terminal geometry readout, analog + digital clock driven by
  `Sys.ticks()`, SPIR-V module stats with the accent swatch, notes page.
- Software cursor drawn from the live `SYS_MOUSE_READ` position.

Frame loop: `GLib.MainLoop` + `timeout_add(33, …)`; each frame pumps up to 16
input events (`Gdk.poll_event`), finishes a drag when the button mask drops,
renders and calls `Gdk.Window.present()` (`SYS_FB_BLIT`).

### 3. Vulkan seam

`select_backend(BACKEND_VULKAN)` returns `false` today (decision D-13: no ICD),
prints `compositor: backend=vulkan ok=0 (no ICD yet, cairo fallback)` when
`--vulkan` is passed, and keeps the cairo path. The pieces a driver needs are
already isolated: the ARGB surface the compositor paints, the `Spv.Module` with
the fragment pipeline, and the per-frame window geometry the scene is rebuilt
from. `--self-test` asserts both the refusal and the cairo handover.

### 4. Gdk pointer queries (`stdlib/gdk_compat.vala`)

`Window.pointer_x()`, `pointer_y()` and `pointer_mask()` expose the
`SYS_MOUSE_READ` state directly (the drag loop needs the button mask, which
`poll_event()` only reports on the press edge).

### 5. Cairo `show_text_n` (`stdlib/cairo_compat.vala`)

`show_text(text)` now delegates to `show_text_n(text, max_chars)`, so widgets can
cut text to their width without building a temporary string (the compact
`StringBuilder` has no `to_string()`).

### 6. Frame buffer memory limit fix

Slice 35 capped `SYS_ALLOC_PAGE` at 256 pages in both `Planet.Sys.alloc_pages`
and `kernel/syscall.vala`. An 800×600 ARGB surface needs **469 pages**, so
`Cairo.ImageSurface` got `-1` back and every graphics demo would have written
through a bad address. The cap is now **1024 pages (4 MiB)**, still bounded and
enough for the framebuffer; the `graphics` case covers this by running
`cairo_demo`, `spv_demo` and the compositor render smoke test.

### 7. Extended keyboard keys (`kernel/keyboard.vala`)

The Set-1 driver ignored the `0xE0` prefix, so arrow keys produced nothing. It
now tracks the prefix and reports `0x81` up, `0x82` down, `0x83` left, `0x84`
right, `0x85` home, `0x86` end; the compositor uses those (and `h/j/k/l`) to move
windows.

### 8. Image and harness

- `compositor.elf` is the **17th** file in the XFS image. Inode 16016 lands in
  block 1001 (`inopblog=4`), which the kernel already addresses, and the
  shortform root directory payload grows to ~323 of 512 bytes.
- New `graphics` case: `cairo_demo --once`, `spv_demo --once`,
  `compositor --self-test`, `compositor --vulkan --self-test`.

## Verification

```
planet> cairo_demo --once
cairo_demo: done
planet> spv_demo --once
spv_demo: frag.spv words=156 insns=41 bound=30 rgb=(56,188,247)
planet> compositor --self-test
compositor: shader=frag.spv ok=1 rgba=56,188,247
compositor:summary checks=43 failures=0
planet> compositor --vulkan --self-test
compositor: backend=vulkan ok=0 (no ICD yet, cairo fallback)
compositor:summary checks=43 failures=0
```

Interactive smoke test (headless QEMU, `compositor` then `q`):

```
planet> compositor
compositor: shader=frag.spv ok=1 rgba=56,188,247
compositor: keys: tab cycle  drag=move  m max  c close  n new  1-9 focus  q quit
compositor: frames=147 windows=3
```

```
== case compiler == PASS
== case directories == PASS
== case errors == PASS
== case exec == PASS
== case gio == PASS
== case graphics == PASS
== case mainloop == PASS
== case objects == PASS
8/8 cases passed
```

The 43 self-test checks cover: sequential ids, count, top-most and focus
ordering, hit testing on overlaps and empty desktop, click-to-focus/raise,
title-bar drag, drag clamping (left and top), release, close button, focus
fallback after close, maximize/restore, keyboard and arrow moves, Tab cycling
and wrap-around, dock hit testing and focus, `c` closing the focused window, a
full render into a 800×600 surface, SPIR-V module validity/word count/accent
range, the Vulkan refusal + cairo handover, and `Esc` quitting.

## Known limitations

- Software rendering only: a full repaint costs ~40 ms at 800×600 in QEMU, so
  the loop runs at ~24 fps. No damage tracking (every frame repaints the whole
  screen), no compositing of client surfaces (windows are drawn by the compositor
  itself), no X11/Wayland clients.
- No Vulkan ICD: `BACKEND_VULKAN` is a seam, not an implementation; `frag.spv` is
  evaluated on the CPU and only its fragment color is consumed. A per-pixel
  pipeline needs a shader with inputs (`gl_FragCoord`/uniforms), which `planc`
  does not emit yet.
- No modifier keys (Alt+Super) and no window resize handles; `planc` has no
  `uint`, so the model uses `int` for all geometry.
- One workspace, no window rules, no snap-to-edge, no alt-tab overlay (Tab
  cycles immediately).
- The XFS image now spans **two** inode blocks (17 files); the next additions
  must keep `INO_BLK + 2` blocks reserved.
