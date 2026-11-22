// Pure-Vala SVG path parser and flattener for the GTK4-style Gsk.Path surface.
//
// Gtk4 exposes gsk_path_parse() for the SVG path grammar; this is the same
// entry point for PlanetOS, without an XML or SVG dependency. It accepts the
// command subset the desktop actually needs (M/L/H/V/C/S/Q/T/A/Z, absolute and
// relative) and emits a set of polylines that Cairo can fill.
//
// Arcs are flattened with a quadratic bulge computed from the chord and the
// radius. That is exact enough for small radii (the cursor's 1px corners) and
// keeps the parser free of libm: the dialect has no sin/cos/atan2. Large-arc
// flags fall back to the chord.

using Cairo;

namespace Gsk {

    public class Path : Object {
        private const int MAX_POINTS = 65536;
        private const int MAX_CONTOURS = 4096;

        private const int CH_M = 77;
        private const int CH_L = 76;
        private const int CH_H = 72;
        private const int CH_V = 86;
        private const int CH_C = 67;
        private const int CH_S = 83;
        private const int CH_Q = 81;
        private const int CH_T = 84;
        private const int CH_A = 65;
        private const int CH_Z = 90;

        private string src = "";
        private int pos = 0;
        private int len = 0;

        private double[] xs = new double[64];
        private double[] ys = new double[64];
        private int[] starts = new int[16];
        private int n = 0;
        private int contours = 0;

        private double cur_x = 0;
        private double cur_y = 0;
        private double sub_x = 0;
        private double sub_y = 0;
        private double last_c2x = 0;
        private double last_c2y = 0;
        private double last_qx = 0;
        private double last_qy = 0;
        private int last_cmd = 0;

        public double first_x { get; private set; }
        public double first_y { get; private set; }
        public double min_x { get; private set; }
        public double min_y { get; private set; }
        public double max_x { get; private set; }
        public double max_y { get; private set; }

        public static Path? parse (string d) {
            if (d.length == 0)
                return null;
            var p = new Path ();
            p.src = d;
            p.len = d.length;
            p.run ();
            if (p.contours == 0 || p.n < 3)
                return null;
            p.first_x = p.xs[p.starts[0]];
            p.first_y = p.ys[p.starts[0]];
            return p;
        }

        public int point_count () {
            return n;
        }

        public int contour_count () {
            return contours;
        }

        public void fill (Context cr) {
            if (contours <= 0 || n <= 0)
                return;
            for (int ci = 0; ci < contours; ci++) {
                int s = starts[ci];
                int e = (ci + 1 < contours) ? starts[ci + 1] : n;
                if (e > s)
                    cr.fill_polygon_range (xs, ys, s, e - s);
            }
        }

        public void fill_translated (Context cr, double dx, double dy) {
            if (contours <= 0 || n <= 0)
                return;
            if (dx == 0 && dy == 0) {
                fill (cr);
                return;
            }
            for (int i = 0; i < n; i++) {
                xs[i] = xs[i] + dx;
                ys[i] = ys[i] + dy;
            }
            fill (cr);
            for (int i = 0; i < n; i++) {
                xs[i] = xs[i] - dx;
                ys[i] = ys[i] - dy;
            }
        }

        private void ensure (int extra) {
            if (n + extra <= xs.length)
                return;
            int cap = xs.length;
            while (cap < n + extra && cap < MAX_POINTS)
                cap = cap * 2;
            if (cap > MAX_POINTS)
                cap = MAX_POINTS;
            if (cap <= xs.length)
                return;
            var nx = new double[cap];
            var ny = new double[cap];
            for (int i = 0; i < n; i++) {
                nx[i] = xs[i];
                ny[i] = ys[i];
            }
            xs = nx;
            ys = ny;
        }

        private void begin_contour (double x, double y) {
            if (contours >= MAX_CONTOURS || n >= MAX_POINTS)
                return;
            if (contours >= starts.length) {
                int ncap = starts.length * 2;
                if (ncap > MAX_CONTOURS)
                    ncap = MAX_CONTOURS;
                var ns = new int[ncap];
                for (int i = 0; i < contours; i++)
                    ns[i] = starts[i];
                starts = ns;
            }
            starts[contours] = n;
            contours++;
            add_point (x, y);
        }

        private void add_point (double x, double y) {
            if (n >= MAX_POINTS)
                return;
            ensure (1);
            if (n >= xs.length)
                return;
            if (n == 0) {
                min_x = x;
                max_x = x;
                min_y = y;
                max_y = y;
            } else {
                if (x < min_x) min_x = x;
                if (x > max_x) max_x = x;
                if (y < min_y) min_y = y;
                if (y > max_y) max_y = y;
            }
            xs[n] = x;
            ys[n] = y;
            n++;
        }

        [AsmBody(@"
            # hw_fma(a in xmm0, b in xmm1, c in xmm2) -> vfmadd213sd (a * b + c)
            .byte 0xc4, 0xe2, 0xf1, 0xa9, 0xc2
            ret
        ")]
        private static extern double hw_fma (double a, double b, double c);

        private bool bezier_init = false;
        private double[] cubic_a = new double[12];
        private double[] cubic_b = new double[12];
        private double[] cubic_c = new double[12];
        private double[] cubic_d = new double[12];
        private double[] quad_a = new double[10];
        private double[] quad_b = new double[10];
        private double[] quad_c = new double[10];

        private void init_bezier_tables () {
            if (bezier_init)
                return;
            bezier_init = true;
            for (int i = 0; i < 12; i++) {
                double t = (double) (i + 1) / 12.0;
                double u = 1.0 - t;
                cubic_a[i] = u * u * u;
                cubic_b[i] = 3.0 * u * u * t;
                cubic_c[i] = 3.0 * u * t * t;
                cubic_d[i] = t * t * t;
            }
            for (int i = 0; i < 10; i++) {
                double t = (double) (i + 1) / 10.0;
                double u = 1.0 - t;
                quad_a[i] = u * u;
                quad_b[i] = 2.0 * u * t;
                quad_c[i] = t * t;
            }
        }

        private static double my_sqrt (double v) {
            if (v <= 0)
                return 0;
            return Math.sqrt (v);
        }

        private void skip_sep () {
            while (pos < len) {
                int c = (int) src[pos];
                if (c == 32 || c == 9 || c == 10 || c == 13 || c == 44)
                    pos++;
                else
                    break;
            }
        }

        private double num () {
            skip_sep ();
            int start = pos;
            int c = (pos < len) ? (int) src[pos] : 0;
            if (c == 43 || c == 45)
                pos++;
            while (pos < len) {
                c = (int) src[pos];
                if (c >= 48 && c <= 57) pos++;
                else break;
            }
            if (pos < len && (int) src[pos] == 46) {
                pos++;
                while (pos < len) {
                    c = (int) src[pos];
                    if (c >= 48 && c <= 57) pos++;
                    else break;
                }
            }
            if (pos < len && ((int) src[pos] == 101 || (int) src[pos] == 69)) {
                pos++;
                c = (pos < len) ? (int) src[pos] : 0;
                if (c == 43 || c == 45)
                    pos++;
                while (pos < len) {
                    c = (int) src[pos];
                    if (c >= 48 && c <= 57) pos++;
                    else break;
                }
            }
            if (pos <= start)
                return 0;
            string t = src[start:pos];
            if (t.length > 0 && (int) t[0] == 43)
                t = t[1:t.length];
            if (t.length == 0 || t == "-" || t == ".")
                return 0;
            return double.parse (t);
        }

        private static bool is_cmd (int c) {
            return (c == CH_M || c == CH_L || c == CH_H || c == CH_V
                    || c == CH_C || c == CH_S || c == CH_Q || c == CH_T
                    || c == CH_A || c == CH_Z
                    || c == CH_M + 32 || c == CH_L + 32 || c == CH_H + 32
                    || c == CH_V + 32 || c == CH_C + 32 || c == CH_S + 32
                    || c == CH_Q + 32 || c == CH_T + 32 || c == CH_A + 32
                    || c == CH_Z + 32);
        }

        private static bool is_upper (int c) {
            return c >= 65 && c <= 90;
        }

        private void run () {
            int cmd = 0;
            while (true) {
                skip_sep ();
                if (pos >= len)
                    break;
                int iter_start = pos;
                int c = (int) src[pos];
                if (is_cmd (c)) {
                    cmd = c;
                    pos++;
                } else if (cmd == 0) {
                    break;
                }
                bool rel = !is_upper (cmd);
                int up = is_upper (cmd) ? cmd : cmd - 32;

                if (up == CH_Z) {
                    cur_x = sub_x;
                    cur_y = sub_y;
                    last_cmd = CH_Z;
                    continue;
                }
                if (up == CH_M) {
                    double x = num ();
                    double y = num ();
                    if (pos == iter_start) break;
                    if (rel) { x = cur_x + x; y = cur_y + y; }
                    cur_x = x;
                    cur_y = y;
                    sub_x = x;
                    sub_y = y;
                    begin_contour (x, y);
                    cmd = rel ? CH_L + 32 : CH_L;
                    last_cmd = CH_M;
                    continue;
                }
                if (up == CH_L) {
                    double x = num ();
                    double y = num ();
                    if (pos == iter_start) break;
                    if (rel) { x = cur_x + x; y = cur_y + y; }
                    add_point (x, y);
                    cur_x = x;
                    cur_y = y;
                    last_cmd = CH_L;
                    continue;
                }
                if (up == CH_H) {
                    double x = num ();
                    if (pos == iter_start) break;
                    if (rel) x = cur_x + x;
                    add_point (x, cur_y);
                    cur_x = x;
                    last_cmd = CH_H;
                    continue;
                }
                if (up == CH_V) {
                    double y = num ();
                    if (pos == iter_start) break;
                    if (rel) y = cur_y + y;
                    add_point (cur_x, y);
                    cur_y = y;
                    last_cmd = CH_V;
                    continue;
                }
                if (up == CH_C || up == CH_S) {
                    double c1x = 0;
                    double c1y = 0;
                    if (up == CH_C) {
                        c1x = num (); c1y = num ();
                        if (rel) { c1x = cur_x + c1x; c1y = cur_y + c1y; }
                    } else if (last_cmd == CH_C || last_cmd == CH_S) {
                        c1x = 2.0 * cur_x - last_c2x;
                        c1y = 2.0 * cur_y - last_c2y;
                    } else {
                        c1x = cur_x;
                        c1y = cur_y;
                    }
                    double c2x = num (); double c2y = num ();
                    double ex = num (); double ey = num ();
                    if (pos == iter_start) break;
                    if (rel) {
                        c2x = cur_x + c2x; c2y = cur_y + c2y;
                        ex = cur_x + ex; ey = cur_y + ey;
                    }
                    cubic_to (c1x, c1y, c2x, c2y, ex, ey);
                    last_c2x = c2x;
                    last_c2y = c2y;
                    cur_x = ex;
                    cur_y = ey;
                    last_cmd = up;
                    continue;
                }
                if (up == CH_Q || up == CH_T) {
                    double qx = 0;
                    double qy = 0;
                    if (up == CH_Q) {
                        qx = num (); qy = num ();
                        if (rel) { qx = cur_x + qx; qy = cur_y + qy; }
                    } else if (last_cmd == CH_Q || last_cmd == CH_T) {
                        qx = 2.0 * cur_x - last_qx;
                        qy = 2.0 * cur_y - last_qy;
                    } else {
                        qx = cur_x;
                        qy = cur_y;
                    }
                    double ex = num (); double ey = num ();
                    if (pos == iter_start) break;
                    if (rel) { ex = cur_x + ex; ey = cur_y + ey; }
                    quad_to (qx, qy, ex, ey);
                    last_qx = qx;
                    last_qy = qy;
                    cur_x = ex;
                    cur_y = ey;
                    last_cmd = up;
                    continue;
                }
                if (up == CH_A) {
                    double rx = num ();
                    double ry = num ();
                    num (); // x-axis-rotation: the cursor's arcs are circular
                    double large = num ();
                    double sweep = num ();
                    double ex = num ();
                    double ey = num ();
                    if (pos == iter_start) break;
                    if (rel) { ex = cur_x + ex; ey = cur_y + ey; }
                    arc_to (rx, ry, large != 0, sweep != 0, ex, ey);
                    cur_x = ex;
                    cur_y = ey;
                    last_cmd = CH_A;
                    continue;
                }
                break;
            }
        }

        private void cubic_to (double c1x, double c1y, double c2x, double c2y, double ex, double ey) {
            init_bezier_tables ();
            double x0 = cur_x;
            double y0 = cur_y;
            for (int i = 0; i < 12; i++) {
                double px = cubic_d[i] * ex;
                px = hw_fma (cubic_c[i], c2x, px);
                px = hw_fma (cubic_b[i], c1x, px);
                px = hw_fma (cubic_a[i], x0, px);
                double py = cubic_d[i] * ey;
                py = hw_fma (cubic_c[i], c2y, py);
                py = hw_fma (cubic_b[i], c1y, py);
                py = hw_fma (cubic_a[i], y0, py);
                add_point (px, py);
            }
        }

        private void quad_to (double qx, double qy, double ex, double ey) {
            init_bezier_tables ();
            double x0 = cur_x;
            double y0 = cur_y;
            for (int i = 0; i < 10; i++) {
                double px = quad_c[i] * ex;
                px = hw_fma (quad_b[i], qx, px);
                px = hw_fma (quad_a[i], x0, px);
                double py = quad_c[i] * ey;
                py = hw_fma (quad_b[i], qy, py);
                py = hw_fma (quad_a[i], y0, py);
                add_point (px, py);
            }
        }

        private void arc_to (double rx, double ry, bool large, bool sweep, double ex, double ey) {
            double dx = ex - cur_x;
            double dy = ey - cur_y;
            double chord2 = hw_fma (dx, dx, dy * dy);
            if (chord2 < 0.000001) {
                add_point (ex, ey);
                return;
            }
            if (large) {
                // A single quadratic cannot stand in for a large-arc segment;
                // keep the endpoint so the outline stays closed.
                add_point (ex, ey);
                return;
            }
            double chord = my_sqrt (chord2);
            double r = (rx + ry) * 0.5;
            if (r < 0) r = -r;
            if (r < chord * 0.5) r = chord * 0.5;
            double half = chord * 0.5;
            double sag = r - my_sqrt (r * r - half * half);
            if (sag < 0) sag = 0;
            double ux = -dy / chord;
            double uy = dx / chord;
            if (sweep) { ux = -ux; uy = -uy; }
            double cx = (cur_x + ex) * 0.5 + ux * 2.0 * sag;
            double cy = (cur_y + ey) * 0.5 + uy * 2.0 * sag;
            quad_to (cx, cy, ex, ey);
        }
    }
}
