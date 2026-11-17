# Slice 44 — TrueType Fonts (`libschrift`), Modular GTK Layer, and ATA/XFS Disk & Input Hardening

## Summary
- **TrueType font rasterizer (`stdlib/schrift.vala`)**: Pure-Vala (`planc`) port of `libschrift` supporting `.ttf` table parsing (`head`, `hhea`, `loca`, `glyf`, `hmtx`, `cmap` 4/6/12, `kern`), simple/compound outlines, adaptive quadratic Bézier tessellation, and 8-bit subpixel-coverage scanline rasterization (`assets/Ubuntu-Regular.ttf`).
- **2D Graphics & Font Fixes (`stdlib/cairo_compat.vala`, `stdlib/gdk_compat.vala`)**:
  - Fixed mirrored `'7'` bitmap glyph in `Cairo.Context.glyph_row`.
  - Added `save ()` / `restore ()`, `rounded_rectangle ()` (`fill`/`stroke`), `fill_gradient_v ()`, and `blit_alpha_mask ()`.
  - Added `EventType.BUTTON_RELEASE` emission in `Gdk.Window.poll_event ()`.
- **Modular GTK Compatibility Layer (`stdlib/gtk/`)**:
  - `stdlib/gtk/text.vala`: `TextHelper` with a 512-entry `GlyphEntry` cache so TrueType glyphs are rasterized once.
  - `stdlib/gtk/widget.vala`: `Orientation` and base `Widget` class.
  - `stdlib/gtk/widgets.vala`: `Label`, `Button` (`clicked` signal), `Entry` (`changed`/`activate` signals, keyboard input).
  - `stdlib/gtk/container.vala`: `Box` layout container (`HORIZONTAL`/`VERTICAL`).
  - `stdlib/gtk/window.vala`: `GtkWindow` over `Gdk.Display.open_window` and `poll_event ()`.
  - Integrated `Kind.GTK` into `user/compositor.vala` (including `BUTTON_RELEASE` / `MOTION_NOTIFY` / `KEY_PRESS` routing and `draw_cursor` clamping at `[0, SCREEN_W - 1]` / `[0, SCREEN_H - 1]`) and added `user/gtk_demo.vala`.
- **Disk Controller & XFS (`kernel/ata.vala`, `kernel/xfs.vala`, `kernel/mouse.vala`, `tools/mkdisk.py`, `run-qemu.sh`, `run-qemu.ps1`)**:
  - `Ata.init ()`, `Ata.reset ()`, `Ata.total_sectors ()`, `Ata.has_lba48 ()`, `Ata.flush_cache ()`, and multi-sector `read_sectors` / `write_sectors` (LBA28 + LBA48).
  - `Xfs.load_inode` reads 4 sectors so root directories with >22 files list cleanly.
  - `Mouse.poll_state` discards PS/2 packets with X/Y overflow bits (`0xC0`).
  - Enabled `-O2` in `run-qemu.sh` and `run-qemu.ps1` and bundled `gtk_demo.elf` + `Ubuntu-Regular.ttf` in `mkdisk.py`.

## Verification
- `bash run-qemu.sh --build-only` + QEMU: `gtk_demo.elf --once` (`gtk_demo: ttf=1`, `gtk_demo: done`, `exec: exit=0`) and `compositor.elf --self-test` (`compositor:summary checks=74 failures=0`).
- `PLANC=./planc/build/planc bash planc/tests/run.sh`: `SUMMARY: 184 cases, 184 pass, 0 fail`.
