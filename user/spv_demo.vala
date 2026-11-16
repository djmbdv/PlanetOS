// SPIR-V 1.0 Shader Loader, Pure-Vala VM Evaluator, and Framebuffer Demo on PlanetOS.

using Planet;
using Cairo;
using Gdk;

private double f32_bits_to_double (uint32 bits) {
    if ((bits & 0x7FFFFFFFu) == 0)
        return 0.0;
    double sign = ((bits & 0x80000000u) != 0) ? -1.0 : 1.0;
    int exp = (int) ((bits >> 23) & 0xFF) - 127;
    uint32 mant = bits & 0x7FFFFFu;
    double val = 1.0 + (double) mant / 8388608.0;
    while (exp > 0) {
        val = val * 2.0;
        exp = exp - 1;
    }
    while (exp < 0) {
        val = val * 0.5;
        exp = exp + 1;
    }
    return sign * val;
}

private uint32 read_u32_le (uint8[] buf, int word_idx) {
    int off = word_idx * 4;
    return (uint32) buf[off + 0]
        | ((uint32) buf[off + 1] << 8)
        | ((uint32) buf[off + 2] << 16)
        | ((uint32) buf[off + 3] << 24);
}

private int th_running = 1;
private int th_sat_x = 664;
private int th_sat_y = 300;
private int th_ticks = 0;
private int th_pulse_milli = 1000;

[AsmBody(@"
    # Devuelve la direccion de la funcion orbit_worker para SYS_THREAD_SPAWN
    lea orbit_worker(%rip), %rax
    ret
")]
private extern int addr_orbit_worker ();

public void orbit_worker (int arg) {
    // Hilo de fisica/orbita en segundo plano: usa solo aritmetica entera para no tocar XMM
    int last_t = -1;
    while (th_running != 0) {
        int ticks = Sys.ticks ();
        if (ticks != last_t) {
            last_t = ticks;
            th_ticks = ticks;

            int phase = (ticks * 3) % 120;
            int tri = (phase < 60) ? phase : (120 - phase);
            th_pulse_milli = 650 + (350 * tri) / 60;

            int ang = (ticks * 2) & 63;
            int qx = (ang + 16) & 63;
            int sx = (ang < 32) ? ang : (64 - ang);
            int cx = (qx < 32) ? qx : (64 - qx);
            int sin_m = (ang < 32 ? 1 : -1) * (1000 - ((sx - 16) * (sx - 16) * 1000) / 256);
            int cos_m = (qx < 32 ? 1 : -1) * (1000 - ((cx - 16) * (cx - 16) * 1000) / 256);
            th_sat_x = 540 + (cos_m * 124) / 1000;
            th_sat_y = 300 + (sin_m * 124) / 1000;
        } else {
            Sys.yield_cpu ();
        }
    }
    Sys.sys (11, 0, 0, 0);
}

int main (string[] args) {
    string spv_name = (args.length > 1 && args[1] != "--once") ? args[1] : "frag.spv";
    bool once = false;
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--once")
            once = true;
    }

    int fd = Sys.open (spv_name);
    if (fd < 0) {
        print (@"spv_demo: cannot open '$spv_name'\n");
        return 1;
    }
    int sz = Sys.file_size (fd);
    if (sz < 20 || (sz % 4) != 0) {
        Sys.close (fd);
        print ("spv_demo: invalid .spv size\n");
        return 1;
    }
    var buf = new uint8[sz];
    int got = 0;
    while (got < sz) {
        var chunk = new uint8[sz - got];
        int r = Sys.read (fd, chunk, sz - got);
        if (r <= 0) break;
        for (int i = 0; i < r; i++)
            buf[got + i] = chunk[i];
        got = got + r;
    }
    Sys.close (fd);

    uint32 magic = read_u32_le (buf, 0);
    uint32 ver   = read_u32_le (buf, 1);
    uint32 bound = read_u32_le (buf, 3);
    if (magic != 0x07230203u) {
        print ("spv_demo: bad SPIR-V magic\n");
        return 1;
    }

    // Minimal pure-Vala SPIR-V 1.0 SSA evaluator
    int max_ids = (int) bound + 4;
    var fvals = new double[max_ids];
    var vec_r = new double[max_ids];
    var vec_g = new double[max_ids];
    var vec_b = new double[max_ids];
    var vec_a = new double[max_ids];
    var var_val = new int[max_ids];
    double out_r = 0.0;
    double out_g = 0.0;
    double out_b = 0.0;
    double out_a = 1.0;

    int total_words = sz / 4;
    int wi = 5;
    int insn_count = 0;
    while (wi < total_words) {
        uint32 hdr = read_u32_le (buf, wi);
        int wc = (int) (hdr >> 16);
        int opc = (int) (hdr & 0xFFFF);
        if (wc <= 0 || wi + wc > total_words)
            break;
        insn_count = insn_count + 1;

        if (opc == 43 && wc >= 4) { // OpConstant (f32 or i32)
            uint32 res = read_u32_le (buf, wi + 2);
            uint32 raw = read_u32_le (buf, wi + 3);
            fvals[(int) res] = f32_bits_to_double (raw);
        } else if (opc == 129 && wc >= 5) { // OpFAdd
            int res = (int) read_u32_le (buf, wi + 2);
            int a = (int) read_u32_le (buf, wi + 3);
            int b = (int) read_u32_le (buf, wi + 4);
            fvals[res] = fvals[a] + fvals[b];
        } else if (opc == 131 && wc >= 5) { // OpFSub
            int res = (int) read_u32_le (buf, wi + 2);
            int a = (int) read_u32_le (buf, wi + 3);
            int b = (int) read_u32_le (buf, wi + 4);
            fvals[res] = fvals[a] - fvals[b];
        } else if (opc == 133 && wc >= 5) { // OpFMul
            int res = (int) read_u32_le (buf, wi + 2);
            int a = (int) read_u32_le (buf, wi + 3);
            int b = (int) read_u32_le (buf, wi + 4);
            fvals[res] = fvals[a] * fvals[b];
        } else if (opc == 136 && wc >= 5) { // OpFDiv
            int res = (int) read_u32_le (buf, wi + 2);
            int a = (int) read_u32_le (buf, wi + 3);
            int b = (int) read_u32_le (buf, wi + 4);
            fvals[res] = (fvals[b] != 0.0) ? (fvals[a] / fvals[b]) : 0.0;
        } else if (opc == 80 && wc >= 7) { // OpCompositeConstruct vec4
            int res = (int) read_u32_le (buf, wi + 2);
            vec_r[res] = fvals[(int) read_u32_le (buf, wi + 3)];
            vec_g[res] = fvals[(int) read_u32_le (buf, wi + 4)];
            vec_b[res] = fvals[(int) read_u32_le (buf, wi + 5)];
            vec_a[res] = fvals[(int) read_u32_le (buf, wi + 6)];
        } else if (opc == 62 && wc >= 3) { // OpStore ptr, obj
            int ptr = (int) read_u32_le (buf, wi + 1);
            int obj = (int) read_u32_le (buf, wi + 2);
            var_val[ptr] = obj;
            fvals[ptr] = fvals[obj];
            out_r = vec_r[obj];
            out_g = vec_g[obj];
            out_b = vec_b[obj];
            out_a = vec_a[obj];
        } else if (opc == 61 && wc >= 4) { // OpLoad ty, res, ptr
            int res = (int) read_u32_le (buf, wi + 2);
            int ptr = (int) read_u32_le (buf, wi + 3);
            fvals[res] = fvals[ptr];
        }
        wi = wi + wc;
    }

    int ir = (int) (out_r * 255.0);
    int ig = (int) (out_g * 255.0);
    int ib = (int) (out_b * 255.0);
    print (@"spv_demo: $spv_name words=$total_words insns=$insn_count bound=$bound rgb=($ir,$ig,$ib)\n");

    var win = Display.open_window (800, 600);
    if (win == null)
        return 1;
    var cr = win.create_cairo_context ();

    th_running = 1;
    int worker_tid = once ? -1 : Sys.sys (27, addr_orbit_worker (), 0, 0);

    int frame = 0;
    int last_tick = -1;
    while (true) {
        int ticks = Sys.ticks ();
        if (ticks != last_tick) {
            last_tick = ticks;
            frame = frame + 1;

            double pulse = (double) th_pulse_milli / 1000.0;
            int sat_x = th_sat_x;
            int sat_y = th_sat_y;

            double pr = out_r * pulse;
            double pg = out_g * pulse;
            double pb = out_b * pulse;

            cr.set_source_rgb (0.04, 0.06, 0.10);
            cr.paint ();

            cr.set_source_rgb (0.09, 0.13, 0.20);
            cr.rectangle (0, 0, 800, 36);
            cr.fill ();
            cr.set_source_rgb (0.22, 0.74, 0.97);
            cr.set_font_size (16);
            cr.move_to (16, 12);
            cr.show_text ("PLANETOS SPIR-V 1.0 SHADER RUNNER");

            cr.set_source_rgb (0.08, 0.11, 0.17);
            cr.rectangle (70, 80, 660, 440);
            cr.fill ();
            cr.set_line_width (2);
            cr.set_source_rgba (pr, pg, pb, 1.0);
            cr.rectangle (70, 80, 660, 440);
            cr.stroke ();

            // Pulsing shaded planet using the exact RGBA evaluated from frag.spv
            cr.set_source_rgba (pr, pg, pb, out_a);
            cr.arc (540, 300, 92, 0, 6.28);
            cr.fill ();
            cr.set_line_width (3);
            cr.set_source_rgb (0.96, 0.62, 0.04);
            cr.arc (540, 300, 124, 0, 6.28);
            cr.stroke ();

            // Orbiting moon
            cr.set_source_rgb (0.98, 0.80, 0.20);
            cr.arc (sat_x, sat_y, 10, 0, 6.28);
            cr.fill ();

            cr.set_source_rgb (0.97, 0.98, 0.99);
            cr.set_font_size (24);
            cr.move_to (108, 130);
            cr.show_text ("SPIR-V SHADER");

            cr.set_source_rgb (0.60, 0.66, 0.74);
            cr.set_font_size (16);
            cr.move_to (108, 195);
            cr.show_text (@"FILE: $spv_name");
            cr.move_to (108, 230);
            cr.show_text (@"WORDS: $total_words  INSNS: $insn_count");
            cr.move_to (108, 265);
            cr.show_text (@"SSA BOUND: $bound");
            cr.move_to (108, 305);
            cr.set_source_rgba (pr, pg, pb, 1.0);
            cr.show_text (@"FRAG COLOR: ($ir, $ig, $ib)");
            cr.move_to (108, 345);
            cr.set_source_rgb (0.96, 0.62, 0.04);
            cr.show_text (@"FRAME: $frame  TID: $worker_tid");
            cr.move_to (108, 460);
            cr.set_source_rgb (0.22, 0.74, 0.97);
            cr.show_text ("PRESS Q TO RETURN TO SHELL");

            win.present ();
            if (once)
                break;
        }

        var ev = win.poll_event ();
        if (ev.type == EventType.KEY_PRESS) {
            if (ev.keyval == 'q' || ev.keyval == 'Q' || ev.keyval == 'x' || ev.keyval == 'X' || ev.keyval == 27)
                break;
        } else {
            Sys.yield_cpu ();
        }
    }

    th_running = 0;
    if (worker_tid > 0)
        Sys.wait (worker_tid);
    win.close ();
    return 0;
}
