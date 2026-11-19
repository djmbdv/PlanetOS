// Compositor entry point, interactive loop, and self-test.
using GLib;
using Planet;
using Pango;
using PangoCairo;
using Spv;
using Cairo;
using Gdk;
using Gtk;
using Gsk;
using Wm;

// --- self test ---------------------------------------------------------

private int st_checks = 0;
private int st_fails = 0;

private void check (bool ok, string name) {
    st_checks = st_checks + 1;
    if (ok)
        return;
    st_fails = st_fails + 1;
    print (@"compositor: FAIL $name\n");
}

private int top_id (Compositor comp) {
    int id = 0;
    var t = comp.top_win ();
    if (t != null)
        id = t.id;
    return id;
}

private int at_id (Compositor comp, int px, int py) {
    int id = 0;
    var t = comp.top_at (px, py);
    if (t != null)
        id = t.id;
    return id;
}

private int self_test_run (Compositor comp) {
    // stack ordering and hit testing
    int a = comp.add ("alpha", 100, 80, 320, 200, Kind.TERMINAL);
    int b = comp.add ("beta", 180, 150, 300, 180, Kind.CLOCK);
    int c = comp.add ("gamma", 420, 100, 260, 160, Kind.NOTES);
    check (a == 1 && b == 2 && c == 3, "ids-sequential");
    check (comp.count () == 3, "count-is-3");
    check (top_id (comp) == 3, "top-is-last-added");
    check (comp.focus_id () == 3, "focus-is-last-added");
    check (at_id (comp, 150, 100) == 1, "hit-alpha");
    check (at_id (comp, 200, 160) == 2, "hit-topmost-on-overlap");
    check (at_id (comp, 770, 400) == 0, "hit-desktop-empty");
    check (comp.pointer_press (150, 200) == ACT_FOCUS, "click-content-focus");
    check (comp.focus_id () == 1, "click-raises-focus");
    check (top_id (comp) == 1, "click-raises-z");
    check (comp.pointer_press (770, 400) == ACT_NONE, "click-desktop-noop");
    check (comp.focus_id () == 1, "click-desktop-keeps-focus");

    // drag, clamp, close button
    var drag = new Compositor ();
    int p = drag.add ("p", 60, 60, 300, 200, Kind.TERMINAL);
    int q = drag.add ("q", 420, 300, 300, 200, Kind.CLOCK);
    check (drag.pointer_press (100, 70) == ACT_DRAG, "title-starts-drag");
    check (drag.dragging_active (), "drag-active");
    drag.drag_to (140, 90);
    check (drag.wx (p) == 100 && drag.wy (p) == 80, "drag-moves-window");
    drag.drag_to (-5000, -5000);
    check (drag.wx (p) == -220, "drag-clamps-left");
    check (drag.wy (p) == TOP_H, "drag-clamps-top");
    drag.pointer_release ();
    check (!drag.dragging_active (), "release-ends-drag");
    int cxp = -220 + 300 - BORDER - BTN_GAP - BTN + 2;
    int cyp = TOP_H + BORDER + (TITLE_H - BTN) / 2 + 2;
    check (drag.pointer_press (cxp, cyp) == ACT_CLOSE, "close-button-hit");
    check (!drag.alive (p), "close-button-closes");
    check (drag.count () == 1, "count-after-close");
    check (drag.focus_id () == q, "focus-falls-back-to-top");

    // maximize, keyboard moves, cycling, dock
    var kb = new Compositor ();
    int k1 = kb.add ("one", 50, 50, 300, 200, Kind.TERMINAL);
    int k2 = kb.add ("two", 380, 60, 300, 200, Kind.CLOCK);
    int k3 = kb.add ("three", 100, 320, 300, 180, Kind.NOTES);
    kb.key_press ('m');
    check (kb.maximized (k3) && kb.ww (k3) == SCREEN_W, "maximize-sizes");
    check (kb.wy (k3) == TOP_H, "maximize-offsets-top-bar");
    kb.key_press ('m');
    check (!kb.maximized (k3) && kb.ww (k3) == 300 && kb.wy (k3) == 320, "maximize-restores");
    kb.focus_nth (0);
    check (kb.focus_id () == k1, "focus-nth-first");
    kb.key_press ('l');
    check (kb.wx (k1) == 58, "key-moves-right");
    kb.key_press ('j');
    check (kb.wy (k1) == 58, "key-moves-down");
    kb.key_press (0x84);
    check (kb.wx (k1) == 66, "arrow-key-moves-right");
    int order1 = kb.focus_id ();
    kb.key_press (9);
    check (kb.focus_id () != order1, "tab-changes-focus");
    kb.key_press (9);
    kb.key_press (9);
    check (kb.focus_id () == order1, "tab-wraps-around");
    int dockx = DOCK_X0 + (DOCK_BTN_W + DOCK_BTN_GAP) + 10;
    check (kb.pointer_press (dockx, SCREEN_H - 10) == ACT_DOCK, "dock-button-hit");
    check (kb.focus_id () == k2, "dock-focuses-second");
    kb.key_press ('c');
    check (!kb.alive (k2) && kb.count () == 2, "key-closes-focused");

    // rendering smoke test (no framebuffer needed)
    // One 1280x720 surface is 900 contiguous frames and every block below starts
    // with a full flush, so the whole self-test shares this one: allocating five
    // of them (18 MiB) is more than the allocator can serve in --animate mode.
    var surf = new ImageSurface (Format.ARGB32, SCREEN_W, SCREEN_H);
    check (surf.buf_addr != 0, "surface-alloc");
    var cr = new Context (surf);
    kb.render (cr, 200, 200);
    check (surf.buf_addr != 0 && kb.count () == 2, "render-survives");
    check (comp.cursor_from_svg (), "cursor-svg-loaded");
    check (comp.cursor_alpha (9, 5) > 128, "cursor-svg-shape");
    check (comp.cursor_alpha (0, 0) == 0, "cursor-svg-clear");

    // spir-v accent pipeline
    check (comp.shader_valid (), "shader-module-valid");
    check (comp.shader_words () > 0, "shader-words");
    check (comp.accent_ir () >= 0 && comp.accent_ir () <= 255, "accent-in-range");
    check (!comp.select_backend (BACKEND_VULKAN), "vulkan-needs-icd");
    check (comp.select_backend (BACKEND_CAIRO) && comp.backend () == BACKEND_CAIRO, "cairo-backend");

    // per-pixel SPIR-V background (gl_FragCoord) baked into PAT_STEP blocks
    check (comp.has_pattern (), "pattern-valid");
    int ps = comp.pattern_step ();
    check (comp.pattern_samples () == ((SCREEN_W + ps - 1) / ps) * ((SCREEN_H + ps - 1) / ps), "pattern-samples");
    check (comp.pattern_at (100, 100) != comp.pattern_at (700, 500), "pattern-varies-per-pixel");
    check (comp.pattern_has_uniforms (), "pattern-uniforms");
    int col_before = comp.pattern_at (400, 100);
    check (comp.animate_pattern (4.0), "pattern-animate-runs");
    check (comp.pattern_at (400, 100) != col_before, "pattern-animates-with-time");
    check (comp.animation_count () == 1, "animate-count");

    // damage merging and occlusion culling
    var mg = new Compositor ();
    var surf4 = surf;
    check (surf4.buf_addr != 0, "merge-surface-alloc");
    var cr4 = new Context (surf4);
    mg.flush (cr4, 0, 0);
    mg.damage (10, 10, 20, 20);
    mg.damage (25, 25, 20, 20);
    check (mg.damage_count () == 1, "damage-merges");
    check (mg.damage_pixels () == 35 * 35, "damage-merge-area");
    mg.damage (500, 400, 20, 20);
    check (mg.damage_count () == 2, "damage-keeps-distant");
    mg.flush (cr4, 0, 0);
    check (mg.damage_count () == 0, "merge-flush-clears");

    var occ = new Compositor ();
    occ.add ("low", 100, 100, 300, 200, Kind.TERMINAL);
    occ.add ("high", 60, 60, 420, 320, Kind.NOTES);
    var surv5 = surf;
    check (surv5.buf_addr != 0, "occlusion-surface-alloc");
    var cr5 = new Context (surv5);
    occ.flush (cr5, 0, 0);
    check (occ.occluded_count () == 1, "occlusion-skips-covered");
    occ.focus_nth (0);
    occ.flush (cr5, 0, 0);
    check (occ.occluded_count () == 0, "occlusion-none-when-raised");

    // damage tracking: only the dirty region is repainted
    var dmgc = new Compositor ();
    dmgc.add ("d", 200, 200, 200, 150, Kind.NOTES);
    check (dmgc.damage_is_full (), "add-damages-all");
    var surf2 = surf;
    check (surf2.buf_addr != 0, "damage-surface-alloc");
    var cr2 = new Context (surf2);
    dmgc.flush (cr2, 0, 0);
    check (!dmgc.damage_is_full () && dmgc.damage_count () == 0, "flush-clears-damage");
    cr2.set_source_rgb (1.0, 0.0, 1.0);
    cr2.paint ();
    dmgc.damage (300, 300, 40, 40);
    check (dmgc.damage_count () == 1 && dmgc.damage_pixels () == 1600, "damage-recorded");
    dmgc.flush (cr2, 0, 0);
    check (cr2.pixel_at (310, 310) != ((255 << 24) | (255 << 16) | (0 << 8) | 255), "damage-repaints-inside");
    check (cr2.pixel_at (700, 100) == ((255 << 24) | (255 << 16) | (0 << 8) | 255), "damage-keeps-outside");

    // modifiers: Alt+Tab, Alt+Q and Super+arrows
    var mod = new Compositor ();
    int m1 = mod.add ("m1", 40, 40, 260, 180, Kind.TERMINAL);
    check (mod.alive (m1), "mods-m1-alive");
    int m2 = mod.add ("m2", 340, 60, 260, 180, Kind.CLOCK);
    int m3 = mod.add ("m3", 120, 300, 260, 160, Kind.NOTES);
    check (mod.focus_id () == m3, "mods-focus-last");
    mod.key_press_mod (9, Sys.MOD_ALT);
    check (mod.focus_id () != m3, "alt-tab-cycles");
    mod.focus_nth (1);
    check (mod.focus_id () == m2, "focus-second-window");
    mod.key_press_mod (0x84, Sys.MOD_SUPER);
    check (mod.layout_of (m2) == LAYOUT_RIGHT, "super-right-tiles");
    check (mod.ww (m2) == SCREEN_W / 2 && mod.wx (m2) == SCREEN_W / 2, "super-right-geometry");
    mod.key_press_mod (0x83, Sys.MOD_SUPER);
    check (mod.layout_of (m2) == LAYOUT_LEFT && mod.wx (m2) == 0, "super-left-tiles");
    mod.key_press_mod (0x81, Sys.MOD_SUPER);
    check (mod.layout_of (m2) == LAYOUT_MAX && mod.ww (m2) == SCREEN_W, "super-up-maximizes");
    mod.key_press_mod (0x82, Sys.MOD_SUPER);
    check (mod.layout_of (m2) == LAYOUT_NORMAL && mod.ww (m2) == 260, "super-down-restores");
    mod.key_press_mod ('q', Sys.MOD_ALT);
    check (!mod.alive (m2), "alt-q-closes-focused");
    check (mod.focus_id () != m2, "alt-q-moves-focus");

    // quit handling
    var qq = new Compositor ();
    qq.add ("x", 10, 40, 200, 150, Kind.NOTES);
    check (!qq.quit_requested (), "no-quit-by-default");
    qq.key_press (27);
    check (qq.quit_requested (), "esc-quits");

    // GTK window widget click + entry typing
    var gtkc = new Compositor ();
    int gw = gtkc.add ("gtk", 100, 100, 380, 240, Kind.GTK);
    var gsurf = surf;
    check (gsurf.buf_addr != 0, "gtk-surface-alloc");
    var gcr = new Context (gsurf);
    gtkc.flush (gcr, 0, 0);
    // Click Entry (around y = 100 + 24 + 12 + 30 = 166) and type 'x'
    gtkc.pointer_press (150, 166);
    gtkc.pointer_release ();
    gtkc.key_press ('x');
    // Click Increment button (around y = 205)
    gtkc.pointer_press (150, 205);
    gtkc.pointer_release ();
    gtkc.flush (gcr, 799, 599);
    check (gtkc.alive (gw), "gtk-win-alive-after-input");

    // FILES (pcm4) window: the root allocation survives a content refresh, and a
    // repaint reuses it instead of laying the tree out again.
    var filec = new Compositor ();
    int fid = filec.add ("files", 60, 80, 560, 320, Kind.FILES);
    filec.flush (gcr, 0, 0);
    var fwin = filec.top_win ();
    int fax = -2;
    int fay = -2;
    int faw = -2;
    int fah = -2;
    if (fwin != null) {
        fax = fwin.gtk_alloc_x;
        fay = fwin.gtk_alloc_y;
        faw = fwin.gtk_alloc_w;
        fah = fwin.gtk_alloc_h;
    }
    check (fwin != null && faw > 0 && fah > 0, "files-alloc-set");
    if (fwin != null && fwin.pcm4_state != null)
        fwin.pcm4_state.refresh ("/");
    filec.flush (gcr, 0, 0);
    check (fwin != null && fwin.gtk_alloc_x == fax && fwin.gtk_alloc_y == fay
           && fwin.gtk_alloc_w == faw && fwin.gtk_alloc_h == fah, "files-repaint-keeps-alloc");
    check (filec.alive (fid), "files-win-alive");

    // VTE terminal typing
    var termc = new Compositor ();
    int tw = termc.add ("term", 40, 50, 400, 240, Kind.TERMINAL);
    termc.pointer_press (100, 120);
    termc.key_press ('h');
    termc.key_press ('e');
    termc.key_press ('l');
    termc.key_press ('p');
    termc.key_press ('\n');
    check (termc.alive (tw), "vte-term-alive");

    // GTK layout: pack_start's fill flag decides the cross size, and repainting a
    // scrolled subtree must not move it.
    var lbox = new Box (Orientation.VERTICAL, 8);
    var ltight = new Button ("ok");
    var lstretch = new Button ("ok");
    lbox.pack_start (ltight, false, false);
    lbox.pack_start (lstretch, false, true);
    lbox.allocate (0, 0, 300, 200);
    int lw = 0;
    int lh = 0;
    ltight.measure (out lw, out lh);
    check (ltight.width == lw, "box-fill-false-natural-width");
    check (lstretch.width == 300, "box-fill-true-stretches");

    var lscroll = new ScrolledWindow ();
    var lrows = new Box (Orientation.VERTICAL, 4);
    for (int i = 0; i < 20; i++)
        lrows.pack_start (new Label (@"row $i"));
    lscroll.set_child (lrows);
    lscroll.allocate (10, 20, 180, 100);
    int ly = lrows.y;
    int lh2 = lrows.height;
    var lcr = new Context (surf);
    lscroll.draw (lcr);
    lscroll.draw (lcr);
    check (lrows.y == ly && lrows.height == lh2, "scroll-repaint-keeps-layout");
    lscroll.scroll_by (0, 40);
    check (lrows.y == ly - 40, "scroll-moves-content");
    lscroll.draw (lcr);
    check (lrows.y == ly - 40, "scroll-draw-keeps-offset");

    print (@"compositor: cursor_svg=$(comp.cursor_from_svg () ? 1 : 0) hotspot=$(comp.cursor_hotspot_x ())x$(comp.cursor_hotspot_y ())\n");
    print (@"compositor:summary checks=$st_checks failures=$st_fails\n");
    return (st_fails == 0) ? 0 : 1;
}

// --- interactive -------------------------------------------------------

private int interactive (Compositor comp) {
    var win = Display.open_window (SCREEN_W, SCREEN_H);
    if (win == null) {
        print ("compositor: no framebuffer available\n");
        return 1;
    }
    comp.attach (win, false);
    print (@"compositor: cursor=$(comp.hardware_cursor () ? "hw" : "sw") screen=$(SCREEN_W)x$(SCREEN_H)\n");
    var loop = new MainLoop ();
    timeout_add (16, () => {
        if (!comp.frame ()) {
            loop.quit ();
            return false;
        }
        return true;
    });
    loop.run ();
    comp.shutdown ();
    print (@"compositor: frames=$(comp.frame_count ()) moves=$(comp.motion_count ()) windows=$(comp.count ()) dirty=$(comp.dirty_frame_count ()) flush_ms=$(comp.avg_flush_ms ()) blit_ms=$(comp.avg_blit_ms ())\n");
    return 0;
}

int main (string[] args) {
    bool self_test = false;
    bool want_shader = true;
    bool want_vulkan = false;
    bool want_pattern = true;
    bool want_animate = false;
    string shader_path = "frag.spv";
    string pattern_path = "frag_pattern.spv";
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--self-test") {
            self_test = true;
        } else if (args[i] == "--no-shader") {
            want_shader = false;
        } else if (args[i] == "--no-pattern") {
            want_pattern = false;
        } else if (args[i] == "--animate") {
            want_animate = true;
        } else if (args[i] == "--vulkan") {
            want_vulkan = true;
        } else if (args[i] == "--pattern") {
            if (i + 1 < args.length) {
                i = i + 1;
                pattern_path = args[i];
            }
        } else if (args[i] == "--shader") {
            if (i + 1 < args.length) {
                i = i + 1;
                shader_path = args[i];
            }
        } else {
            shader_path = args[i];
        }
    }

    var comp = new Compositor ();
    if (want_shader) {
        bool ok = comp.load_shader (shader_path);
        print (@"compositor: shader=$shader_path ok=$(ok ? 1 : 0) rgba=$(comp.accent_ir ()),$(comp.accent_ig ()),$(comp.accent_ib ())\n");
    }
    if (want_vulkan) {
        bool ok = comp.select_backend (BACKEND_VULKAN);
        print (@"compositor: backend=vulkan ok=$(ok ? 1 : 0) (no ICD yet, cairo fallback)\n");
    }
    if (want_animate)
        comp.set_pattern_step (16);
    if (want_pattern) {
        bool pok = comp.load_pattern (pattern_path);
        print (@"compositor: pattern=$pattern_path ok=$(pok ? 1 : 0) samples=$(comp.pattern_samples ()) uniforms=$(comp.pattern_has_uniforms () ? 1 : 0)\n");
        if (want_animate)
            comp.set_animation (true, 400);
        print (@"compositor: animate=$(want_animate ? 1 : 0) period_ms=400\n");
    }
    if (self_test)
        return self_test_run (comp);

    comp.seed ();
    print ("compositor: keys: tab cycle  drag=move  m max  c close  n new  1-9 focus  q quit\n");
    return interactive (comp);
}
