# Slice 29: Linear Framebuffer (`BGA`), PS/2 Mouse (`IRQ12`), SSE, and Pure-Vala `Cairo` + `Gdk`

## Goal

Build the graphical foundation for PlanetOS: enable x86-64 SSE/SSE2 for `double`/`float`, add a Bochs/QEMU VBE (`800x600x32` ARGB) linear framebuffer driver and PS/2 mouse (`IRQ12`), and provide a 100% pure-Vala `Cairo` + `Gdk` compatibility layer (`stdlib/cairo_compat.vala` + `stdlib/gdk_compat.vala`) with zero C or `.vapi`.

## Changes

### 1. Kernel SSE, Bochs VBE Framebuffer, and PS/2 Mouse
- [`kernel/cpu.vala`](../../kernel/cpu.vala) & [`kernel/main.vala`](../../kernel/main.vala):
  - Added `cpu_enable_sse()` (`CR0.EM=0`, `CR0.MP=1`, `CR4.OSFXSR=1`, `CR4.OSXMMEXCPT=1`) so `float`/`double` SSE instructions work in kernel and userland.
- [`kernel/fb.vala`](../../kernel/fb.vala):
  - Scans PCI for Bochs/QEMU VGA (`0x1234`), maps `BAR0` (`8 MiB` via `PD3` at `0x103000`), programs `800x600x32` ARGB via BGA ports `0x01CE`/`0x01CF`, and blits userland backbuffers (`fb_copy_dwords`).
- [`kernel/mouse.vala`](../../kernel/mouse.vala):
  - Enables PS/2 auxiliary port (`IRQ12`, vector `44`), decodes 3-byte packets into clamped `(x, y, buttons)` state.
- [`kernel/syscall.vala`](../../kernel/syscall.vala):
  - Added `SYS_FB_INIT` (`21`), `SYS_FB_BLIT` (`22`), `SYS_FB_CLOSE` (`23`), and `SYS_MOUSE_READ` (`24`).

### 2. Pure-Vala `Cairo` + `Gdk` compatibility & GUI demo
- [`stdlib/cairo_compat.vala`](../../stdlib/cairo_compat.vala) and [`stdlib/gdk_compat.vala`](../../stdlib/gdk_compat.vala):
  - `Cairo.ImageSurface`, `Cairo.Context` (`set_source_rgb`/`rgba`, `paint`, `rectangle`, `arc`, `move_to`, `line_to`, `fill` with alpha blending, `stroke`, `show_text` with built-in 5×7 bitmap font).
  - `Gdk.RGBA`, `Gdk.cairo_set_source_rgba`, `Gdk.Display.open_window`, `Gdk.Window` (`present`, `poll_event`, `close`), `Gdk.Event`.
- [`user/cairo_demo.vala`](../../user/cairo_demo.vala):
  - Interactive graphical PlanetOS window with Cairo orbital rings, click counter, mouse cursor, and clean return to VGA text shell (`q` or `[X]`).
