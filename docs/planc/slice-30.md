# Slice 30: Hardware Double-Buffered Display Driver (`kernel/fb.vala`) & `--target=spirv` Shader Backend (`planc/src/spirv.vala`)

## Goal

Upgrade the display driver to support hardware double-buffering (page flipping), 16 MiB VRAM mapping, mode queries, and dirty-rectangle blits, and implement the deterministic Vala-to-SPIR-V 1.0 shader compiler backend (`--target=spirv`, **GX-01**, **GX-02**, **GX-04**).

## Changes

### 1. Upgraded display driver (`kernel/fb.vala`, `kernel/syscall.vala`)
- [`kernel/fb.vala`](../../kernel/fb.vala):
  - Maps 16 MiB of VRAM via `PD3` (`0x103000`), supporting `800x600`, `1024x768`, and `1280x720` @ 32bpp ARGB.
  - Configures Bochs VBE virtual height (`2 * h`) and flips between pages via `VBE_DISPI_INDEX_Y_OFFSET` (`9`) for tear-free double-buffered rendering.
  - Added `Fb.info()` and `Fb.blit_rect()` for partial dirty-rectangle updates.
- [`kernel/syscall.vala`](../../kernel/syscall.vala):
  - Added `SYS_FB_INFO` (`25`) and `SYS_FB_BLIT_RECT` (`26`).

### 2. `--target=spirv` Vala shader compiler (`planc/src/spirv.vala`)
- [`planc/src/spirv.vala`](../../planc/src/spirv.vala), [`planc/src/main.vala`](../../planc/src/main.vala), [`planc/build.sh`](../../planc/build.sh), [`planc/bootstrap.sh`](../../planc/bootstrap.sh):
  - Emits deterministic **SPIR-V 1.0** fragment shader modules (`0x07230203`, `OpCapability Shader`, `OpMemoryModel Logical GLSL450`, `OpEntryPoint Fragment %main "main"`, `Location 0` `vec4` output, `float`/`int` constants & arithmetic, `vec4`/`frag_color`).
  - Enforces shader dialect restrictions (**GX-04**), rejecting `classes`, `strings`, `print()`, and host-only constructs.
- [`planc/tests/run.sh`](../../planc/tests/run.sh):
  - Added `spirv_shader` verifying deterministic `.spv` output, SPIR-V 1.0 header invariants, and `GX-04` rejection.
