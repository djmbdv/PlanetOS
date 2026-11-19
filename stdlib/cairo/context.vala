// Pure-Vala Cairo Context and SSE2 pixel primitives.
using Planet;

namespace Cairo {

    [AsmBody(@"
        # __c_fill32(addr in rdi, val in rsi, count in rdx)
        # Fills 'count' 32-bit ARGB pixels using AVX2 (32B/iter) + 4B tail
        mov %rdx, %rcx
        test %rcx, %rcx
        jz _cf_done
        mov %esi, %eax
        cmp $8, %rcx
        jb _cf_loop
        .byte 0xc5, 0xf9, 0x6e, 0xc6
        .byte 0xc4, 0xe2, 0x7d, 0x58, 0xc0
    _cf_avx:
        cmp $8, %rcx
        jb _cf_tail_vzu
        .byte 0xc5, 0xfe, 0x7f, 0x07
        add $32, %rdi
        sub $8, %rcx
        jmp _cf_avx
    _cf_tail_vzu:
        .byte 0xc5, 0xf8, 0x77
    _cf_loop:
        test %rcx, %rcx
        jz _cf_done
        mov %eax, (%rdi)
        add $4, %rdi
        dec %rcx
        jnz _cf_loop
    _cf_done:
        ret
    ")]
    private extern void __c_fill32 (int addr, int val, int count);

    [AsmBody(@"
        # __c_blit32(dst in rdi, src in rsi, count in rdx)
        # Copies 'count' 32-bit ARGB pixels using AVX2 (32B/iter) + 4B tail
        mov %rdx, %rcx
        test %rcx, %rcx
        jz _cb_done
    _cb_avx:
        cmp $8, %rcx
        jb _cb_tail_vzu
        .byte 0xc5, 0xfe, 0x6f, 0x06
        .byte 0xc5, 0xfe, 0x7f, 0x07
        add $32, %rsi
        add $32, %rdi
        sub $8, %rcx
        jmp _cb_avx
    _cb_tail_vzu:
        .byte 0xc5, 0xf8, 0x77
    _cb_loop:
        test %rcx, %rcx
        jz _cb_done
        mov (%rsi), %eax
        mov %eax, (%rdi)
        add $4, %rsi
        add $4, %rdi
        dec %rcx
        jnz _cb_loop
    _cb_done:
        ret
    ")]
    private extern void __c_blit32 (int dst, int src, int count);

    [AsmBody(@"
        # Escribe un pixel ARGB de 32 bits en la direccion 'addr' (rdi)
        mov %esi, (%rdi)
        ret
    ")]
    private extern void __c_poke32 (int addr, int val);

    [AsmBody(@"
        # Lee un pixel ARGB de 32 bits desde la direccion 'addr' (rdi)
        mov (%rdi), %eax
        ret
    ")]
    private extern int __c_peek32 (int addr);

    public class Context : Object {
        private ImageSurface surf;
        private int src_r = 255;
        private int src_g = 255;
        private int src_b = 255;
        private int src_a = 255;
        private int line_w = 1;

        // Current path state (rect, circle/arc, line, rounded_rect)
        private int path_kind = 0; // 0=none, 1=rect, 2=circle, 3=line, 4=rrect
        private int px = 0;
        private int py = 0;
        private int pw = 0;
        private int ph = 0;
        private int pr = 0;
        private int cur_x = 0;
        private int cur_y = 0;
        private int font_scale = 2;

        // Drawing clip + save/restore stack
        private int clip_x0 = 0;
        private int clip_y0 = 0;
        private int clip_x1 = 0;
        private int clip_y1 = 0;
        private bool clip_on = false;

        private int saved_sp = 0;
        private int[] sv_cx0 = new int[8];
        private int[] sv_cy0 = new int[8];
        private int[] sv_cx1 = new int[8];
        private int[] sv_cy1 = new int[8];
        private bool[] sv_con = new bool[8];
        private int[] sv_sr = new int[8];
        private int[] sv_sg = new int[8];
        private int[] sv_sb = new int[8];
        private int[] sv_sa = new int[8];
        private int[] sv_lw = new int[8];

        public Context (ImageSurface target) {
            surf = target;
        }

        private static int clamp255 (double v) {
            int iv = (int) (v * 255.0);
            if (iv < 0) return 0;
            if (iv > 255) return 255;
            return iv;
        }

        public void set_source_rgb (double r, double g, double b) {
            src_r = clamp255 (r);
            src_g = clamp255 (g);
            src_b = clamp255 (b);
            src_a = 255;
        }

        public void set_source_rgba (double r, double g, double b, double a) {
            src_r = clamp255 (r);
            src_g = clamp255 (g);
            src_b = clamp255 (b);
            src_a = clamp255 (a);
        }

        public void set_line_width (double w) {
            int iw = (int) w;
            line_w = (iw < 1) ? 1 : iw;
        }

        public void select_font_face (string family, int slant, int weight) {}

        public void set_font_size (double sz) {
            int s = (int) (sz / 8.0);
            font_scale = (s < 1) ? 1 : ((s > 4) ? 4 : s);
        }

        private void blend_px (int x, int y, int a) {
            if (a <= 0)
                return;
            if (x < 0 || y < 0 || x >= surf.width || y >= surf.height)
                return;
            if (clip_on && (x < clip_x0 || y < clip_y0 || x >= clip_x1 || y >= clip_y1))
                return;
            int addr = surf.buf_addr + (y * surf.width + x) * 4;
            if (a >= 255) {
                int col = (255 << 24) | (src_r << 16) | (src_g << 8) | src_b;
                __c_poke32 (addr, col);
                return;
            }
            int dst = __c_peek32 (addr);
            int dr = (dst >> 16) & 0xFF;
            int dg = (dst >> 8) & 0xFF;
            int db = dst & 0xFF;
            int ia = 255 - a;
            int rr = ((src_r * a + dr * ia + 128) * 257) >> 16;
            int rg = ((src_g * a + dg * ia + 128) * 257) >> 16;
            int rb = ((src_b * a + db * ia + 128) * 257) >> 16;
            __c_poke32 (addr, (255 << 24) | (rr << 16) | (rg << 8) | rb);
        }

        private void put_px (int x, int y) {
            blend_px (x, y, src_a);
        }

        // Fills a closed polygon with 4x4 supersampling. Cairo's fill covers
        // arbitrary paths; the compat layer only had rect/circle, which is not
        // enough for an SVG path such as the cursor.
        [AsmBody(@"
            # __c_fma(a in xmm0, b in xmm1, c in xmm2) -> vfmadd213sd (a * b + c)
            .byte 0xc4, 0xe2, 0xf1, 0xa9, 0xc2
            ret
        ")]
        private static extern double __c_fma (double a, double b, double c);

        public void fill_polygon_range (double[] xs, double[] ys, int start, int n) {
            if (n < 3 || start < 0 || start + n > xs.length || start + n > ys.length)
                return;
            double min_x = xs[start];
            double max_x = xs[start];
            double min_y = ys[start];
            double max_y = ys[start];
            for (int i = start + 1; i < start + n; i++) {
                if (xs[i] < min_x) min_x = xs[i];
                if (xs[i] > max_x) max_x = xs[i];
                if (ys[i] < min_y) min_y = ys[i];
                if (ys[i] > max_y) max_y = ys[i];
            }
            int x0 = (int) min_x;
            int y0 = (int) min_y;
            int x1 = (int) max_x + 1;
            int y1 = (int) max_y + 1;
            if (min_x < 0) x0 = x0 - 1;
            if (min_y < 0) y0 = y0 - 1;
            if (x0 < 0) x0 = 0;
            if (y0 < 0) y0 = 0;
            if (x1 > surf.width) x1 = surf.width;
            if (y1 > surf.height) y1 = surf.height;
            if (clip_on) {
                if (x0 < clip_x0) x0 = clip_x0;
                if (y0 < clip_y0) y0 = clip_y0;
                if (x1 > clip_x1) x1 = clip_x1;
                if (y1 > clip_y1) y1 = clip_y1;
            }
            if (x1 <= x0 || y1 <= y0)
                return;

            // Precompute non-horizontal edges that overlap [y0, y1).
            var ey_min = new double[n];
            var ey_max = new double[n];
            var ex0 = new double[n];
            var ey0 = new double[n];
            var eslope = new double[n];
            int ec = 0;
            double dy0 = (double) y0;
            double dy1 = (double) y1;
            int j = start + n - 1;
            for (int i = start; i < start + n; i++) {
                double yi = ys[i];
                double yj = ys[j];
                if (yi != yj) {
                    double emin = (yi < yj) ? yi : yj;
                    double emax = (yi > yj) ? yi : yj;
                    if (emax > dy0 && emin < dy1) {
                        ey_min[ec] = emin;
                        ey_max[ec] = emax;
                        ex0[ec] = xs[i];
                        ey0[ec] = yi;
                        eslope[ec] = (xs[j] - xs[i]) / (yj - yi);
                        ec++;
                    }
                }
                j = i;
            }
            if (ec == 0)
                return;

            int rw = x1 - x0;
            var row_hits = new int[rw];
            var row_edges = new int[ec];
            var xcs = new double[ec];

            for (int y = y0; y < y1; y++) {
                double row_top = (double) y;
                double row_bot = row_top + 1.0;
                int rc = 0;
                for (int e = 0; e < ec; e++) {
                    if (ey_min[e] < row_bot && ey_max[e] > row_top) {
                        row_edges[rc] = e;
                        rc++;
                    }
                }
                if (rc == 0)
                    continue;

                for (int k = 0; k < rw; k++)
                    row_hits[k] = 0;

                for (int sy = 0; sy < 4; sy++) {
                    double py = row_top + ((double) sy + 0.5) * 0.25;
                    int nx = 0;
                    for (int ri = 0; ri < rc; ri++) {
                        int e = row_edges[ri];
                        if (ey_min[e] <= py && py < ey_max[e]) {
                            xcs[nx] = __c_fma (py - ey0[e], eslope[e], ex0[e]);
                            nx++;
                        }
                    }
                    if (nx < 2)
                        continue;

                    // Insertion sort intersections (small per-scanline count).
                    for (int a = 1; a < nx; a++) {
                        double key = xcs[a];
                        int b = a - 1;
                        while (b >= 0 && xcs[b] > key) {
                            xcs[b + 1] = xcs[b];
                            b--;
                        }
                        xcs[b + 1] = key;
                    }

                    for (int k = 0; k + 1 < nx; k += 2) {
                        double xa = xcs[k];
                        double xb = xcs[k + 1];
                        if (xb <= (double) x0 || xa >= (double) x1)
                            continue;
                        int p0 = (int) xa;
                        if (xa < 0.0) p0 = p0 - 1;
                        if (p0 < x0) p0 = x0;
                        int p1 = (int) xb + 1;
                        if (p1 > x1) p1 = x1;

                        for (int x = p0; x < p1; x++) {
                            double fx = (double) x;
                            if (fx + 0.125 >= xa && fx + 0.875 < xb) {
                                row_hits[x - x0] += 4;
                            } else {
                                int h = 0;
                                if (fx + 0.125 >= xa && fx + 0.125 < xb) h++;
                                if (fx + 0.375 >= xa && fx + 0.375 < xb) h++;
                                if (fx + 0.625 >= xa && fx + 0.625 < xb) h++;
                                if (fx + 0.875 >= xa && fx + 0.875 < xb) h++;
                                row_hits[x - x0] += h;
                            }
                        }
                    }
                }

                for (int i = 0; i < rw; i++) {
                    int hits = row_hits[i];
                    if (hits > 0)
                        blend_px (x0 + i, y, (src_a * hits + 8) / 16);
                }
            }
        }

        public void fill_polygon (double[] xs, double[] ys, int n) {
            fill_polygon_range (xs, ys, 0, n);
        }

        public void clear () {
            for (int y = 0; y < surf.height; y++)
                __c_fill32 (surf.buf_addr + (y * surf.width) * 4, 0, surf.width);
        }

        // Blits a BGRA byte buffer (the layout the VirtIO-GPU cursor uses).
        public void draw_rgba (uint8[] pix, int w, int h, int dx, int dy) {
            if (w <= 0 || h <= 0 || pix.length < w * h * 4)
                return;
            for (int y = 0; y < h; y++) {
                int ty = dy + y;
                if (ty < 0 || ty >= surf.height)
                    continue;
                if (clip_on && (ty < clip_y0 || ty >= clip_y1))
                    continue;
                for (int x = 0; x < w; x++) {
                    int tx = dx + x;
                    if (tx < 0 || tx >= surf.width)
                        continue;
                    if (clip_on && (tx < clip_x0 || tx >= clip_x1))
                        continue;
                    int off = (y * w + x) * 4;
                    int a = (int) pix[off + 3];
                    if (a == 0)
                        continue;
                    int r = (int) pix[off + 2];
                    int g = (int) pix[off + 1];
                    int b = (int) pix[off + 0];
                    int addr = surf.buf_addr + (ty * surf.width + tx) * 4;
                    if (a >= 255) {
                        __c_poke32 (addr, (255 << 24) | (r << 16) | (g << 8) | b);
                        continue;
                    }
                    int dst = __c_peek32 (addr);
                    int dr = (dst >> 16) & 0xFF;
                    int dg = (dst >> 8) & 0xFF;
                    int db = dst & 0xFF;
                    int ia = 255 - a;
                    int rr = ((r * a + dr * ia + 128) * 257) >> 16;
                    int rg = ((g * a + dg * ia + 128) * 257) >> 16;
                    int rb = ((b * a + db * ia + 128) * 257) >> 16;
                    __c_poke32 (addr, (255 << 24) | (rr << 16) | (rg << 8) | rb);
                }
            }
        }

        public void paint () {
            int x0 = clip_on ? clip_x0 : 0;
            int y0 = clip_on ? clip_y0 : 0;
            int x1 = clip_on ? clip_x1 : surf.width;
            int y1 = clip_on ? clip_y1 : surf.height;
            if (x1 > surf.width) x1 = surf.width;
            if (y1 > surf.height) y1 = surf.height;
            if (x1 <= x0 || y1 <= y0)
                return;
            if (src_a == 255) {
                int col = (255 << 24) | (src_r << 16) | (src_g << 8) | src_b;
                int span = x1 - x0;
                for (int y = y0; y < y1; y++) {
                    __c_fill32 (surf.buf_addr + (y * surf.width + x0) * 4, col, span);
                }
                return;
            }
            for (int y = y0; y < y1; y++) {
                for (int x = x0; x < x1; x++) {
                    put_px (x, y);
                }
            }
        }

        public void clip () {
            if (path_kind != 1) {
                path_kind = 0;
                return;
            }
            int x0 = (px < 0) ? 0 : px;
            int y0 = (py < 0) ? 0 : py;
            int x1 = px + pw;
            int y1 = py + ph;
            if (x1 > surf.width) x1 = surf.width;
            if (y1 > surf.height) y1 = surf.height;
            if (clip_on) {
                if (x0 < clip_x0) x0 = clip_x0;
                if (y0 < clip_y0) y0 = clip_y0;
                if (x1 > clip_x1) x1 = clip_x1;
                if (y1 > clip_y1) y1 = clip_y1;
            }
            clip_x0 = x0;
            clip_y0 = y0;
            clip_x1 = x1;
            clip_y1 = y1;
            clip_on = true;
            path_kind = 0;
        }

        public void reset_clip () {
            clip_on = false;
        }

        public bool has_clip () {
            return clip_on;
        }

        public int clip_left () { return clip_on ? clip_x0 : 0; }
        public int clip_top () { return clip_on ? clip_y0 : 0; }
        public int clip_right () { return clip_on ? clip_x1 : surf.width; }
        public int clip_bottom () { return clip_on ? clip_y1 : surf.height; }

        public int current_x () { return cur_x; }
        public int current_y () { return cur_y; }

        // Reads a pixel back (0xAARRGGBB), for tests and damage bookkeeping.
        public int pixel_at (int x, int y) {
            if (x < 0 || y < 0 || x >= surf.width || y >= surf.height)
                return 0;
            return __c_peek32 (surf.buf_addr + (y * surf.width + x) * 4);
        }

        public void save () {
            if (saved_sp >= 8)
                return;
            sv_cx0[saved_sp] = clip_x0;
            sv_cy0[saved_sp] = clip_y0;
            sv_cx1[saved_sp] = clip_x1;
            sv_cy1[saved_sp] = clip_y1;
            sv_con[saved_sp] = clip_on;
            sv_sr[saved_sp] = src_r;
            sv_sg[saved_sp] = src_g;
            sv_sb[saved_sp] = src_b;
            sv_sa[saved_sp] = src_a;
            sv_lw[saved_sp] = line_w;
            saved_sp++;
        }

        public void restore () {
            if (saved_sp <= 0)
                return;
            saved_sp--;
            clip_x0 = sv_cx0[saved_sp];
            clip_y0 = sv_cy0[saved_sp];
            clip_x1 = sv_cx1[saved_sp];
            clip_y1 = sv_cy1[saved_sp];
            clip_on = sv_con[saved_sp];
            src_r = sv_sr[saved_sp];
            src_g = sv_sg[saved_sp];
            src_b = sv_sb[saved_sp];
            src_a = sv_sa[saved_sp];
            line_w = sv_lw[saved_sp];
        }

        public void rectangle (double x, double y, double w, double h) {
            path_kind = 1;
            px = (int) x;
            py = (int) y;
            pw = (int) w;
            ph = (int) h;
        }

        public void rounded_rectangle (double x, double y, double w, double h, double radius) {
            path_kind = 4;
            px = (int) x;
            py = (int) y;
            pw = (int) w;
            ph = (int) h;
            pr = (int) radius;
            if (pr < 0) pr = 0;
            if (pr * 2 > pw) pr = pw / 2;
            if (pr * 2 > ph) pr = ph / 2;
        }

        public void arc (double xc, double yc, double radius, double a1, double a2) {
            path_kind = 2;
            px = (int) xc;
            py = (int) yc;
            pw = (int) radius;
        }

        public void move_to (double x, double y) {
            cur_x = (int) x;
            cur_y = (int) y;
        }

        public void line_to (double x, double y) {
            path_kind = 3;
            px = cur_x;
            py = cur_y;
            pw = (int) x;
            ph = (int) y;
            cur_x = pw;
            cur_y = ph;
        }

        public void fill () {
            if (path_kind == 1) {
                int x0 = (px < 0) ? 0 : px;
                int y0 = (py < 0) ? 0 : py;
                int x1 = (px + pw > surf.width) ? surf.width : (px + pw);
                int y1 = (py + ph > surf.height) ? surf.height : (py + ph);
                if (clip_on) {
                    if (x0 < clip_x0) x0 = clip_x0;
                    if (y0 < clip_y0) y0 = clip_y0;
                    if (x1 > clip_x1) x1 = clip_x1;
                    if (y1 > clip_y1) y1 = clip_y1;
                }
                if (src_a == 255 && x1 > x0) {
                    int col = (255 << 24) | (src_r << 16) | (src_g << 8) | src_b;
                    int span = x1 - x0;
                    for (int y = y0; y < y1; y++) {
                        __c_fill32 (surf.buf_addr + (y * surf.width + x0) * 4, col, span);
                    }
                } else {
                    for (int y = y0; y < y1; y++) {
                        for (int x = x0; x < x1; x++) {
                            put_px (x, y);
                        }
                    }
                }
            } else if (path_kind == 2) {
                int r = pw;
                int r2 = r * r;
                for (int dy = -r; dy <= r; dy++) {
                    for (int dx = -r; dx <= r; dx++) {
                        if (dx * dx + dy * dy <= r2)
                            put_px (px + dx, py + dy);
                    }
                }
            } else if (path_kind == 4) {
                int r = pr;
                int r2 = r * r;
                int x0 = (px < 0) ? 0 : px;
                int y0 = (py < 0) ? 0 : py;
                int x1 = (px + pw > surf.width) ? surf.width : (px + pw);
                int y1 = (py + ph > surf.height) ? surf.height : (py + ph);
                if (clip_on) {
                    if (x0 < clip_x0) x0 = clip_x0;
                    if (y0 < clip_y0) y0 = clip_y0;
                    if (x1 > clip_x1) x1 = clip_x1;
                    if (y1 > clip_y1) y1 = clip_y1;
                }
                if (x1 > x0 && y1 > y0) {
                    if (src_a == 255) {
                        int col = (255 << 24) | (src_r << 16) | (src_g << 8) | src_b;
                        int mx0 = px + r;
                        int mx1 = px + pw - r;
                        if (mx0 < x0) mx0 = x0;
                        if (mx1 > x1) mx1 = x1;
                        for (int y = y0; y < y1; y++) {
                            int dy = 0;
                            if (y < py + r) dy = (py + r) - y;
                            else if (y >= py + ph - r) dy = y - (py + ph - r - 1);
                            if (dy == 0) {
                                __c_fill32 (surf.buf_addr + (y * surf.width + x0) * 4, col, x1 - x0);
                            } else {
                                if (mx1 > mx0)
                                    __c_fill32 (surf.buf_addr + (y * surf.width + mx0) * 4, col, mx1 - mx0);
                                for (int x = x0; x < mx0; x++) {
                                    int dx = (px + r) - x;
                                    if (dx * dx + dy * dy <= r2)
                                        __c_poke32 (surf.buf_addr + (y * surf.width + x) * 4, col);
                                }
                                for (int x = mx1; x < x1; x++) {
                                    int dx = x - (px + pw - r - 1);
                                    if (dx * dx + dy * dy <= r2)
                                        __c_poke32 (surf.buf_addr + (y * surf.width + x) * 4, col);
                                }
                            }
                        }
                    } else {
                        for (int y = y0; y < y1; y++) {
                            int dy = 0;
                            if (y < py + r) dy = (py + r) - y;
                            else if (y >= py + ph - r) dy = y - (py + ph - r - 1);
                            for (int x = x0; x < x1; x++) {
                                int dx = 0;
                                if (x < px + r) dx = (px + r) - x;
                                else if (x >= px + pw - r) dx = x - (px + pw - r - 1);
                                if (dx == 0 || dy == 0 || (dx * dx + dy * dy <= r2))
                                    put_px (x, y);
                            }
                        }
                    }
                }
            }
            path_kind = 0;
        }

        public void stroke () {
            if (path_kind == 1) {
                for (int t = 0; t < line_w; t++) {
                    for (int x = px; x < px + pw; x++) {
                        put_px (x, py + t);
                        put_px (x, py + ph - 1 - t);
                    }
                    for (int y = py; y < py + ph; y++) {
                        put_px (px + t, y);
                        put_px (px + pw - 1 - t, y);
                    }
                }
            } else if (path_kind == 2) {
                int r = pw;
                int r_out = r * r;
                int r_in = (r - line_w) * (r - line_w);
                if (r - line_w < 0) r_in = 0;
                for (int dy = -r; dy <= r; dy++) {
                    for (int dx = -r; dx <= r; dx++) {
                        int d2 = dx * dx + dy * dy;
                        if (d2 <= r_out && d2 >= r_in)
                            put_px (px + dx, py + dy);
                    }
                }
            } else if (path_kind == 3) {
                int x0 = px; int y0 = py;
                int x1 = pw; int y1 = ph;
                int dx = (x1 > x0) ? (x1 - x0) : (x0 - x1);
                int dy = (y1 > y0) ? (y1 - y0) : (y0 - y1);
                int sx = (x0 < x1) ? 1 : -1;
                int sy = (y0 < y1) ? 1 : -1;
                int err = dx - dy;
                while (true) {
                    for (int ty = 0; ty < line_w; ty++)
                        for (int tx = 0; tx < line_w; tx++)
                            put_px (x0 + tx, y0 + ty);
                    if (x0 == x1 && y0 == y1) break;
                    int e2 = 2 * err;
                    if (e2 > -dy) { err = err - dy; x0 = x0 + sx; }
                    if (e2 < dx)  { err = err + dx; y0 = y0 + sy; }
                }
            } else if (path_kind == 4) {
                int r = pr;
                int r_out = r * r;
                int inner = (r > line_w) ? (r - line_w) : 0;
                int r_in = inner * inner - (r > 1 ? (r - 1) : 0);
                if (r_in < 0) r_in = 0;
                for (int y = py; y < py + ph; y++) {
                    int dy = 0;
                    if (y < py + r) dy = (py + r) - y;
                    else if (y >= py + ph - r) dy = y - (py + ph - r - 1);
                    bool in_y_edge = (y < py + line_w || y >= py + ph - line_w);
                    for (int x = px; x < px + pw; x++) {
                        int dx = 0;
                        if (x < px + r) dx = (px + r) - x;
                        else if (x >= px + pw - r) dx = x - (px + pw - r - 1);
                        if (dx > 0 && dy > 0) {
                            int d2 = dx * dx + dy * dy;
                            if (d2 <= r_out && d2 >= r_in)
                                put_px (x, y);
                        } else if (in_y_edge || x < px + line_w || x >= px + pw - line_w) {
                            put_px (x, y);
                        }
                    }
                }
            }
            path_kind = 0;
        }

        public void fill_gradient_v (double x, double y, double w, double h,
                                     double r0, double g0, double b0,
                                     double r1, double g1, double b1) {
            int ix = (int) x;
            int iy = (int) y;
            int iw = (int) w;
            int ih = (int) h;
            if (iw <= 0 || ih <= 0)
                return;
            int saved_r = src_r;
            int saved_g = src_g;
            int saved_b = src_b;
            int saved_a = src_a;
            src_a = 255;
            for (int row = 0; row < ih; row++) {
                double t = (ih > 1) ? ((double) row / (double) (ih - 1)) : 0.0;
                src_r = clamp255 (r0 + (r1 - r0) * t);
                src_g = clamp255 (g0 + (g1 - g0) * t);
                src_b = clamp255 (b0 + (b1 - b0) * t);
                for (int col = 0; col < iw; col++) {
                    put_px (ix + col, iy + row);
                }
            }
            src_r = saved_r;
            src_g = saved_g;
            src_b = saved_b;
            src_a = saved_a;
        }

        public void blit_alpha_mask (uint8[] mask, int mw, int mh, int dx, int dy) {
            if (mw <= 0 || mh <= 0 || src_a == 0)
                return;
            int saved_a = src_a;
            for (int y = 0; y < mh; y++) {
                int py0 = dy + y;
                if (py0 < 0 || py0 >= surf.height)
                    continue;
                if (clip_on && (py0 < clip_y0 || py0 >= clip_y1))
                    continue;
                for (int x = 0; x < mw; x++) {
                    int a = (int) mask[y * mw + x];
                    if (a == 0)
                        continue;
                    src_a = (saved_a * a) / 255;
                    if (src_a > 0)
                        put_px (dx + x, py0);
                }
            }
            src_a = saved_a;
        }

        // Compact 5x7 bitmap glyph rows (encoded as 7 rows of 5 bits) for ASCII 32..126
        private static int glyph_row (int ch, int row) {
            if (ch == ' ') return 0;
            if (ch == '!') return (row == 0 || row == 1 || row == 2 || row == 3 || row == 5) ? 4 : 0;
            if (ch == '%') return (row == 1) ? 25 : ((row == 2) ? 2 : ((row == 3) ? 4 : ((row == 4) ? 8 : ((row == 5) ? 19 : 0))));
            if (ch == '.') return (row == 6) ? 4 : 0;
            if (ch == ',') return (row == 5) ? 4 : ((row == 6) ? 8 : 0);
            if (ch == ':') return (row == 2 || row == 5) ? 4 : 0;
            if (ch == '-') return (row == 3) ? 14 : 0;
            if (ch == '+') return (row == 3) ? 14 : ((row >= 1 && row <= 5) ? 4 : 0);
            if (ch == '=') return (row == 2 || row == 4) ? 14 : 0;
            if (ch == '/') return 1 << (row < 5 ? (4 - row) : 0);
            if (ch == '(') return (row == 0 || row == 6) ? 2 : ((row == 1 || row == 5) ? 4 : 8);
            if (ch == ')') return (row == 0 || row == 6) ? 8 : ((row == 1 || row == 5) ? 4 : 2);
            if (ch >= '0' && ch <= '9') {
                if (ch == '0') return (row == 0 || row == 6) ? 14 : 17;
                if (ch == '1') return (row == 0) ? 4 : ((row == 1) ? 12 : ((row == 6) ? 14 : 4));
                if (ch == '2') return (row == 0 || row == 3 || row == 6) ? 14 : ((row < 3) ? 1 : 16);
                if (ch == '3') return (row == 0 || row == 3 || row == 6) ? 14 : 1;
                if (ch == '4') return (row == 3) ? 31 : ((row < 3) ? 17 : 1);
                if (ch == '5') return (row == 0 || row == 3 || row == 6) ? 31 : ((row < 3) ? 16 : 1);
                if (ch == '6') return (row == 0 || row == 3 || row == 6) ? 14 : ((row < 3) ? 16 : 17);
                if (ch == '7') return (row == 0) ? 31 : (1 << (row / 2));
                if (ch == '8') return (row == 0 || row == 3 || row == 6) ? 14 : 17;
                if (ch == '9') return (row == 0 || row == 3 || row == 6) ? 14 : ((row < 3) ? 17 : 1);
            }
            int u = (ch >= 'a' && ch <= 'z') ? (ch - 32) : ch;
            if (u == 'A') return (row == 0) ? 14 : ((row == 3) ? 31 : 17);
            if (u == 'B') return (row == 0 || row == 3 || row == 6) ? 30 : 17;
            if (u == 'C') return (row == 0 || row == 6) ? 14 : 16;
            if (u == 'D') return (row == 0 || row == 6) ? 30 : 17;
            if (u == 'E') return (row == 0 || row == 6) ? 31 : ((row == 3) ? 28 : 16);
            if (u == 'F') return (row == 0) ? 31 : ((row == 3) ? 28 : 16);
            if (u == 'G') return (row == 0 || row == 6) ? 14 : ((row == 3) ? 23 : ((row > 3) ? 17 : 16));
            if (u == 'H') return (row == 3) ? 31 : 17;
            if (u == 'I') return (row == 0 || row == 6) ? 14 : 4;
            if (u == 'J') return (row == 6) ? 14 : ((row > 4) ? 17 : 1);
            if (u == 'K') return (row == 3) ? 24 : ((row == 2 || row == 4) ? 20 : 18);
            if (u == 'L') return (row == 6) ? 31 : 16;
            if (u == 'M') return (row == 1) ? 27 : ((row == 2) ? 21 : 17);
            if (u == 'N') return (row == 1) ? 25 : ((row == 2) ? 21 : ((row == 3) ? 19 : 17));
            if (u == 'O') return (row == 0 || row == 6) ? 14 : 17;
            if (u == 'P') return (row == 0 || row == 3) ? 30 : ((row < 3) ? 17 : 16);
            if (u == 'Q') return (row == 0) ? 14 : ((row == 5) ? 18 : ((row == 6) ? 13 : 17));
            if (u == 'R') return (row == 0 || row == 3) ? 30 : ((row < 3) ? 17 : (16 | (1 << (6 - row))));
            if (u == 'S') return (row == 0 || row == 3 || row == 6) ? 14 : ((row < 3) ? 16 : 1);
            if (u == 'T') return (row == 0) ? 31 : 4;
            if (u == 'U') return (row == 6) ? 14 : 17;
            if (u == 'V') return (row == 6) ? 4 : ((row == 5) ? 10 : 17);
            if (u == 'W') return (row == 5) ? 21 : ((row == 4) ? 21 : 17);
            if (u == 'X') return (row == 3) ? 4 : ((row == 2 || row == 4) ? 10 : 17);
            if (u == 'Y') return (row < 3) ? 17 : ((row == 3) ? 10 : 4);
            if (u == 'Z') return (row == 0 || row == 6) ? 31 : (1 << ((row <= 4) ? (row - 0) : 4));
            return (row == 0 || row == 6) ? 14 : 0;
        }

        public void show_text (string text) {
            show_text_range (text, 0, text.length);
        }

        // Draws at most max_chars glyphs, for text that must stay inside a widget.
        public void show_text_n (string text, int max_chars) {
            show_text_range (text, 0, max_chars);
        }

        // Draws count glyphs starting at start, advancing the current point.
        public void show_text_range (string text, int start, int count) {
            int cx = cur_x;
            int cy = cur_y;
            int s = font_scale;
            int n = count;
            if (start < 0)
                start = 0;
            if (start + n > text.length)
                n = text.length - start;
            if (n < 0)
                n = 0;
            for (int i = 0; i < n; i++) {
                int ch = (int) text[start + i];
                if (ch < 0x80) {
                    for (int r = 0; r < 7; r++) {
                        int bits = glyph_row (ch, r);
                        for (int c = 0; c < 5; c++) {
                            if ((bits & (16 >> c)) != 0) {
                                for (int sy = 0; sy < s; sy++)
                                    for (int sx = 0; sx < s; sx++)
                                        put_px (cx + c * s + sx, cy + r * s + sy);
                            }
                        }
                    }
                    cx = cx + 6 * s;
                }
            }
            cur_x = cx;
        }

        public void blit_surface (ImageSurface src, int dx, int dy, int w, int h) {
            if (surf.buf_addr == 0 || src.buf_addr == 0 || w <= 0 || h <= 0)
                return;
            int bw = (w < src.width) ? w : src.width;
            int bh = (h < src.height) ? h : src.height;
            int x0 = dx;
            int y0 = dy;
            int x1 = dx + bw;
            int y1 = dy + bh;
            if (x0 < 0) x0 = 0;
            if (y0 < 0) y0 = 0;
            if (x1 > surf.width) x1 = surf.width;
            if (y1 > surf.height) y1 = surf.height;
            if (clip_on) {
                if (x0 < clip_x0) x0 = clip_x0;
                if (y0 < clip_y0) y0 = clip_y0;
                if (x1 > clip_x1) x1 = clip_x1;
                if (y1 > clip_y1) y1 = clip_y1;
            }
            int cw = x1 - x0;
            if (cw <= 0 || y1 <= y0)
                return;
            int sx0 = x0 - dx;
            for (int ry = y0; ry < y1; ry++) {
                int sy = ry - dy;
                int dst_row = surf.buf_addr + (ry * surf.width + x0) * 4;
                int src_row = src.buf_addr + (sy * src.width + sx0) * 4;
                __c_blit32 (dst_row, src_row, cw);
            }
        }
    }
}
