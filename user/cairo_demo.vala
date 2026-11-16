// Interactive Cairo + Gdk graphical demo in 100% pure Vala on PlanetOS (no C, no .vapi).

using Cairo;
using Gdk;

[AsmBody(@"
    mov %rdi, %rax
    int $0x80
    ret
")]
private extern int sys_yield (int num);

void draw_scene (Context cr, int w, int h, int mx, int my, int clicks) {
    // Deep cosmic background
    cr.set_source_rgb (0.04, 0.06, 0.10);
    cr.paint ();

    // Top bar
    cr.set_source_rgb (0.09, 0.13, 0.20);
    cr.rectangle (0, 0, w, 36);
    cr.fill ();
    cr.set_source_rgb (0.22, 0.74, 0.97);
    cr.set_font_size (16);
    cr.move_to (16, 12);
    cr.show_text ("PLANETOS DESKTOP  CAIRO + GDK (100% VALA)");

    // Window card
    cr.set_source_rgb (0.08, 0.11, 0.17);
    cr.rectangle (80, 76, 640, 440);
    cr.fill ();
    cr.set_line_width (2);
    cr.set_source_rgb (0.22, 0.74, 0.97);
    cr.rectangle (80, 76, 640, 440);
    cr.stroke ();

    // Close button [X]
    cr.set_source_rgb (0.85, 0.25, 0.25);
    cr.rectangle (686, 84, 24, 24);
    cr.fill ();
    cr.set_source_rgb (1.0, 1.0, 1.0);
    cr.set_font_size (16);
    cr.move_to (693, 90);
    cr.show_text ("X");

    // Orbital planet (Cairo arc + alpha)
    cr.set_line_width (3);
    cr.set_source_rgba (0.22, 0.74, 0.97, 0.9);
    cr.arc (540, 290, 110, 0, 6.28);
    cr.stroke ();
    cr.set_source_rgba (0.96, 0.62, 0.04, 0.85);
    cr.arc (540, 290, 82, 0, 6.28);
    cr.stroke ();
    cr.set_source_rgb (0.10, 0.20, 0.32);
    cr.arc (540, 290, 64, 0, 6.28);
    cr.fill ();

    // Labels using Gdk.RGBA
    var title_col = new RGBA ();
    title_col.parse ("#F8FAFC");
    cairo_set_source_rgba (cr, title_col);
    cr.set_font_size (24);
    cr.move_to (116, 130);
    cr.show_text ("PLANETOS");

    cr.set_source_rgb (0.58, 0.64, 0.72);
    cr.set_font_size (16);
    cr.move_to (116, 185);
    cr.show_text ("PURE VALA CAIRO + GDK");
    cr.move_to (116, 220);
    cr.show_text ("800X600X32 LINEAR FB");
    cr.move_to (116, 255);
    cr.show_text ("ZERO C  ZERO VAPI");
    cr.move_to (116, 305);
    cr.set_source_rgb (0.96, 0.62, 0.04);
    cr.show_text (@"CLICKS: $clicks");
    cr.move_to (116, 465);
    cr.set_source_rgb (0.22, 0.74, 0.97);
    cr.show_text ("PRESS Q TO RETURN TO SHELL");

    // Mouse cursor
    cr.set_source_rgb (1.0, 1.0, 1.0);
    cr.rectangle (mx, my, 10, 14);
    cr.fill ();
    cr.set_source_rgb (0.22, 0.74, 0.97);
    cr.rectangle (mx + 2, my + 2, 6, 10);
    cr.fill ();
}

int main (string[] args) {
    print ("cairo_demo: open\n");
    var win = Display.open_window (800, 600);
    if (win == null) {
        print ("cairo_demo: framebuffer unavailable\n");
        return 1;
    }
    print ("cairo_demo: ctx\n");
    var cr = win.create_cairo_context ();
    int mx = 400;
    int my = 300;
    int clicks = 0;

    print ("cairo_demo: draw\n");
    draw_scene (cr, win.width, win.height, mx, my, clicks);
    print ("cairo_demo: present\n");
    win.present ();

    // If `--once` is passed (for automated CI), render 1 frame and exit cleanly
    if (args.length > 1 && args[1] == "--once") {
        win.close ();
        print ("cairo_demo: done\n");
        return 0;
    }

    while (true) {
        var ev = win.poll_event ();
        if (ev.type == EventType.KEY_PRESS) {
            if (ev.keyval == 'q' || ev.keyval == 'Q' || ev.keyval == 'x' || ev.keyval == 'X' || ev.keyval == 27)
                break;
        } else if (ev.type == EventType.BUTTON_PRESS) {
            mx = ev.x;
            my = ev.y;
            if (mx >= 686 && mx <= 710 && my >= 84 && my <= 108)
                break;
            clicks = clicks + 1;
            draw_scene (cr, win.width, win.height, mx, my, clicks);
            win.present ();
        } else if (ev.type == EventType.MOTION_NOTIFY) {
            mx = ev.x;
            my = ev.y;
            draw_scene (cr, win.width, win.height, mx, my, clicks);
            win.present ();
        } else {
            sys_yield (10);
        }
    }

    win.close ();
    return 0;
}
