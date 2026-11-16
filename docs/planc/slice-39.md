# Slice 39: Pango layer, damage tracking, keyboard modifiers, per-pixel SPIR-V

## Goal

Make the graphics stack usable rather than demo-grade: real text layout
(Pango), a compositor that only repaints what changed (damage tracking),
modifier keys with window-manager bindings (Alt+Tab, Super+arrows) and a
fragment shader that actually runs per pixel (`gl_FragCoord`).

## Changes

### 1. Pango + PangoCairo (`stdlib/pango_compat.vala`)

A text layout layer on top of the compact 5x7 bitmap font that Cairo paints,
with exact metrics for that font instead of outline shaping:

| Type | API |
|---|---|
| `Pango.FontDescription` | `family`, `size` (px), `weight`, `style`, `copy()`, `from_string("mono 24 italic")`, `describe()` |
| `Pango.PangoContext` | `font_description`, `glyph_scale(px)` |
| `Pango.Layout` | `set_text`, `set_font_description`, `set_width`, `set_ellipsize`, `set_alignment`, `set_spacing`, `pixel_width()`, `pixel_height()`, `line_count()`, `line_start_of/length_of/chars_of`, `line_truncated()`, `alignment_offset()`, `scale()`, `char_width()`, `line_height()` |
| `PangoCairo` | `show_layout_at(cr, layout, x, y)`, `show_layout(cr, layout)` |

Behaviour:

- Advance is `6 * scale` and line height `7 * scale`, where `scale` is
  `size / 8` clamped to 1..4 — exactly what `Cairo.Context.set_font_size`
  selects, so measurements and rendering agree.
- Word wrapping at the last space, hard break for a word that does not fit,
  `\n` handling (including a trailing newline producing an empty last line).
- `EllipsizeMode.END` keeps one line, reserves two character cells for `..`
  and reports `line_truncated()`; the renderer draws the ellipsis.
- Alignment offsets are computed against the widest line (`pixel_width()`).
- The class is named `PangoContext` (the C type name) because `planc` resolves
  type names per file and a `Pango.Context` would collide with `Cairo.Context`
  under `using Cairo;`.
- Only `sans`, `mono` and `serif` are recognized families; the bitmap font has
  no families, and the field is kept for API compatibility.

`user/pango_demo.vala` covers it with **36 checks** (metrics, empty text,
newlines, word wrap, hard break, ellipsize, alignment, font parsing, spacing,
drawing into a surface and `clip()`).

### 2. Cairo additions (`stdlib/cairo_compat.vala`)

- `clip()` intersects the current rectangle path with the drawing area;
  `reset_clip()`, `has_clip()`, `clip_left/top/right/bottom()`.
- `put_px`, `fill()` and `paint()` all honour the clip (fast paths included).
- `show_text_range(text, start, count)` draws a slice of a string;
  `show_text_n` and `show_text` are thin wrappers.
- `current_x()/current_y()` and `pixel_at(x, y)` (read-back for tests).

### 3. Damage tracking (`user/compositor.vala`)

- `damage(x, y, w, h)` records up to 32 clamped rectangles; overflow promotes
  the whole frame to `damage_full()`; `flush(cr, mx, my)` repaints each rect
  with `clip()` and clears the list.
- Every model mutation marks damage: `add`, `raise`, `focus`, `close_win`,
  `maximize`, `snap`, `restore_layout`, `move_by` and `drag_to` (old + new
  rect for moves).
- Per-frame animation damage is second-granular: the analog clock face and the
  `T+mm:ss` readout are only dirtied when `Sys.ticks()/100` changes, and the
  cursor only when it moves.
- Culling (`rect_hits`) skips windows, panels, content blocks and the clock
  face when they do not touch the current clip, so one damage rect costs only
  that rect.
- `Gdk.Window.present_rect()` blits only a dirty rectangle through
  `SYS_FB_BLIT_RECT` (26); a full `present()` happens only on `damage_full`.

Measured in QEMU (8 s interactive session, three windows):

```
compositor: frames=179 windows=3 dirty=8 flush_ms=20 blit_ms=2
```

i.e. **8 of 179 frames painted anything at all** (one per second, for the
clock), and the loop keeps its 30 Hz `timeout_add(33)` cadence. Before damage
tracking every frame repainted the full 800×600 surface (~24 fps ceiling with
~40 ms of work per frame).

### 4. Keyboard modifiers (`kernel/keyboard.vala`, syscall 33)

The Set-1 decoder now tracks Ctrl (`0x1D`), Alt (`0x38`), Super (`0xE0 0x5B`)
and exposes them through `SYS_KEY_MODS` (**33**), so userland keeps plain ASCII
key values:

- `Planet.Sys.key_mods()`, `MOD_SHIFT/CTRL/ALT/SUPER`, `mod_alt()`,
  `mod_super()`, `mod_ctrl()`.
- `Compositor.key_press_mod(key, mods)`: **Alt+Tab** cycles focus,
  **Alt+Q** closes the focused window, **Super+←/→** tiles to half the work
  area, **Super+↑** maximizes, **Super+↓** restores. Windows carry a
  `layout_state` (`LAYOUT_NORMAL/MAX/LEFT/RIGHT`) so tiling, maximizing and
  restoring share one restore geometry.
- `Gdk.Window` caches the pointer state (one `SYS_MOUSE_READ` per poll) and
  exposes `pointer_x/y/mask()` plus `read_pointer()`.

### 5. Per-pixel SPIR-V (`planc/src/spirv.vala`, `stdlib/spirv_compat.vala`)

The fragment backend now declares a real input:

- `OpVariable` with storage class `Input` (`OpTypePointer` 1) and
  `OpDecorate %in BuiltIn FragCoord` (decoration 11, built-in 15), added to the
  `OpEntryPoint` interface list (its word count grew from `4 + strlen` to
  `5 + strlen`).
- New shader built-ins `frag_coord_x()/y()/z()/w()`: `OpLoad` of the input plus
  `OpCompositeExtract` (81), so the value is a normal `float` in shader code.

The CPU evaluator (`Spv.Module`) gained `OpVariable` (input detection),
`OpCompositeExtract`, `has_input()` and `pixel(x, y)`, which re-walks the
module with `gl_FragCoord = (x + 0.5, y + 0.5, 0, 1)`. Scratch arrays are
allocated once per module, so per-pixel evaluation does not allocate.

`user/frag_pattern.vala` is the first per-pixel shader (horizon gradient +
radial glow); the compositor bakes it into 8×8 blocks (`PAT_STEP`) —
100×75 = 7500 samples — and paints the desktop from that cache, with
`--pattern FILE` to load another module and `--no-pattern` for the CPU
gradient. `frag.spv` (constant color) is unchanged and still feeds the accent.

### 6. Build plumbing

- `tools/build-planc-host.sh` rebuilds the stage-0 compiler with the MSYS2
  UCRT64 `valac` (the repo's `planc/build.sh` needs the Vala oracle, which is
  only installed on Linux). Needed whenever the compiler sources change.
- The XFS image grows to **19 files** (`pango_demo.elf`,
  `frag_pattern.spv`, all inside the second inode block).
- New `pango` case and an extended `graphics` case (62 compositor checks).

## Verification

```
planet> pango_demo
pango:summary checks=36 failures=0
planet> compositor --self-test
compositor: shader=frag.spv ok=1 rgba=56,188,247
compositor: pattern=frag_pattern.spv ok=1 samples=7500
compositor:summary checks=62 failures=0
planet> compositor --vulkan --self-test
compositor: backend=vulkan ok=0 (no ICD yet, cairo fallback)
compositor:summary checks=62 failures=0
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
== case pango == PASS
9/9 cases passed
```

The new compositor checks cover: baked pattern sample count, per-pixel
variation, `add-damages-all`, `flush-clears-damage`, damage accounting
(`1600` px), that a clipped flush repaints inside its rect and leaves pixels
outside untouched (read back with `pixel_at`), Alt+Tab, Alt+Q, and
Super+←/→/↑/↓ tiling geometry and restore.

## Known limitations

- Pango is a single-font layout engine: no text runs, attributes, bidi,
  shaping, or font fallback; `weight`/`style` are recorded but the bitmap font
  has one face.
- Damage rectangles are not merged; 32 entries then a full repaint. No
  occlusion culling against higher windows (a rect always repaints the whole
  stack inside it).
- The `flush_ms` figure is measured with the 10 ms `Sys.ticks()` granularity.
- Modifiers are polled (`SYS_KEY_MODS`) rather than delivered with each key, so
  a key and its modifier can race by one frame; there is no modifier-repeat or
  keyboard-layout support.
- SPIR-V inputs are limited to the FragCoord built-in: no uniforms, descriptor
  sets or push constants, so shaders cannot animate or sample textures. The
  evaluator handles constant arithmetic and `vec4` construction/extraction only.
- No Vulkan ICD (D-13): `frag_pattern.spv` is evaluated on the CPU and baked.
