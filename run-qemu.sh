#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PLANC="$ROOT/planc/build/planc"
# valac names the stage-0 binary planc.exe when built on Windows/MSYS2.
if [ ! -x "$PLANC" ] && [ -x "$PLANC.exe" ]; then
    PLANC="$PLANC.exe"
fi
OUT="/tmp/planetos-qemu"
mkdir -p "$OUT"

BUILD_ONLY=0
DISPLAY_MODE="window"
GPU_MODE="std"
for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=1 ;;
        --headless)   DISPLAY_MODE="none" ;;
        --display)    DISPLAY_MODE="gtk" ;;
        --virtio)     GPU_MODE="virtio" ;;
        --virtio-gl)  GPU_MODE="virtio-gl" ;;
    esac
done

if [ ! -x "$PLANC" ]; then
    "$ROOT/planc/build.sh"
    if [ ! -x "$PLANC" ] && [ -x "$PLANC.exe" ]; then
        PLANC="$PLANC.exe"
    fi
fi

echo "Building PlanetOS kernel and userland..."
OPT="${PLANC_OPT:--O2}"
"$PLANC" $OPT --target=planetos "$ROOT/user/init.vala" -o "$OUT/init.elf"
"$PLANC" --target=planetos --image-base=0x900000 "$ROOT/stdlib/planet_sys.vala" "$ROOT/user/worker.vala" -o "$OUT/worker.elf"
"$PLANC" --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/user/banner.vala" -o "$OUT/banner.elf"
"$PLANC" --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/glib_compat.vala" "$ROOT/user/wc.vala" -o "$OUT/wc.elf"
"$PLANC" --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/glib_compat.vala" "$ROOT/stdlib/gio_compat.vala" "$ROOT/user/gio_demo.vala" -o "$OUT/gio_demo.elf"
"$PLANC" --target=planetos "$ROOT/stdlib/gobject_compat.vala" "$ROOT/user/gobject_demo.vala" -o "$OUT/gobject_demo.elf"
"$PLANC" --target=planetos "$ROOT/stdlib/gmodule_compat.vala" "$ROOT/user/gmodule_demo.vala" -o "$OUT/gmodule_demo.elf"
"$PLANC" --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/glib_compat.vala" "$ROOT/stdlib/gio_compat.vala" "$ROOT/user/mainloop_demo.vala" -o "$OUT/mainloop_demo.elf"
"$PLANC" --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/cairo_compat.vala" "$ROOT/stdlib/gdk_compat.vala" "$ROOT/user/cairo_demo.vala" -o "$OUT/cairo_demo.elf"
"$PLANC" --target=spirv "$ROOT/user/frag_planet.vala" -o "$OUT/frag.spv"
"$PLANC" --target=spirv "$ROOT/user/frag_pattern.vala" -o "$OUT/frag_pattern.spv"
"$PLANC" --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/spirv_compat.vala" "$ROOT/stdlib/cairo_compat.vala" "$ROOT/stdlib/gdk_compat.vala" "$ROOT/user/spv_demo.vala" -o "$OUT/spv_demo.elf"
"$PLANC" $OPT --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/spirv_compat.vala" "$ROOT/stdlib/venus_compat.vala" "$ROOT/stdlib/cairo_compat.vala" "$ROOT/stdlib/gdk_compat.vala" "$ROOT/stdlib/gsk_compat.vala" "$ROOT/user/vk_demo.vala" -o "$OUT/vk_demo.elf"
"$PLANC" $OPT --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/glib_compat.vala" "$ROOT/stdlib/pango_compat.vala" "$ROOT/stdlib/spirv_compat.vala" "$ROOT/stdlib/cairo_compat.vala" "$ROOT/stdlib/gdk_compat.vala" "$ROOT/stdlib/schrift.vala" "$ROOT/stdlib/gtk/text.vala" "$ROOT/stdlib/gtk/widget.vala" "$ROOT/stdlib/gtk/widgets.vala" "$ROOT/stdlib/gtk/container.vala" "$ROOT/stdlib/gtk/window.vala" "$ROOT/user/compositor.vala" -o "$OUT/compositor.elf"
"$PLANC" $OPT --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/cairo_compat.vala" "$ROOT/stdlib/pango_compat.vala" "$ROOT/user/pango_demo.vala" -o "$OUT/pango_demo.elf"
"$PLANC" $OPT --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/cairo_compat.vala" "$ROOT/stdlib/gdk_compat.vala" "$ROOT/stdlib/schrift.vala" "$ROOT/stdlib/gtk/text.vala" "$ROOT/stdlib/gtk/widget.vala" "$ROOT/stdlib/gtk/widgets.vala" "$ROOT/stdlib/gtk/container.vala" "$ROOT/stdlib/gtk/window.vala" "$ROOT/user/gtk_demo.vala" -o "$OUT/gtk_demo.elf"
"$PLANC" --target=planetos "$ROOT/user/jsmn_demo.vala" "$ROOT/tools/c2vala_rt.vala" -o "$OUT/jsmn_demo.elf"
"$PLANC" --target=planetos "$ROOT/planc/src/buffer.vala" "$ROOT/planc/src/host_planetos.vala" "$ROOT/stdlib/planet_sys.vala" \
    "$ROOT/tools/c2vala/ast.vala" "$ROOT/tools/c2vala/preproc.vala" "$ROOT/tools/c2vala/lexer.vala" \
    "$ROOT/tools/c2vala/parser.vala" "$ROOT/tools/c2vala/translator.vala" "$ROOT/tools/c2vala/main.vala" -o "$OUT/c2vala.elf"
"$PLANC" --target=planetos --image-base=0xA00000 "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/glib_compat.vala" "$ROOT/user/shell.vala" -o "$OUT/shell.elf"
"$PLANC" $OPT --target=planetos --image-base=0xC00000 \
    "$ROOT/stdlib/planet_sys.vala" \
    "$ROOT/planc/src/buffer.vala" \
    "$ROOT/planc/src/host_planetos.vala" \
    "$ROOT/planc/src/ast.vala" \
    "$ROOT/planc/src/lexer.vala" \
    "$ROOT/planc/src/parser.vala" \
    "$ROOT/planc/src/asm.vala" \
    "$ROOT/planc/src/emitter.vala" \
    "$ROOT/planc/src/elf.vala" \
    "$ROOT/planc/src/dwarf.vala" \
    "$ROOT/planc/src/spirv.vala" \
    "$ROOT/planc/src/opt.vala" \
    "$ROOT/planc/src/codegen.vala" \
    "$ROOT/planc/src/main.vala" \
    -o "$OUT/planc.elf"

"$PLANC" $OPT --freestanding \
    "$ROOT/planetrt/boot_mb2.vala" \
    "$ROOT/planetrt/serial.vala" \
    "$ROOT/kernel/cpu.vala" \
    "$ROOT/kernel/vga.vala" \
    "$ROOT/kernel/fb.vala" \
    "$ROOT/kernel/pmm.vala" \
    "$ROOT/kernel/vmm.vala" \
    "$ROOT/kernel/virtio_gpu.vala" \
    "$ROOT/kernel/env.vala" \
    "$ROOT/kernel/ramfs.vala" \
    "$ROOT/kernel/keyboard.vala" \
    "$ROOT/kernel/rtc.vala" \
    "$ROOT/kernel/mouse.vala" \
    "$ROOT/kernel/ata.vala" \
    "$ROOT/kernel/xfs.vala" \
    "$ROOT/kernel/vfs.vala" \
    "$ROOT/kernel/syscall.vala" \
    "$ROOT/kernel/elf_loader.vala" \
    "$ROOT/kernel/sched.vala" \
    "$ROOT/kernel/main.vala" \
    -o "$OUT/planet-kernel"

python3 "$ROOT/tools/mkdisk.py" "$OUT/disk.img" \
    "$OUT/init.elf" "$OUT/shell.elf" "$OUT/planc.elf" "$OUT/banner.elf" \
    "$OUT/worker.elf" "$OUT/wc.elf" "$OUT/cairo_demo.elf" "$OUT/frag.spv" \
    "$OUT/spv_demo.elf" "$OUT/gio_demo.elf" \
    "$ROOT/planc/tests/valid/utf8.vala" "$ROOT/planc/tests/valid/class_basic.vala" \
    "$OUT/gobject_demo.elf" "$OUT/gmodule_demo.elf" "$OUT/mainloop_demo.elf" "$OUT/compositor.elf" "$OUT/pango_demo.elf" "$OUT/jsmn_demo.elf" "$OUT/c2vala.elf" "$ROOT/tools/c2vala_tests/cases/arith/main.c" "$OUT/frag_pattern.spv" "$OUT/gtk_demo.elf" "$OUT/vk_demo.elf" "$ROOT/assets/Ubuntu-Regular.ttf"

# --headless forces the serial-only mode; --display forces a window. Without a
# flag: window when a display server exists, headless otherwise. Windows/MSYS2
# always has one even though $DISPLAY is unset.
if [ "$BUILD_ONLY" = "1" ]; then
    echo "PLANETOS_OUT=$OUT"
    echo "PLANETOS_QEMU=qemu-system-x86_64"
    echo "Build complete (build-only)."
    exit 0
fi

if [ "$DISPLAY_MODE" = "window" ] \
    && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${MSYSTEM:-}" ]; then
    DISPLAY_MODE="none"
fi
GPU_ARGS=(-vga std)
if [ "$GPU_MODE" = "virtio" ]; then
    GPU_ARGS=(-vga none -device virtio-gpu-pci)
elif [ "$GPU_MODE" = "virtio-gl" ]; then
    GPU_ARGS=(-vga none -device virtio-gpu-gl-pci,blob=on,hostmem=256M)
fi
DISP_ARGS=()
SER_ARGS=()
if [ "$DISPLAY_MODE" = "none" ]; then
    if [ "$GPU_MODE" = "virtio-gl" ]; then
        DISP_ARGS=(-display egl-headless)
    else
        DISP_ARGS=(-display none)
    fi
    SER_ARGS=(-serial mon:stdio)
else
    if [ "$GPU_MODE" = "virtio-gl" ]; then
        DISP_ARGS=(-display gtk,gl=on,grab-on-hover=on)
    elif [ "$GPU_MODE" = "virtio" ] || [ "$DISPLAY_MODE" = "gtk" ]; then
        DISP_ARGS=(-display gtk,grab-on-hover=on)
    fi
    # Keep the serial console out of the terminal: QEMU's stdio backend is
    # unreliable under mintty, and the guest already draws to the VGA window.
    SER_LOG="$OUT/serial.log"
    if command -v cygpath >/dev/null 2>&1; then
        SER_LOG="$(cygpath -m "$SER_LOG")"
    fi
    SER_ARGS=(-serial "file:$SER_LOG")
    echo "Serial log: $SER_LOG"
fi

echo "Booting PlanetOS in QEMU (type 'exit' in the guest shell to quit)..."
exec qemu-system-x86_64 \
    -cpu max \
    -kernel "$OUT/planet-kernel" \
    -drive file="$OUT/disk.img",format=raw,if=ide \
    "${GPU_ARGS[@]}" \
    "${DISP_ARGS[@]}" \
    "${SER_ARGS[@]}" \
    -no-reboot \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
