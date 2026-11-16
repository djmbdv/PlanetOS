# Slice 40: shader uniforms, damage merging, occlusion culling, text attributes

## Goal

Finish the loop opened by slice 39: let a shader **animate** (uniforms), make
the damage list **cheap** (merge + occlusion culling) and give Pango **text
attributes** (colour runs), which is the piece the renderer needs before it can
highlight anything.

## Changes

### 1. Push constants in the SPIR-V backend (`planc/src/spirv.vala`)

Uniforms without descriptor sets: a single push-constant block, emitted lazily
only when the shader uses one (so `frag.spv` is still 676 bytes and its word
count is unchanged):

```
%block   = OpTypeStruct %f32 %f32 %f32 %f32
           OpMemberDecorate %block 0 Offset 0     (… 4, 8, 12)
           OpDecorate %block Block
%pc_ptr  = OpTypePointer PushConstant %block
%pc      = OpVariable %pc_ptr PushConstant
%ep      = OpTypePointer PushConstant %f32
%ptr     = OpAccessChain %ep %pc %idx
%val     = OpLoad %f32 %ptr
```

Shader built-ins (the dialect keeps its function-call style):

| Built-in | Member | Meaning |
|---|---|---|
| `uniform_time()` | 0 | seconds, supplied by the compositor |
| `uniform_width()` | 1 | viewport width |
| `uniform_height()` | 2 | viewport height |

The block is `{time, width, height, pad}` at offsets 0/4/8/12 (16 bytes, well
inside the 128-byte push-constant limit).

### 2. Evaluator (`stdlib/spirv_compat.vala`)

- The module is decoded **once** into an `int[]` word cache; per-pixel
  evaluation no longer does four byte loads per operand. This alone took an
  animated bake from ~1.1 s to ~0.2 s per frame.
- `OpAccessChain` (65) is tracked so `OpLoad` of a push-constant pointer
  returns `time/width/height` instead of a function-local value;
  `OpConstant` values are also kept as integers to resolve member indices.
- New API: `has_uniforms()`, `set_uniforms(time, width, height)`,
  `uniform_time_value()`.

### 3. Animated background (`user/frag_pattern.vala`, `user/compositor.vala`)

- `frag_pattern.vala` reads `uniform_time()` and sweeps the glow horizontally
  (`sweep = t * 60.0` pixels).
- `Compositor.bake_pattern(time)` fills the block cache with `set_uniforms()`
  and `animate_pattern(time)` re-bakes and marks the whole screen dirty.
- `--animate` enables a 400 ms animation tick (host supplies `ticks % 8 / 100`
  as a sawtooth) and switches the bake to `--pattern-step 16` (50×38 = 1900
  samples instead of 7500). `set_pattern_step(n)` clamps to 2..32.
- Measured in QEMU: without the optimisations the animated session managed
  **6 frames**; after the word cache and the coarser animated bake it runs at
  the usual 30 Hz (`frames=242`, `dirty=40`, `flush_ms=24`).
- Two `screendump`s 2 s apart differ in 774 sampled pixels of the top band,
  i.e. the glow really moves.

### 4. Damage merging + occlusion culling (`user/compositor.vala`)

- `damage()` now merges a new rectangle into an existing one when they overlap
  or are within 8 px, so the cursor, the clock hands and its digital readout
  collapse into one repaint instead of three.
- `covered(w)` skips a window whose frame (shadow included) lies completely
  inside a higher window; `occluded_count()` reports how many were skipped in
  the last `render()`.

### 5. Pango colour attributes (`stdlib/pango_compat.vala`)

- `Pango.ColorAttribute` + `Layout.add_color_attribute(start, end, r, g, b)`,
  `clear_attributes()`, `attribute_count()`, `has_attributes()` and
  `color_at(index)` (packed `0xRRGGBB` or `-1`).
- `PangoCairo.show_layout_at` draws glyph by glyph when the layout has
  attributes, switching the source colour only when the run changes; layouts
  without attributes keep the single-run fast path.
- The compositor's notes window is now one layout whose last line
  (`spir-v accent pipeline`) is an accent-coloured run.

## Verification

```
planet> pango_demo
pango:summary checks=44 failures=0
planet> compositor --self-test
compositor: pattern=frag_pattern.spv ok=1 samples=7500 uniforms=1
compositor:summary checks=73 failures=0
planet> compositor --animate --self-test
compositor: pattern=frag_pattern.spv ok=1 samples=1900 uniforms=1
compositor: animate=1 period_ms=400
compositor:summary checks=73 failures=0
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

New checks: `pattern-uniforms`, `pattern-animate-runs`, `pattern-animates-with-time`,
`animate-count`, `damage-merges`, `damage-merge-area`, `damage-keeps-distant`,
`merge-flush-clears`, `occlusion-skips-covered`, `occlusion-none-when-raised`
(compositor, 73 total) and `no-attributes`, `attribute-count`, `attribute-red`,
`attribute-blue`, `attribute-outside`, `attribute-draws-red`,
`attribute-draws-blue`, `attributes-cleared` (pango, 44 total).

The `graphics` case now runs the compositor three times (static, `--vulkan`,
`--animate`) so both bake paths stay covered.

## Known limitations

- Push constants are the only uniform mechanism: no descriptor sets, no
  textures, no storage buffers. `uniform_time` is fed from the host, so shaders
  still cannot read anything else about the scene.
- The animated path repaints the whole screen on every tick (a background
  covers everything); it is opt-in for that reason. Detail is coarser (16 px
  blocks) while animating.
- Damage rectangles only merge pairwise and greedily; there is no rectangle
  compaction into a minimal cover.
- Occlusion culling assumes windows are opaque and rectangular (true today);
  it does not consider partial overlaps or the cursor.
- Text attributes are colour runs only: no weight/style runs, underline,
  letter spacing or bidi; the renderer switches `set_source_rgb` per glyph.
