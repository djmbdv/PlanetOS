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
WINDOW_BACKEND="gtk"
# virtio-gpu with virgl by default; blob=on exposes RESOURCE_BLOB so the
# Phase 3 context/blob path can be probed (guest blobs need no hostmem).
# --vga falls back to the plain VGA path, --virtio keeps virtio-gpu without GL
# and --venus (or the old --virtio-gl) asks for the venus/hostmem setup that
# needs a render-server virglrenderer.
GPU_MODE="gl"
for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=1 ;;
        --headless)   DISPLAY_MODE="none" ;;
        --display)    DISPLAY_MODE="gtk" ;;
        --vga)        GPU_MODE="std" ;;
        --virtio)     GPU_MODE="virtio" ;;
        --venus)      GPU_MODE="venus" ;;
        --virtio-gl)  GPU_MODE="venus" ;;
        --sdl)        WINDOW_BACKEND="sdl" ;;
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
GLIB_SRCS=("$ROOT/stdlib/glib/core.vala" "$ROOT/stdlib/glib/math.vala" "$ROOT/stdlib/glib/process.vala" "$ROOT/stdlib/glib/keyfile.vala" "$ROOT/stdlib/glib/mainloop.vala" "$ROOT/stdlib/glib/regex.vala" "$ROOT/stdlib/glib/variant.vala" "$ROOT/stdlib/glib/time.vala" "$ROOT/stdlib/glib/thread.vala" "$ROOT/stdlib/glib/uuid.vala" "$ROOT/stdlib/glib/bit.vala" "$ROOT/stdlib/glib/memory.vala" "$ROOT/stdlib/glib/slice.vala" "$ROOT/stdlib/glib/atomic.vala" "$ROOT/stdlib/glib/bytes.vala" "$ROOT/stdlib/glib/codec.vala" "$ROOT/stdlib/glib/hashtable.vala" "$ROOT/stdlib/glib/queue.vala")
GEE_SRCS=("$ROOT/stdlib/gee/base.vala" "$ROOT/stdlib/gee/lists.vala" "$ROOT/stdlib/gee/maps.vala" "$ROOT/stdlib/gee/queues.vala" "$ROOT/stdlib/gee/trees.vala")
GIO_SRCS=("$ROOT/stdlib/gio/types.vala" "$ROOT/stdlib/gio/streams.vala" "$ROOT/stdlib/gio/file.vala" "$ROOT/stdlib/gio/models.vala")
CAIRO_SRCS=("$ROOT/stdlib/cairo/surface.vala" "$ROOT/stdlib/cairo/context.vala")
GDK_SRCS=("$ROOT/stdlib/gdk/rgba.vala" "$ROOT/stdlib/gdk/event.vala" "$ROOT/stdlib/gdk/window.vala" "$ROOT/stdlib/gdk/display.vala")
GSK_SRCS=("$ROOT/stdlib/gsk/types.vala" "$ROOT/stdlib/gsk/nodes.vala" "$ROOT/stdlib/gsk/renderer.vala")
GTK_SRCS=("$ROOT/stdlib/gtk/text.vala" "$ROOT/stdlib/gtk/widget.vala" "$ROOT/stdlib/gtk/widgets.vala" "$ROOT/stdlib/gtk/container.vala" "$ROOT/stdlib/gtk/scrolled.vala" "$ROOT/stdlib/gtk/listview.vala" "$ROOT/stdlib/gtk/image.vala" "$ROOT/stdlib/gtk/window.vala")
COMPOSITOR_SRCS=("$ROOT/user/compositor/apps.vala" "$ROOT/user/compositor/win.vala" "$ROOT/user/compositor/wm.vala" "$ROOT/user/compositor/main.vala")

"$PLANC" $OPT --target=planetos --format=dlib --image-base=0x1800000 "$ROOT/stdlib/planet_sys.vala" "${GLIB_SRCS[@]}" -o "$OUT/glib.dlib"
GLIB_IMP="--import-dlib=$OUT/glib.dlib"
"$PLANC" $OPT --target=planetos "$ROOT/user/init.vala" -o "$OUT/init.elf"
"$PLANC" $OPT --target=planetos --image-base=0x900000 "$ROOT/stdlib/planet_sys.vala" "$ROOT/user/worker.vala" -o "$OUT/worker.elf"
"$PLANC" $OPT --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/user/banner.vala" -o "$OUT/banner.elf"
"$PLANC" $OPT --target=planetos "$GLIB_IMP" "$ROOT/stdlib/planet_sys.vala" "${GLIB_SRCS[@]}" "${GEE_SRCS[@]}" "$ROOT/user/wc.vala" -o "$OUT/wc.elf"
"$PLANC" $OPT --target=planetos "$GLIB_IMP" "$ROOT/stdlib/planet_sys.vala" "${GLIB_SRCS[@]}" "${GIO_SRCS[@]}" "$ROOT/user/gio_demo.vala" -o "$OUT/gio_demo.elf"
"$PLANC" $OPT --target=planetos "$ROOT/stdlib/gobject_compat.vala" "$ROOT/user/gobject_demo.vala" -o "$OUT/gobject_demo.elf"
"$PLANC" $OPT --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/gmodule_compat.vala" "$ROOT/user/gmodule_demo.vala" -o "$OUT/gmodule_demo.elf"
"$PLANC" $OPT --target=planetos "$ROOT/user/mathlib.vala" -o "$OUT/mathlib.dlib"
"$PLANC" $OPT --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/gmodule_compat.vala" "$ROOT/user/plan_demo.vala" -o "$OUT/plan_demo.plan"
"$PLANC" $OPT --target=planetos "$GLIB_IMP" "$ROOT/stdlib/planet_sys.vala" "${GLIB_SRCS[@]}" "${GIO_SRCS[@]}" "$ROOT/user/mainloop_demo.vala" -o "$OUT/mainloop_demo.elf"
"$PLANC" $OPT --target=planetos "$ROOT/stdlib/planet_sys.vala" "${CAIRO_SRCS[@]}" "${GDK_SRCS[@]}" "$ROOT/user/cairo_demo.vala" -o "$OUT/cairo_demo.elf"
"$PLANC" --target=spirv "$ROOT/user/frag_planet.vala" -o "$OUT/frag.spv"
"$PLANC" --target=spirv "$ROOT/user/frag_pattern.vala" -o "$OUT/frag_pattern.spv"
"$PLANC" $OPT --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/glib/math.vala" "$ROOT/stdlib/spirv_compat.vala" "${CAIRO_SRCS[@]}" "${GDK_SRCS[@]}" "$ROOT/user/spv_demo.vala" -o "$OUT/spv_demo.elf"
"$PLANC" $OPT --target=planetos "$ROOT/stdlib/planet_sys.vala" "$ROOT/stdlib/glib/math.vala" "$ROOT/stdlib/spirv_compat.vala" "$ROOT/stdlib/venus_compat.vala" "${CAIRO_SRCS[@]}" "${GDK_SRCS[@]}" "${GSK_SRCS[@]}" "$ROOT/user/vk_demo.vala" -o "$OUT/vk_demo.elf"
"$PLANC" $OPT --target=planetos --image-base=0xE00000 "$GLIB_IMP" "$ROOT/stdlib/planet_sys.vala" "${GLIB_SRCS[@]}" "$ROOT/stdlib/pango_compat.vala" "$ROOT/stdlib/spirv_compat.vala" "$ROOT/stdlib/venus_compat.vala" "${CAIRO_SRCS[@]}" "${GDK_SRCS[@]}" "$ROOT/stdlib/schrift.vala" "$ROOT/stdlib/gsk/path.vala" "${GSK_SRCS[@]}" "${GTK_SRCS[@]}" "${COMPOSITOR_SRCS[@]}" -o "$OUT/compositor.elf"
"$PLANC" $OPT --target=planetos "$ROOT/stdlib/planet_sys.vala" "${CAIRO_SRCS[@]}" "$ROOT/stdlib/pango_compat.vala" "$ROOT/user/pango_demo.vala" -o "$OUT/pango_demo.elf"
"$PLANC" $OPT --target=planetos "$GLIB_IMP" "$ROOT/stdlib/planet_sys.vala" "${GLIB_SRCS[@]}" "${GEE_SRCS[@]}" "${GIO_SRCS[@]}" "${CAIRO_SRCS[@]}" "${GDK_SRCS[@]}" "$ROOT/stdlib/schrift.vala" "${GTK_SRCS[@]}" "$ROOT/user/pcm4.vala" -o "$OUT/pcm4.elf"
"$PLANC" $OPT --target=planetos "$GLIB_IMP" "$ROOT/stdlib/planet_sys.vala" "${GLIB_SRCS[@]}" "$ROOT/user/pluto.vala" -o "$OUT/pluto.elf"
"$PLANC" $OPT --target=planetos "$GLIB_IMP" "$ROOT/stdlib/planet_sys.vala" "${GLIB_SRCS[@]}" "${GEE_SRCS[@]}" "${GIO_SRCS[@]}" "${CAIRO_SRCS[@]}" "${GDK_SRCS[@]}" "$ROOT/stdlib/schrift.vala" "${GTK_SRCS[@]}" "$ROOT/user/saturn.vala" -o "$OUT/saturn.elf"
"$PLANC" $OPT --target=planetos "$GLIB_IMP" "$ROOT/stdlib/planet_sys.vala" "${GLIB_SRCS[@]}" "$ROOT/user/jsmn_demo.vala" "$ROOT/tools/c2vala_rt.vala" -o "$OUT/jsmn_demo.elf"
"$PLANC" $OPT --target=planetos "$ROOT/planc/src/buffer.vala" "$ROOT/planc/src/host_planetos.vala" "$ROOT/stdlib/planet_sys.vala" \
    "$ROOT/tools/c2vala/ast.vala" "$ROOT/tools/c2vala/preproc.vala" "$ROOT/tools/c2vala/lexer.vala" \
    "$ROOT/tools/c2vala/parser.vala" "$ROOT/tools/c2vala/ptr_analyzer.vala" "$ROOT/tools/c2vala/translator.vala" "$ROOT/tools/c2vala/main.vala" -o "$OUT/c2vala.elf"
"$PLANC" $OPT --target=planetos --image-base=0xA00000 "$GLIB_IMP" "$ROOT/stdlib/planet_sys.vala" "${GLIB_SRCS[@]}" "${GEE_SRCS[@]}" "$ROOT/user/shell.vala" -o "$OUT/shell.elf"
"$PLANC" $OPT --target=planetos --image-base=0xB00000 "$GLIB_IMP" "$ROOT/stdlib/planet_sys.vala" "${GLIB_SRCS[@]}" "${GEE_SRCS[@]}" "$ROOT/user/shell.vala" -o "$OUT/vte_sh.elf"
"$PLANC" $OPT --target=planetos --image-base=0xC00000 \
    "$ROOT/stdlib/planet_sys.vala" \
    "$ROOT/planc/src/buffer.vala" \
    "$ROOT/planc/src/host_planetos.vala" \
    "$ROOT/planc/src/ast.vala" \
    "$ROOT/planc/src/diag.vala" \
    "$ROOT/planc/src/preproc.vala" \
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
    "$ROOT/kernel/layout.vala" \
    "$ROOT/kernel/klog.vala" \
    "$ROOT/kernel/cpu.vala" \
    "$ROOT/kernel/vga.vala" \
    "$ROOT/kernel/fb.vala" \
    "$ROOT/kernel/pmm.vala" \
    "$ROOT/kernel/vmm.vala" \
    "$ROOT/kernel/console_font.vala" \
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

# Fails the build when the fixed low-memory window in kernel/layout.vala is
# broken (overlapping regions, image reaching into it, asm literals drifted).
python3 "$ROOT/tools/check_layout.py" "$OUT/planet-kernel"

python3 "$ROOT/tools/mkdisk.py" "$OUT/disk.img" \
    "$OUT/init.elf" "$OUT/shell.elf" "$OUT/planc.elf" "$OUT/banner.elf" \
    "$OUT/worker.elf" "$OUT/wc.elf" "$OUT/cairo_demo.elf" "$OUT/frag.spv" \
    "$OUT/spv_demo.elf" "$OUT/gio_demo.elf" \
    "$ROOT/planc/tests/valid/utf8.vala" "$ROOT/planc/tests/valid/class_basic.vala" \
    "$OUT/gobject_demo.elf" "$OUT/gmodule_demo.elf" "$OUT/mainloop_demo.elf" "$OUT/compositor.elf" "$OUT/pango_demo.elf" "$OUT/vk_demo.elf" "$OUT/c2vala.elf" "$ROOT/tools/c2vala_tests/cases/arith/main.c" "$OUT/frag_pattern.spv" "$ROOT/assets/LiberationSans-Regular.ttf" "$ROOT/assets/LiberationMono-Regular.ttf" "$ROOT/cursor.svg" "$OUT/pcm4.elf" "$OUT/mathlib.dlib" "$OUT/plan_demo.plan" "$OUT/vte_sh.elf" "$OUT/pluto.elf" "$OUT/saturn.elf" "$OUT/jsmn_demo.elf" "$OUT/glib.dlib"

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
GPU_ARGS=(-vga none -device virtio-gpu-gl-pci,blob=on)
case "$GPU_MODE" in
    std)    GPU_ARGS=(-vga std) ;;
    virtio) GPU_ARGS=(-vga none -device virtio-gpu-pci) ;;
    venus)  GPU_ARGS=(-vga none -device virtio-gpu-gl-pci,venus=on,blob=on,hostmem=256M)
            # Most virglrenderer builds lack the render server, so venus cannot
            # come up and QEMU leaves the guest on plain virgl.
            echo "QEMU: --venus needs a virglrenderer built with the render server; if QEMU reports \"failed to initialize venus renderer\", this host cannot do venus and the guest keeps plain virgl." ;;
esac
DISP_ARGS=()
SER_ARGS=()
if [ "$DISPLAY_MODE" = "none" ]; then
    case "$GPU_MODE" in
        gl|venus)
            # A GL device needs a GL-capable display backend, and egl-headless
            # boots but fails its scanouts (VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER),
            # so headless stays on the non-GL virtio-gpu: only serial matters.
            echo "QEMU: --headless has no OpenGL backend here; using virtio-gpu-pci instead of virtio-gpu-gl-pci."
            GPU_ARGS=(-vga none -device virtio-gpu-pci)
            ;;
    esac
    DISP_ARGS=(-display none)
    SER_ARGS=(-serial mon:stdio)
else
    # grab-on-hover is a GTK-only sub-option; passing it to SDL makes QEMU
    # refuse to start, so it is added only for the GTK backend.
    if [ "$WINDOW_BACKEND" = "gtk" ]; then GRAB=",grab-on-hover=on"; else GRAB=""; fi
    case "$GPU_MODE" in
        gl|venus) DISP_ARGS=(-display "$WINDOW_BACKEND,gl=on$GRAB") ;;
        virtio)   DISP_ARGS=(-display "$WINDOW_BACKEND$GRAB") ;;
        std)      if [ "$DISPLAY_MODE" = "gtk" ]; then DISP_ARGS=(-display "$WINDOW_BACKEND$GRAB"); fi ;;
    esac
    # Keep the serial console out of the terminal: QEMU's stdio backend is
    # unreliable under mintty, and the guest already draws to the VGA window.
    SER_LOG="$OUT/serial.log"
    if command -v cygpath >/dev/null 2>&1; then
        SER_LOG="$(cygpath -m "$SER_LOG")"
    fi
    SER_ARGS=(-serial "file:$SER_LOG")
    echo "Serial log: $SER_LOG"
fi

# A virtio-gpu-gl device only exists on top of an OpenGL display backend: QEMU
# refuses to start without one ("The display backend does not have OpenGL
# support enabled"), and a GL device paired with a plain backend is how a run
# silently loses virgl. Keep device and display in sync and say so out loud.
GPU_LINE="${GPU_ARGS[*]:-} ${DISP_ARGS[*]:-}"
DISP_LINE="${DISP_ARGS[*]:-}"
case "$GPU_LINE" in
    *virtio-gpu-gl*)
        case "$DISP_LINE" in
            *gl=on*) ;;
            *) echo "run-qemu: the GL device needs a gl=on display backend, got: $GPU_LINE" >&2; exit 1 ;;
        esac
        ;;
esac
echo "GPU: $GPU_MODE [$GPU_LINE]"

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
