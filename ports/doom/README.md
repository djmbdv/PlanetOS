# DOOM on PlanetOS

[doomgeneric](https://github.com/ozkl/doomgeneric) translated to Vala with
`c2vala` and compiled with `planc`. It boots on the stock PlanetOS image, loads
a WAD from XFS, renders with the software renderer and presents through
virtio-gpu.

```
[doom] init
[doom] D_DoomMain...
I_InitGraphics: framebuffer: RGBA: 8888, red_off: 16, green_off: 8, blue_off: 0
[doom] loop
[doom] frame 100 tic=130 free=232660
```

## Layout

| File | What it is |
| --- | --- |
| `upstream/` | doomgeneric sources (GPL-2.0, see `upstream/LICENSE`), unmodified |
| `doom_combined2.vala` | c2vala output for `upstream/*.c`, post-fixed (committed) |
| `doom_platform.vala` | hand-written backend: window, present, keys, zone stubs |
| `fix_doom_vala.py` | post-fixes applied to the generated Vala |
| `exclude.txt` | C files c2vala skips (other backends, sound, zone, wipes) |
| `build.ps1`, `build.sh` | regenerate (optional) + compile to `doom.elf` |

## Build

```powershell
.\run-qemu.ps1 -BuildOnly      # the SDK the port links against
.\ports\doom\build.ps1         # -> <msys64>\tmp\planetos-qemu\doom.elf
```

`build.ps1` compiles the committed Vala, so it does not need `c2vala`. Use
`-Regenerate` after changing `upstream/` or `fix_doom_vala.py`:

```powershell
.\ports\doom\build.ps1 -Regenerate   # needs tools\c2vala\build\c2vala.exe
```

## Run

`freedoom1.wad` is not in the repository (28 MB). Any Doom IWAD works; for the
free one:

```sh
curl -LO https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip
unzip freedoom-0.13.0.zip freedoom1.wad
```

Then add it to the image and let the launcher type the command:

```powershell
.\run-qemu.ps1 -Headless -Add doom.elf,freedoom1.wad `
    -Run 'doom.elf -iwad /freedoom1.wad' -RunSeconds 60
```

```sh
./run-qemu.sh --headless --add=doom.elf --add=freedoom1.wad \
    --run='doom.elf -iwad /freedoom1.wad' --run-seconds=60
```

Without `-Run`, boot normally, put the WAD in the image with `-Add`, and type
`doom.elf -iwad /freedoom1.wad` at the shell.

## How the port works

`doomgeneric` asks the backend for a frame buffer, a present call, a clock and
key events; `doom_platform.vala` provides those and stubs the rest:

* **Frames** — `DG_ScreenBuffer` (640x400 ARGB) is wrapped by Cairo's
  `ImageSurface.wrap`, so `DG_DrawFrame` only blits and presents. No copy.
* **Zone** — `Z_Malloc` returns a planc array; `Z_Free` is a no-op because the
  runtime frees by refcount, and `W_CacheLumpNum` caches each lump once.
* **Sound/music/joystick/wipes** — built with `-D PLANETOS_NOSOUND` and stubbed.
* **Keys** — `DG_GetKey` maps GDK keyvals to Doom key codes (arrows, use, fire,
  run, enter, escape).

## What `fix_doom_vala.py` covers

The translator emits valid Vala, but doomgeneric relies on C idioms that have
to be expressed differently. Each rule in the script has a comment; the ones
that matter for correctness:

* byte views of structs (`patch_t`, `post_t`) are `T.at (buf, off)` objects, so
  advancing through a picture is `(post_t *)((byte *)p + n)` re-based on the
  same buffer instead of a copy;
* `p = buffer + i + j` keeps the buffer plus an offset (`_off_p`), so drawing a
  patch no longer duplicates half a screen per call;
* `p->field[i]` on an inline array (`patch_t.columnofs`) uses the generated
  `field_at (i)` accessor: the property would materialise the whole lump;
* `ylookup[y]` becomes `int[] ylookup_off` so the renderer writes into
  `I_VideoBuffer` instead of a per-row copy;
* `R_GetColumn` returns the texture buffer and hands the offset back in
  `_off_rget`;
* a few constructs c2vala cannot express yet (a table of pointers to globals,
  `sha1sum` arrays, savegame-only initialisers) are rewritten locally.

## Performance notes

The port is built with `-O2`: the register allocator plus the bounds-check
elimination that planc now also runs at `-O1`. In a headless QEMU run of the
same wall-clock window this gives about **225 frames / 168 game tics** at `-O2`
against **150 frames / 147 tics** at `-O1`, i.e. the renderer keeps up with the
35 Hz game clock at `-O2` (~4 ms per frame) and drops frames at `-O1`. Before
packed 16-bit arrays and the `-O1` bounds-check work, `-O1` managed 75 frames per
35 s.

Element packing is what makes the buffers cheap: `uint8[]` is one byte per
element and `int16[]` two, so a 320x200 screen is 64 KB plus a 16-byte header and
DOOM's `int16` tables are a quarter of the 8-byte slot size. Both widths are
indexed directly by the register allocator (`movzx`/`movsx` loads and 8/16-bit
stores), and the bounds checks are hoisted out of the canonical `for` loops, so
the byte loops in the rasteriser no longer pay a check per pixel. What remains is
the software rasteriser itself and QEMU's TCG, which emulates every instruction.
Sound, music and wipes are not implemented, and the attract-mode demo takes a
long time to appear at these frame rates.
