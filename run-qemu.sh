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
ADD_FILES=()
RUN_CMD=""
RUN_SECONDS=60
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
        # --add=FILE puts an extra file in the image (a port's binary and its
        # data files) and --run=CMD types that command at the shell prompt.
        --add=*)      ADD_FILES+=("${arg#--add=}") ;;
        --run=*)      RUN_CMD="${arg#--run=}" ;;
        --run-seconds=*) RUN_SECONDS="${arg#--run-seconds=}" ;;
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
JOBS="${PLANC_JOBS:-$(nproc 2>/dev/null || echo 4)}"
wave_pids=()
run_job() {
    "$@" &
    wave_pids+=($!)
    if [ "${#wave_pids[@]}" -ge "$JOBS" ]; then
        wait "${wave_pids[0]}"
        wave_pids=("${wave_pids[@]:1}")
    fi
}
wait_wave() {
    local p
    for p in ${wave_pids+"${wave_pids[@]}"}; do
        wait "$p"
    done
    wave_pids=()
}

GLIB_SRCS=("$ROOT/stdlib/glib/core.vala" "$ROOT/stdlib/glib/filestream.vala" "$ROOT/stdlib/glib/utils.vala" "$ROOT/stdlib/glib/test_option.vala" "$ROOT/stdlib/glib/math.vala" "$ROOT/stdlib/glib/process.vala" "$ROOT/stdlib/glib/keyfile.vala" "$ROOT/stdlib/glib/mainloop.vala" "$ROOT/stdlib/glib/regex.vala" "$ROOT/stdlib/glib/variant.vala" "$ROOT/stdlib/glib/time.plan" "$ROOT/stdlib/glib/thread.vala" "$ROOT/stdlib/glib/uuid.plan" "$ROOT/stdlib/glib/bit.plan" "$ROOT/stdlib/glib/memory.vala" "$ROOT/stdlib/glib/slice.plan" "$ROOT/stdlib/glib/atomic.vala" "$ROOT/stdlib/glib/bytes.plan" "$ROOT/stdlib/glib/codec.vala" "$ROOT/stdlib/glib/hashtable.vala" "$ROOT/stdlib/glib/queue.plan" "$ROOT/stdlib/glib/uri.plan" "$ROOT/stdlib/glib/bookmark.vala" "$ROOT/stdlib/glib/arena.plan" "$ROOT/stdlib/glib/simd.plan")
GEE_SRCS=("$ROOT/stdlib/gee/base.vala" "$ROOT/stdlib/gee/lists.plan" "$ROOT/stdlib/gee/maps.vala" "$ROOT/stdlib/gee/queues.vala" "$ROOT/stdlib/gee/trees.vala")
GIO_SRCS=("$ROOT/stdlib/gio/types.vala" "$ROOT/stdlib/gio/streams.plan" "$ROOT/stdlib/gio/converter.vala" "$ROOT/stdlib/gio/file.vala" "$ROOT/stdlib/gio/models.vala" "$ROOT/stdlib/gio/planet.vala" "$ROOT/stdlib/gio/stack.vala" "$ROOT/stdlib/gio/net.vala" "$ROOT/stdlib/gio/tls.vala" "$ROOT/stdlib/gio/dns.vala" "$ROOT/stdlib/gio/subprocess.vala")
CAIRO_SRCS=("$ROOT/stdlib/cairo/surface.vala" "$ROOT/stdlib/cairo/context.vala")
GDK_SRCS=("$ROOT/stdlib/gdk/rgba.vala" "$ROOT/stdlib/gdk/event.vala" "$ROOT/stdlib/gdk/window.vala" "$ROOT/stdlib/gdk/display.vala")
GSK_SRCS=("$ROOT/stdlib/gsk/path.vala" "$ROOT/stdlib/gsk/types.vala" "$ROOT/stdlib/gsk/nodes.vala" "$ROOT/stdlib/gsk/renderer.vala")
GTK_SRCS=("$ROOT/stdlib/gtk/text.vala" "$ROOT/stdlib/gtk/widget.vala" "$ROOT/stdlib/gtk/widgets.vala" "$ROOT/stdlib/gtk/container.vala" "$ROOT/stdlib/gtk/scrolled.vala" "$ROOT/stdlib/gtk/listview.vala" "$ROOT/stdlib/gtk/image.vala" "$ROOT/stdlib/gtk/window.vala")
COMPOSITOR_SRCS=("$ROOT/tools/c2plan_rt.plan" "$ROOT/stdlib/gdk/stb_image.vala" "$ROOT/user/compositor/apps.vala" "$ROOT/user/compositor/win.vala" "$ROOT/user/compositor/wm.vala" "$ROOT/user/compositor/main.vala")

LIBDIR="$OUT/library"
mkdir -p "$LIBDIR"/{glib,gee,gio,cairo,gdk,pango,spirv,venus,gsk,gtk,gobject,gmodule,unsafe}
LIB_FLAGS="--library-dir=$LIBDIR"

# Wave 1: glib root (always starts at 0x1800000)
"$PLANC" $OPT --target=planetos --nostdlib --format=dlib --image-base=0x1800000 "$ROOT/stdlib/planet_sys.vala" "${GLIB_SRCS[@]}" -o "$LIBDIR/glib/glib.dlib"

build_dlib_waves() {
eval "$(python3 "$ROOT/tools/dlib_layout.py" plan "$LIBDIR" --shell)"

# Wave 2: base libs + freestanding/glib-only binaries
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --format=dlib --image-base="$BASE_unsafe" "$ROOT/stdlib/planet_unsafe.vala" -o "$LIBDIR/unsafe/unsafe.dlib"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --format=dlib --image-base="$BASE_gee" "${GEE_SRCS[@]}" -o "$LIBDIR/gee/gee.dlib"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --format=dlib --image-base="$BASE_cairo" "${CAIRO_SRCS[@]}" -o "$LIBDIR/cairo/cairo.dlib"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --format=dlib --image-base="$BASE_spirv" "$ROOT/stdlib/spirv_compat.vala" -o "$LIBDIR/spirv/spirv.dlib"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --format=dlib --image-base="$BASE_venus" "$ROOT/stdlib/venus_compat.vala" -o "$LIBDIR/venus/venus.dlib"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --format=dlib --image-base="$BASE_gobject" "$ROOT/stdlib/gobject_compat.vala" -o "$LIBDIR/gobject/gobject.dlib"
# In-guest compiles need the GLib declarations (c2plan_sdk.plan),
# packed into one file because the guest shell line buffer is only 480 bytes.
run_job python3 "$ROOT/tools/make_sdk.py" "$OUT/c2plan_sdk.plan"
run_job "$PLANC" $OPT --target=planetos --nostdlib "$ROOT/user/init.vala" -o "$OUT/init.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --image-base=0x900000 "$ROOT/user/worker.vala" -o "$OUT/worker.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS "$ROOT/user/banner.vala" -o "$OUT/banner.elf"
run_job "$PLANC" $OPT --target=planetos --nostdlib "$ROOT/stdlib/planet_math_kernels.vala" "$ROOT/user/mathlib.plan" -o "$OUT/mathlib.dlib"
run_job "$PLANC" --target=spirv "$ROOT/user/frag_planet.vala" -o "$OUT/frag.spv"
run_job "$PLANC" --target=spirv "$ROOT/user/frag_pattern.vala" -o "$OUT/frag_pattern.spv"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS "$ROOT/user/pluto.vala" -o "$OUT/pluto.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS "$ROOT/user/jsmn_demo.vala" "$ROOT/tools/c2plan_rt.plan" -o "$OUT/jsmn_demo.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS "$ROOT/planc/src/buffer.vala" "$ROOT/planc/src/host_planetos.vala" \
    "$ROOT/tools/c2plan/ast.vala" "$ROOT/tools/c2plan/preproc.vala" "$ROOT/tools/c2plan/lexer.vala" \
    "$ROOT/tools/c2plan/parser.vala" "$ROOT/tools/c2plan/ptr_analyzer.vala" "$ROOT/tools/c2plan/translator_models.vala" "$ROOT/tools/c2plan/translator.vala" "$ROOT/tools/c2plan/main.vala" -o "$OUT/c2plan.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --image-base=0xC00000 \
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
    "$ROOT/planc/src/dwarf.plan" \
    "$ROOT/planc/src/spirv.vala" \
    "$ROOT/planc/src/opt.vala" \
    "$ROOT/planc/src/pe.plan" \
    "$ROOT/planc/src/elem_layout.plan" \
    "$ROOT/planc/src/effects.plan" \
    "$ROOT/planc/src/puzzle_ra.vala" \
    "$ROOT/planc/src/codegen.vala" \
    "$ROOT/planc/src/main.vala" \
    -o "$OUT/planc.elf"
run_job "$PLANC" $OPT --freestanding \
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
    "$ROOT/kernel/virtio_blk.vala" \
    "$ROOT/kernel/virtio_net.vala" \
    "$ROOT/kernel/env.vala" \
    "$ROOT/kernel/ramfs.plan" \
    "$ROOT/kernel/keyboard.vala" \
    "$ROOT/kernel/rtc.vala" \
    "$ROOT/kernel/mouse.vala" \
    "$ROOT/kernel/ata.vala" \
    "$ROOT/kernel/xfs.vala" \
    "$ROOT/kernel/vfs.plan" \
    "$ROOT/kernel/syscall.vala" \
    "$ROOT/kernel/elf_loader.vala" \
    "$ROOT/kernel/sched.vala" \
    "$ROOT/kernel/main.vala" \
    -o "$OUT/planet-kernel"
wait_wave

# Wave 3: mid-tier libs + binaries using Wave 2 libs
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=unsafe --format=dlib --image-base="$BASE_gio" "${GIO_SRCS[@]}" -o "$LIBDIR/gio/gio.dlib"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=unsafe --import-lib=cairo --format=dlib --image-base="$BASE_gdk" "${GDK_SRCS[@]}" -o "$LIBDIR/gdk/gdk.dlib"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=cairo --format=dlib --image-base="$BASE_pango" "$ROOT/stdlib/schrift.vala" "$ROOT/stdlib/pango_compat.vala" -o "$LIBDIR/pango/pango.dlib"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=unsafe --format=dlib --image-base="$BASE_gmodule" "$ROOT/stdlib/gmodule_compat.vala" -o "$LIBDIR/gmodule/gmodule.dlib"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=gee "$ROOT/user/wc.plan" -o "$OUT/wc.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=gobject "$ROOT/user/gobject_demo.vala" -o "$OUT/gobject_demo.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=unsafe "$ROOT/user/sys_demo.vala" -o "$OUT/sys_demo.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --image-base=0xA00000 --import-lib=gee "$ROOT/user/shell.plan" -o "$OUT/shell.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --image-base=0xB00000 --import-lib=gee "$ROOT/user/shell.plan" -o "$OUT/vte_sh.elf"
wait_wave

# Wave 4: gsk + binaries using Wave 3 libs
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=unsafe --import-lib=cairo --import-lib=gdk --import-lib=spirv --import-lib=venus --format=dlib --image-base="$BASE_gsk" "${GSK_SRCS[@]}" -o "$LIBDIR/gsk/gsk.dlib"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=gio "$ROOT/user/gio_demo.vala" -o "$OUT/gio_demo.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=gee --import-lib=gio "$ROOT/user/curl.vala" -o "$OUT/curl.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=gmodule "$ROOT/user/gmodule_demo.vala" -o "$OUT/gmodule_demo.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=unsafe --import-lib=gmodule "$ROOT/user/plan_demo.plan" -o "$OUT/plan_demo.plan"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=gio "$ROOT/user/mainloop_demo.vala" -o "$OUT/mainloop_demo.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=cairo --import-lib=gdk "$ROOT/user/cairo_demo.vala" -o "$OUT/cairo_demo.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=unsafe --import-lib=spirv --import-lib=cairo --import-lib=gdk "$ROOT/user/spv_demo.vala" -o "$OUT/spv_demo.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=cairo --import-lib=pango "$ROOT/user/pango_demo.vala" -o "$OUT/pango_demo.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=gio "$ROOT/user/mercury.vala" -o "$OUT/mercury.elf"
wait_wave

# Wave 5: gtk + vk_demo
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=gio --import-lib=cairo --import-lib=gdk --import-lib=gsk --import-lib=pango --import-lib=spirv --import-lib=venus --format=dlib --image-base="$BASE_gtk" "${GTK_SRCS[@]}" -o "$LIBDIR/gtk/gtk.dlib"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=spirv --import-lib=venus --import-lib=cairo --import-lib=gdk --import-lib=gsk "$ROOT/user/vk_demo.vala" -o "$OUT/vk_demo.elf"
wait_wave

# Wave 6: gtk apps
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --image-base=0xE00000 --import-lib=unsafe --import-lib=gio --import-lib=cairo --import-lib=gdk --import-lib=pango --import-lib=spirv --import-lib=venus --import-lib=gsk --import-lib=gtk "${COMPOSITOR_SRCS[@]}" -o "$OUT/compositor.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=gee --import-lib=gio --import-lib=spirv --import-lib=venus --import-lib=cairo --import-lib=gdk --import-lib=gsk --import-lib=pango --import-lib=gtk "$ROOT/user/pcm4.plan" -o "$OUT/pcm4.elf"
run_job "$PLANC" $OPT --target=planetos $LIB_FLAGS --import-lib=unsafe --import-lib=gee --import-lib=gio --import-lib=spirv --import-lib=venus --import-lib=cairo --import-lib=gdk --import-lib=gsk --import-lib=pango --import-lib=gtk "$ROOT/user/saturn.plan" -o "$OUT/saturn.elf"
wait_wave
}

build_dlib_waves
if ! python3 "$ROOT/tools/dlib_layout.py" verify "$LIBDIR"; then
    echo "Re-packing .dlib image bases with measured sizes..."
    build_dlib_waves
    python3 "$ROOT/tools/dlib_layout.py" verify "$LIBDIR"
fi

# Fails the build when the fixed low-memory window in kernel/layout.vala is
# broken (overlapping regions, image reaching into it, asm literals drifted).
python3 "$ROOT/tools/check_layout.py" "$OUT/planet-kernel"

MK_ADD=()
for add_file in ${ADD_FILES+"${ADD_FILES[@]}"}; do
    if [ ! -f "$add_file" ]; then echo "run-qemu: --add: missing $add_file" >&2; exit 1; fi
    MK_ADD+=(--add "$(basename "$add_file")=$add_file")
done
python3 "$ROOT/tools/mkdisk.py" "$OUT/disk.img" \
    "$OUT/init.elf" "$OUT/shell.elf" "$OUT/planc.elf" "$OUT/banner.elf" \
    "$OUT/worker.elf" "$OUT/wc.elf" "$OUT/cairo_demo.elf" "$OUT/frag.spv" \
    "$OUT/spv_demo.elf" "$OUT/gio_demo.elf" \
    "$ROOT/planc/tests/valid/utf8.vala" "$ROOT/planc/tests/valid/class_basic.vala" \
    "$OUT/gobject_demo.elf" "$OUT/gmodule_demo.elf" "$OUT/mainloop_demo.elf" "$OUT/compositor.elf" "$OUT/pango_demo.elf" "$OUT/vk_demo.elf" "$OUT/c2plan.elf" "$ROOT/tools/c2plan_tests/cases/arith/main.c" "$OUT/frag_pattern.spv" "$ROOT/assets/Tahoma.ttf" "$ROOT/assets/Consolas-Regular.ttf" "$ROOT/cursor.svg" "$OUT/pcm4.elf" "$OUT/mathlib.dlib" "$OUT/plan_demo.plan" "$OUT/vte_sh.elf" "$OUT/pluto.elf" "$OUT/saturn.elf" "$OUT/jsmn_demo.elf" "$OUT/c2plan_sdk.plan" "$OUT/sys_demo.elf" "$OUT/mercury.elf" "$OUT/curl.elf" "$ROOT/assets/winxp.jpg" \
    --lib "$LIBDIR/glib/glib.dlib" --lib "$LIBDIR/glib/glib.hlib" \
    --lib "$LIBDIR/gee/gee.dlib" --lib "$LIBDIR/gee/gee.hlib" \
    --lib "$LIBDIR/gio/gio.dlib" --lib "$LIBDIR/gio/gio.hlib" \
    --lib "$LIBDIR/cairo/cairo.dlib" --lib "$LIBDIR/cairo/cairo.hlib" \
    --lib "$LIBDIR/gdk/gdk.dlib" --lib "$LIBDIR/gdk/gdk.hlib" \
    --lib "$LIBDIR/pango/pango.dlib" --lib "$LIBDIR/pango/pango.hlib" \
    --lib "$LIBDIR/spirv/spirv.dlib" --lib "$LIBDIR/spirv/spirv.hlib" \
    --lib "$LIBDIR/venus/venus.dlib" --lib "$LIBDIR/venus/venus.hlib" \
    --lib "$LIBDIR/gsk/gsk.dlib" --lib "$LIBDIR/gsk/gsk.hlib" \
    --lib "$LIBDIR/gtk/gtk.dlib" --lib "$LIBDIR/gtk/gtk.hlib" \
    --lib "$LIBDIR/gobject/gobject.dlib" --lib "$LIBDIR/gobject/gobject.hlib" \
    --lib "$LIBDIR/gmodule/gmodule.dlib" --lib "$LIBDIR/gmodule/gmodule.hlib" \
    --lib "$LIBDIR/unsafe/unsafe.dlib" --lib "$LIBDIR/unsafe/unsafe.hlib" \
    ${MK_ADD+"${MK_ADD[@]}"}

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
if [ -n "$RUN_CMD" ]; then
    echo "Typing into the guest shell: $RUN_CMD"
    { sleep 10; printf '%s\n' "$RUN_CMD"; sleep "$RUN_SECONDS"; } | qemu-system-x86_64 \
    -cpu max \
    -m 1024M \
    -kernel "$OUT/planet-kernel" \
    -drive file="$OUT/disk.img",format=raw,if=ide \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    "${GPU_ARGS[@]}" \
    "${DISP_ARGS[@]}" \
    "${SER_ARGS[@]}" \
    -no-reboot \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
    exit 0
fi
exec qemu-system-x86_64 \
    -cpu max \
    -m 1024M \
    -kernel "$OUT/planet-kernel" \
    -drive file="$OUT/disk.img",format=raw,if=ide \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    "${GPU_ARGS[@]}" \
    "${DISP_ARGS[@]}" \
    "${SER_ARGS[@]}" \
    -no-reboot \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
