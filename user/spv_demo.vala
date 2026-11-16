// SPIR-V 1.0 Shader Loader, Pure-Vala VM Evaluator, and Framebuffer Demo on PlanetOS.

using Cairo;
using Gdk;

[AsmBody(@"
    # __spv_sys(num in rdi, a0 in rsi, a1 in rdx, a2 in rcx) -> syscall PlanetOS via int 0x80
    mov %rdi, %rax
    mov %rsi, %rdi
    mov %rdx, %rsi
    mov %rcx, %rdx
    int $0x80
    ret
")]
private extern int __spv_sys (int num, int a0, int a1, int a2);

[AsmBody(@"
    # __spv_open(path_str in rdi) -> fd
    mov 8(%rdi), %rsi
    add $16, %rdi
    mov $6, %rax
    xor %edx, %edx
    int $0x80
    ret
")]
private extern int __spv_open (string path);

[AsmBody(@"
    # __spv_read_arr(fd in rdi, buf in rsi, count in rdx) -> bytes read
    add $16, %rsi
    mov $7, %rax
    int $0x80
    ret
")]
private extern int __spv_read_arr (int fd, uint8[] buf, int count);

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

int main (string[] args) {
    string spv_name = (args.length > 1 && args[1] != "--once") ? args[1] : "frag.spv";
    bool once = false;
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--once")
            once = true;
    }

    int fd = __spv_open (spv_name);
    if (fd < 0) {
        print (@"spv_demo: cannot open '$spv_name'\n");
        return 1;
    }
    int sz = __spv_sys (9, fd, 0, 0);
    if (sz < 20 || (sz % 4) != 0) {
        __spv_sys (8, fd, 0, 0);
        print ("spv_demo: invalid .spv size\n");
        return 1;
    }
    var buf = new uint8[sz];
    int got = 0;
    while (got < sz) {
        int r = __spv_read_arr (fd, buf, sz - got);
        if (r <= 0) break;
        got = got + r;
    }
    __spv_sys (8, fd, 0, 0);

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

    int frame = 0;
    int last_tick = -1;
    while (true) {
        int ticks = __spv_sys (2, 0, 0, 0);
        if (ticks != last_tick) {
            last_tick = ticks;
            frame = frame + 1;

            // Smooth triangle-wave pulse (0.65 .. 1.0) and orbiting satellite angle
            int phase = (ticks * 3) % 120;
            int tri = (phase < 60) ? phase : (120 - phase);
            double pulse = 0.65 + 0.35 * ((double) tri / 60.0);

            // Approximate sin/cos on 64-step circle using quadratic parabola wave
            int ang = (ticks * 2) & 63;
            int qx = (ang + 16) & 63;
            int sx = (ang < 32) ? ang : (64 - ang);
            int cx = (qx < 32) ? qx : (64 - qx);
            double sin_v = (ang < 32 ? 1.0 : -1.0) * (1.0 - ((double) (sx - 16) * (double) (sx - 16)) / 256.0);
            double cos_v = (qx < 32 ? 1.0 : -1.0) * (1.0 - ((double) (cx - 16) * (double) (cx - 16)) / 256.0);
            int sat_x = 540 + (int) (cos_v * 124.0);
            int sat_y = 300 + (int) (sin_v * 124.0);

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
            cr.show_text (@"FRAME: $frame  TICKS: $ticks");
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
            __spv_sys (10, 0, 0, 0);
        }
    }

    win.close ();
    return 0;
}
