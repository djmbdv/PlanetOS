# Slice 49: VirGL 3D resources, and the SVG cursor in the compositor

Two pieces of the desktop that were still missing after slice 48: a GPU
resource path that works without blobs, and a cursor that is the actual
`cursor.svg` asset instead of a hand-drawn arrow.

## 1. `RESOURCE_CREATE_3D`

`RESOURCE_BLOB` is the Venus path, but it is not available on every host (the
QEMU build in slice 48 advertises it and then rejects the command). VirGL has
a second, older way to back a GPU object with guest pages:
`RESOURCE_CREATE_3D` + `RESOURCE_ATTACH_BACKING`. It is enough for a 2D
texture used as a render target and works on any virglrenderer.

`kernel/virtio_gpu.vala` now implements `create_3d_mapped (ctx, res, w, h)`:

- `RESOURCE_CREATE_3D` (`0x0204`) with `PIPE_TEXTURE_2D`, B8G8R8A8,
  `VIRGL_BIND_RENDER_TARGET`, `depth = array_size = 1`.
- `RESOURCE_ATTACH_BACKING` with one memory entry for the allocated frames.
- `CTX_ATTACH_RESOURCE`, then the same checked mapping into the caller's CR3
  that blobs use.
- The resource is recorded in the per-task ownership table as `GPU_RES_3D`.

`resource_destroy` (the slice-48 `blob_destroy`, renamed) releases blobs and
3D resources through the same path: detach, unref, unmap, free. The syscall
surface is:

| Syscall | Number | Arguments |
|---|---|---|
| `SYS_GPU_RESOURCE_DESTROY` | 46 | `ctx_id, res_id, pa, size` |
| `SYS_GPU_3D_CREATE` | 47 | `ctx_id, res_id, width, height` -> `pa` or `0` |

`Venus.ProbeResult` now creates a 16x16 3D texture after the NOP submission
and destroys it before the blob attempt. `gpu probe` reports both:

```
gpu: probe ctx=1 submit=1 res3d=1 blob=0 venus=0 cleanup=1
```

### 1.1 The PMM bug the probe found

The first 3D run faulted inside `poison_page_4k` at the frame address
(`cr2=0x63b000`, `err=2`). The sequence was `resource_destroy`: unmap the
resource from the current user CR3, then `Pmm.free_frame`, whose poison write
went through that same CR3 and hit the page that had just been unmapped.

`Pmm` now performs frame zeroing and poisoning under the kernel identity map:

- `alloc_frame`/`free_frame` enter the kernel CR3 around the scratch write;
- `alloc_contiguous` does it once for the whole run.

The kernel CR3 maps the low 1 GiB and is never unmapped, so the scratch write
always has a valid translation. This also fixes the latent version of the
same bug in `SYS_ALLOC_PAGE` when a checked mapping fails after splitting a
2 MiB page.

## 2. The SVG cursor

`cursor.svg` is a 30x30 path (`M/A/L/C/Z`) that was sitting untracked in the
repository. It is now part of the image and the compositor renders it.

### 2.1 `Gsk.Path`

`stdlib/gsk_path.vala` adds the GTK4-style entry point `Gsk.Path.parse (d)`:
the SVG path grammar (`M/L/H/V/C/S/Q/T/A/Z`, absolute and relative), flattening
of cubics and quadratics, and contour tracking. It deliberately has no XML or
SVG library behind it and no libm: the dialect has no `sin`/`cos`/`atan2`, so
arcs are flattened with a quadratic bulge computed from the chord and radius
(`sqrt` is a Newton loop). Small radii, such as the cursor's 1px corners, are
exact enough; a `large-arc` segment falls back to the chord and says so in the
file header.

`Gsk.Path.fill (Cairo.Context)` and `fill_translated` drive the rasterizer.

### 2.2 Cairo polygon fill

`stdlib/cairo_compat.vala` only knew rectangles, circles and rounded
rectangles. `Context.fill_polygon_range` adds a closed-polygon scanline fill
with 4x4 supersampling (`blend_px`), and `draw_rgba` blits a BGRA buffer with
clipping and alpha. `clear` gives a deterministic transparent surface.

### 2.3 Compositor

At construction the compositor reads `cursor.svg`, extracts the `d` attribute,
rasters it into a 64x64 BGRA image (dark drop shadow at +1.2px, white body),
and keeps it in `cursor_pix`. The hotspot comes from the path start (`9,3`),
which is the arrow tip.

- Software cursor: `draw_cursor` blits the image with `draw_rgba`.
- Hardware cursor: `init_hw_cursor` passes the same image and hotspot to
  `SYS_GPU_CURSOR_SET`; the interactive session now calls
  `attach (win, true)`, so a VirtIO-GPU takes the cursor over and the software
  path remains the fallback when the cursor queue refuses it.
- If the file is missing or the path does not parse, the old hand-drawn
  12x18 arrow is used, so a build without the asset still has a pointer.

The self-test reports and checks the asset:

```
compositor: cursor_svg=1 hotspot=9x3
compositor:summary checks=78 failures=0
```

and samples the raster (`cursor_alpha (9,5) > 128`, `cursor_alpha (0,0) == 0`).

## 3. Verification

- `python tests/qemu.py --no-build`: 16/16; `graphics` covers the three
  compositor self-tests and the new cursor checks.
- QEMU GL (`-display egl-headless -device virtio-gpu-gl-pci,blob=on`):

```
virtio_gpu:found=1 w=1280 h=800 virgl=1 blob=1 ctx=1 venus=0
gpu: probe ctx=1 submit=1 res3d=1 blob=0 venus=0 cleanup=1
gpu: probe ctx=1 submit=1 res3d=1 blob=0 venus=0 cleanup=1
```

Two probes in one boot prove the 3D resource was unref'd and its frames
returned: the second create reuses the same resource id and context.

## 4. What is still open

1. HOST3D blobs and `RESOURCE_MAP_BLOB`; the host still refuses GUEST blobs
   with `0x1205` before the handler trace (slice 48 §5).
2. Draw into the 3D texture from `planc --target=spirv` output: the resource
   now exists, the pipeline needs the Venus command ring.
3. Arc flattening for large angles (the cursor only needs small corners).
4. GTK4: `Gsk.Path` is the parser a `GskPath`-based renderer expects; the
   cursor image is a plain texture, so a future `GdkTexture`/`GskRenderer`
   port has no SVG-side work left.
