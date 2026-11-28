// Native Vala (planc) port of libschrift (ISC license, Thomas Oltmann).
// TrueType (.ttf) outline parser, quadratic Bezier tessellator, and
// subpixel-coverage scanline rasterizer with zero external dependencies.

namespace Schrift {

    public const int SFT_DOWNWARD_Y = 0x01;

    private const int POINT_IS_ON_CURVE       = 0x01;
    private const int X_CHANGE_IS_SMALL       = 0x02;
    private const int Y_CHANGE_IS_SMALL       = 0x04;
    private const int REPEAT_FLAG             = 0x08;
    private const int X_CHANGE_IS_ZERO        = 0x10;
    private const int X_CHANGE_IS_POSITIVE    = 0x10;
    private const int Y_CHANGE_IS_ZERO        = 0x20;
    private const int Y_CHANGE_IS_POSITIVE    = 0x20;

    private const int OFFSETS_ARE_LARGE       = 0x001;
    private const int ACTUAL_XY_OFFSETS       = 0x002;
    private const int GOT_A_SINGLE_SCALE      = 0x008;
    private const int THERE_ARE_MORE_COMPONENTS = 0x020;
    private const int GOT_AN_X_AND_Y_SCALE    = 0x040;
    private const int GOT_A_SCALE_MATRIX      = 0x080;

    private const int HORIZONTAL_KERNING      = 0x01;
    private const int MINIMUM_KERNING         = 0x02;
    private const int CROSS_STREAM_KERNING    = 0x04;

    public class SftLMetrics : Object {
        public float ascender = 0.0f;
        public float descender = 0.0f;
        public float line_gap = 0.0f;
    }

    public class SftGMetrics : Object {
        public float advance_width = 0.0f;
        public float left_side_bearing = 0.0f;
        public int16 y_offset = 0;
        public int16 min_width = 0;
        public int16 min_height = 0;
    }

    public class SftKerning : Object {
        public float x_shift = 0.0f;
        public float y_shift = 0.0f;
    }

    public class SftImage : Object {
        public uint8[] pixels;
        public int32 width = 0;
        public int32 height = 0;

        public SftImage (int w, int h) {
            width = (int32) w;
            height = (int32) h;
            int n = (w > 0 && h > 0) ? (w * h) : 1;
            pixels = new uint8[n];
        }
    }

    private class SftOutline : Object {
        public float[] px;
        public float[] py;
        public int32 num_points = 0;
        public int32 cap_points = 64;

        public int32[] cbeg;
        public int32[] cend;
        public int32[] cctrl;
        public int32 num_curves = 0;
        public int32 cap_curves = 64;

        public int32[] lbeg;
        public int32[] lend;
        public int32 num_lines = 0;
        public int32 cap_lines = 64;

        public SftOutline () {
            px = new float[64];
            py = new float[64];
            cbeg = new int32[64];
            cend = new int32[64];
            cctrl = new int32[64];
            lbeg = new int32[64];
            lend = new int32[64];
        }

        public bool grow_points () {
            if (cap_points >= 32768)
                return false;
            int32 ncap = cap_points * 2;
            var nx = new float[ncap];
            var ny = new float[ncap];
            for (int i = 0; i < num_points; i++) {
                nx[i] = px[i];
                ny[i] = py[i];
            }
            px = nx;
            py = ny;
            cap_points = ncap;
            return true;
        }

        public bool grow_curves () {
            if (cap_curves >= 32768)
                return false;
            int32 ncap = cap_curves * 2;
            var nb = new int32[ncap];
            var ne = new int32[ncap];
            var nc = new int32[ncap];
            for (int i = 0; i < num_curves; i++) {
                nb[i] = cbeg[i];
                ne[i] = cend[i];
                nc[i] = cctrl[i];
            }
            cbeg = nb;
            cend = ne;
            cctrl = nc;
            cap_curves = ncap;
            return true;
        }

        public bool grow_lines () {
            if (cap_lines >= 32768)
                return false;
            int32 ncap = cap_lines * 2;
            var nb = new int32[ncap];
            var ne = new int32[ncap];
            for (int i = 0; i < num_lines; i++) {
                nb[i] = lbeg[i];
                ne[i] = lend[i];
            }
            lbeg = nb;
            lend = ne;
            cap_lines = ncap;
            return true;
        }

        public int add_point (double x, double y) {
            if (num_points >= cap_points && !grow_points ())
                return -1;
            int idx = (int) num_points++;
            px[idx] = (float) x;
            py[idx] = (float) y;
            return idx;
        }

        public bool add_curve (int b, int e, int c) {
            if (num_curves >= cap_curves && !grow_curves ())
                return false;
            int idx = (int) num_curves++;
            cbeg[idx] = (int32) b;
            cend[idx] = (int32) e;
            cctrl[idx] = (int32) c;
            return true;
        }

        public bool add_line (int b, int e) {
            if (num_lines >= cap_lines && !grow_lines ())
                return false;
            int idx = (int) num_lines++;
            lbeg[idx] = (int32) b;
            lend[idx] = (int32) e;
            return true;
        }
    }

    public class SftFont : Object {
        public uint8[] memory;
        public int size = 0;
        public int units_per_em = 0;
        public int loca_format = 0;
        public int num_long_hmtx = 0;

        public static SftFont? load_mem (uint8[] data, int len = -1) {
            int n = (len >= 0 && len <= data.length) ? len : data.length;
            if (n < 12)
                return null;
            var f = new SftFont ();
            f.memory = data;
            f.size = n;
            if (!f.init_font ())
                return null;
            return f;
        }

        public bool is_safe_offset (int offset, int margin) {
            if (offset < 0 || margin < 0 || offset > size)
                return false;
            return (size - offset) >= margin;
        }

        public int getu8 (int offset) {
            return (int) memory[offset];
        }

        public int geti8 (int offset) {
            int v = (int) memory[offset];
            return (v >= 128) ? (v - 256) : v;
        }

        public int getu16 (int offset) {
            return ((int) memory[offset] << 8) | (int) memory[offset + 1];
        }

        public int geti16 (int offset) {
            int v = getu16 (offset);
            return (v >= 32768) ? (v - 65536) : v;
        }

        public int getu32 (int offset) {
            return ((int) memory[offset] << 24)
                 | ((int) memory[offset + 1] << 16)
                 | ((int) memory[offset + 2] << 8)
                 | (int) memory[offset + 3];
        }

        private static int cmp_tag (uint8[] mem, int off, string tag) {
            for (int i = 0; i < 4; i++) {
                int a = (int) tag[i];
                int b = (int) mem[off + i];
                if (a != b)
                    return a - b;
            }
            return 0;
        }

        public int gettable (string tag) {
            int num_tables = getu16 (4);
            if (!is_safe_offset (12, num_tables * 16))
                return -1;
            int low = 0;
            int high = num_tables - 1;
            while (low <= high) {
                int mid = low + (high - low) / 2;
                int off = 12 + mid * 16;
                int c = cmp_tag (memory, off, tag);
                if (c == 0)
                    return getu32 (off + 8);
                if (c < 0)
                    high = mid - 1;
                else
                    low = mid + 1;
            }
            return -1;
        }

        private bool init_font () {
            if (!is_safe_offset (0, 12))
                return false;
            int sfnt_version = getu32 (0);
            if (sfnt_version != 0x00010000 && sfnt_version != 0x4F54544F && sfnt_version != 0x74727565)
                return false;

            int head = gettable ("head");
            if (head < 0 || !is_safe_offset (head, 54))
                return false;
            units_per_em = getu16 (head + 18);
            if (units_per_em <= 0)
                return false;
            loca_format = geti16 (head + 50);

            int hhea = gettable ("hhea");
            if (hhea < 0 || !is_safe_offset (hhea, 36))
                return false;
            num_long_hmtx = getu16 (hhea + 34);
            return true;
        }
    }

    public class Sft : Object {
        public SftFont? font = null;
        public double x_scale = 16.0;
        public double y_scale = 16.0;
        public double x_offset = 0.0;
        public double y_offset = 0.0;
        public int flags = 0;

        private static int fast_floor (double x) {
            int i = (int) x;
            return (x < (double) i) ? (i - 1) : i;
        }

        private static int fast_ceil (double x) {
            int i = (int) x;
            return (x > (double) i) ? (i + 1) : i;
        }

        private static double d_abs (double x) {
            return (x < 0.0) ? -x : x;
        }

        private static double d_min (double a, double b) {
            return (a < b) ? a : b;
        }

        private static int i_sign (double x) {
            if (x > 0.0) return 1;
            if (x < 0.0) return -1;
            return 0;
        }

        public int lmetrics (SftLMetrics metrics) {
            metrics.ascender = 0.0f;
            metrics.descender = 0.0f;
            metrics.line_gap = 0.0f;
            if (font == null)
                return -1;
            var f = (SftFont) font;
            int hhea = f.gettable ("hhea");
            if (hhea < 0 || !f.is_safe_offset (hhea, 36))
                return -1;
            double factor = y_scale / (double) f.units_per_em;
            metrics.ascender  = (float) ((double) f.geti16 (hhea + 4) * factor);
            metrics.descender = (float) ((double) f.geti16 (hhea + 6) * factor);
            metrics.line_gap  = (float) ((double) f.geti16 (hhea + 8) * factor);
            return 0;
        }

        private static int cmap_fmt4 (SftFont f, int table, int char_code, out int glyph) {
            glyph = 0;
            if (char_code > 0xFFFF)
                return 0;
            if (!f.is_safe_offset (table, 8))
                return -1;
            int seg_count_x2 = f.getu16 (table);
            if ((seg_count_x2 & 1) != 0 || seg_count_x2 == 0)
                return -1;
            int end_codes = table + 8;
            int start_codes = end_codes + seg_count_x2 + 2;
            int id_deltas = start_codes + seg_count_x2;
            int id_range_offsets = id_deltas + seg_count_x2;
            if (!f.is_safe_offset (id_range_offsets, seg_count_x2))
                return -1;

            int num_segs = seg_count_x2 / 2;
            int low = 0;
            int high = num_segs - 1;
            while (low < high) {
                int mid = low + (high - low) / 2;
                int ec = f.getu16 (end_codes + mid * 2);
                if (ec < char_code)
                    low = mid + 1;
                else
                    high = mid;
            }
            int seg_idx_x2 = low * 2;
            int start_code = f.getu16 (start_codes + seg_idx_x2);
            if (start_code > char_code)
                return 0;
            int id_delta = f.getu16 (id_deltas + seg_idx_x2);
            int id_range_offset = f.getu16 (id_range_offsets + seg_idx_x2);
            if (id_range_offset == 0) {
                glyph = (char_code + id_delta) & 0xFFFF;
                return 0;
            }
            int id_offset = id_range_offsets + seg_idx_x2 + id_range_offset + 2 * (char_code - start_code);
            if (!f.is_safe_offset (id_offset, 2))
                return -1;
            int id = f.getu16 (id_offset);
            glyph = (id != 0) ? ((id + id_delta) & 0xFFFF) : 0;
            return 0;
        }

        private static int cmap_fmt6 (SftFont f, int table, int char_code, out int glyph) {
            glyph = 0;
            if (char_code > 0xFFFF)
                return 0;
            if (!f.is_safe_offset (table, 4))
                return -1;
            int first_code = f.getu16 (table);
            int entry_count = f.getu16 (table + 2);
            if (!f.is_safe_offset (table, 4 + 2 * entry_count))
                return -1;
            if (char_code < first_code)
                return -1;
            int idx = char_code - first_code;
            if (idx >= entry_count)
                return -1;
            glyph = f.getu16 (table + 4 + 2 * idx);
            return 0;
        }

        private static int cmap_fmt12 (SftFont f, int table, int char_code, out int glyph) {
            glyph = 0;
            if (!f.is_safe_offset (table, 16))
                return -1;
            int len = f.getu32 (table + 4);
            if (len < 16 || !f.is_safe_offset (table, len))
                return -1;
            int num_entries = f.getu32 (table + 12);
            if (num_entries < 0 || num_entries > (len - 16) / 12)
                return -1;
            for (int i = 0; i < num_entries; i++) {
                int base_off = table + 16 + i * 12;
                int first_code = f.getu32 (base_off);
                int last_code = f.getu32 (base_off + 4);
                if (char_code < first_code || char_code > last_code)
                    continue;
                int glyph_offset = f.getu32 (base_off + 8);
                glyph = (char_code - first_code) + glyph_offset;
                return 0;
            }
            return 0;
        }

        public int lookup (int codepoint, out int glyph) {
            glyph = 0;
            if (font == null)
                return -1;
            var f = (SftFont) font;
            int cmap = f.gettable ("cmap");
            if (cmap < 0 || !f.is_safe_offset (cmap, 4))
                return -1;
            int num_entries = f.getu16 (cmap + 2);
            if (!f.is_safe_offset (cmap, 4 + num_entries * 8))
                return -1;

            for (int idx = 0; idx < num_entries; idx++) {
                int entry = cmap + 4 + idx * 8;
                int pid = f.getu16 (entry);
                int eid = f.getu16 (entry + 2);
                if ((pid == 0 && eid == 4) || (pid == 3 && eid == 10)) {
                    int table = cmap + f.getu32 (entry + 4);
                    if (!f.is_safe_offset (table, 8))
                        return -1;
                    if (f.getu16 (table) == 12)
                        return cmap_fmt12 (f, table, codepoint, out glyph);
                }
            }

            for (int idx = 0; idx < num_entries; idx++) {
                int entry = cmap + 4 + idx * 8;
                int pid = f.getu16 (entry);
                int eid = f.getu16 (entry + 2);
                if ((pid == 0 && eid == 3) || (pid == 3 && eid == 1)) {
                    int table = cmap + f.getu32 (entry + 4);
                    if (!f.is_safe_offset (table, 6))
                        return -1;
                    int fmt = f.getu16 (table);
                    if (fmt == 4)
                        return cmap_fmt4 (f, table + 6, codepoint, out glyph);
                    if (fmt == 6)
                        return cmap_fmt6 (f, table + 6, codepoint, out glyph);
                }
            }
            return -1;
        }

        private static (int, int) hor_metrics! (SftFont f, int glyph) {
            int hmtx = f.gettable ("hmtx");
            if (hmtx < 0)
                throws -1;
            if (glyph < f.num_long_hmtx) {
                int offset = hmtx + 4 * glyph;
                if (!f.is_safe_offset (offset, 4))
                    throws -1;
                return (f.getu16 (offset), f.geti16 (offset + 2));
            } else {
                int boundary = hmtx + 4 * f.num_long_hmtx;
                if (boundary < 4)
                    throws -1;
                int offset = boundary - 4;
                if (!f.is_safe_offset (offset, 4))
                    throws -1;
                int adv = f.getu16 (offset);
                offset = boundary + 2 * (glyph - f.num_long_hmtx);
                if (!f.is_safe_offset (offset, 2))
                    throws -1;
                return (adv, f.geti16 (offset));
            }
        }

        private static int outline_offset! (SftFont f, int glyph) {
            int loca = f.gettable ("loca");
            int glyf = f.gettable ("glyf");
            if (loca < 0 || glyf < 0)
                throws -1;
            int cur_off = 0;
            int next_off = 0;
            if (f.loca_format == 0) {
                int b = loca + 2 * glyph;
                if (!f.is_safe_offset (b, 4))
                    throws -1;
                cur_off = 2 * f.getu16 (b);
                next_off = 2 * f.getu16 (b + 2);
            } else {
                int b = loca + 4 * glyph;
                if (!f.is_safe_offset (b, 8))
                    throws -1;
                cur_off = f.getu32 (b);
                next_off = f.getu32 (b + 4);
            }
            return (cur_off == next_off) ? 0 : (glyf + cur_off);
        }

        private int glyph_bbox (int outline, int[] box) {
            var f = (SftFont) font;
            if (!f.is_safe_offset (outline, 10))
                return -1;
            int x0 = f.geti16 (outline + 2);
            int y0 = f.geti16 (outline + 4);
            int x1 = f.geti16 (outline + 6);
            int y1 = f.geti16 (outline + 8);
            if (x1 <= x0 || y1 <= y0)
                return -1;
            double xs = x_scale / (double) f.units_per_em;
            double ys = y_scale / (double) f.units_per_em;
            box[0] = fast_floor ((double) x0 * xs + x_offset);
            box[1] = fast_floor ((double) y0 * ys + y_offset);
            box[2] = fast_ceil ((double) x1 * xs + x_offset);
            box[3] = fast_ceil ((double) y1 * ys + y_offset);
            return 0;
        }

        public int gmetrics (int glyph, SftGMetrics metrics) {
            metrics.advance_width = 0.0f;
            metrics.left_side_bearing = 0.0f;
            metrics.y_offset = 0;
            metrics.min_width = 0;
            metrics.min_height = 0;
            if (font == null)
                return -1;
            var f = (SftFont) font;
            int adv = 0;
            int lsb = 0;
            int outline = 0;
            try {
                var (a, l) = hor_metrics! (f, glyph);
                adv = a;
                lsb = l;
                outline = outline_offset! (f, glyph);
            } catch {
                return -1;
            }
            double xs = x_scale / (double) f.units_per_em;
            metrics.advance_width = (float) ((double) adv * xs);
            metrics.left_side_bearing = (float) ((double) lsb * xs + x_offset);
            if (outline == 0)
                return 0;
            var box = new int[4];
            if (glyph_bbox (outline, box) < 0)
                return -1;
            metrics.min_width = (int16) (box[2] - box[0] + 1);
            metrics.min_height = (int16) (box[3] - box[1] + 1);
            metrics.y_offset = (int16) (((flags & SFT_DOWNWARD_Y) != 0) ? -box[3] : box[1]);
            return 0;
        }

        public int kerning (int left_glyph, int right_glyph, SftKerning kern) {
            kern.x_shift = 0.0f;
            kern.y_shift = 0.0f;
            if (font == null)
                return -1;
            var f = (SftFont) font;
            int offset = f.gettable ("kern");
            if (offset < 0)
                return 0;
            if (!f.is_safe_offset (offset, 4))
                return -1;
            if (f.getu16 (offset) != 0)
                return 0;
            int num_tables = f.getu16 (offset + 2);
            offset += 4;
            int key = ((left_glyph & 0xFFFF) << 16) | (right_glyph & 0xFFFF);

            while (num_tables > 0) {
                if (!f.is_safe_offset (offset, 6))
                    return -1;
                int length = f.getu16 (offset + 2);
                int fmt = f.getu8 (offset + 4);
                int fl = f.getu8 (offset + 5);
                offset += 6;
                if (fmt == 0 && (fl & HORIZONTAL_KERNING) != 0 && (fl & MINIMUM_KERNING) == 0) {
                    if (!f.is_safe_offset (offset, 8))
                        return -1;
                    int num_pairs = f.getu16 (offset);
                    int pairs_off = offset + 8;
                    if (!f.is_safe_offset (pairs_off, num_pairs * 6))
                        return -1;
                    int low = 0;
                    int high = num_pairs - 1;
                    while (low <= high) {
                        int mid = low + (high - low) / 2;
                        int po = pairs_off + mid * 6;
                        int pk = (f.getu16 (po) << 16) | f.getu16 (po + 2);
                        if (pk == key) {
                            int val = f.geti16 (po + 4);
                            if ((fl & CROSS_STREAM_KERNING) != 0)
                                kern.y_shift += (float) val;
                            else
                                kern.x_shift += (float) val;
                            break;
                        }
                        if (key < pk)
                            high = mid - 1;
                        else
                            low = mid + 1;
                    }
                }
                offset += length - 6;
                num_tables--;
            }
            kern.x_shift = (float) ((double) kern.x_shift / (double) f.units_per_em * x_scale);
            kern.y_shift = (float) ((double) kern.y_shift / (double) f.units_per_em * y_scale);
            return 0;
        }

        private static bool simple_flags (SftFont f, ref int offset, int num_pts, uint8[] fl) {
            int val = 0;
            int repeat = 0;
            for (int i = 0; i < num_pts; i++) {
                if (repeat > 0) {
                    repeat--;
                } else {
                    if (!f.is_safe_offset (offset, 1))
                        return false;
                    val = f.getu8 (offset++);
                    if ((val & REPEAT_FLAG) != 0) {
                        if (!f.is_safe_offset (offset, 1))
                            return false;
                        repeat = f.getu8 (offset++);
                    }
                }
                fl[i] = (uint8) val;
            }
            return true;
        }

        private static bool simple_points (SftFont f, int offset, int num_pts, uint8[] fl, SftOutline outl, int base_pt) {
            int accum = 0;
            for (int i = 0; i < num_pts; i++) {
                int fv = (int) fl[i];
                if ((fv & X_CHANGE_IS_SMALL) != 0) {
                    if (!f.is_safe_offset (offset, 1))
                        return false;
                    int v = f.getu8 (offset++);
                    if ((fv & X_CHANGE_IS_POSITIVE) != 0)
                        accum += v;
                    else
                        accum -= v;
                } else if ((fv & X_CHANGE_IS_ZERO) == 0) {
                    if (!f.is_safe_offset (offset, 2))
                        return false;
                    accum += f.geti16 (offset);
                    offset += 2;
                }
                outl.px[base_pt + i] = (float) accum;
            }

            accum = 0;
            for (int i = 0; i < num_pts; i++) {
                int fv = (int) fl[i];
                if ((fv & Y_CHANGE_IS_SMALL) != 0) {
                    if (!f.is_safe_offset (offset, 1))
                        return false;
                    int v = f.getu8 (offset++);
                    if ((fv & Y_CHANGE_IS_POSITIVE) != 0)
                        accum += v;
                    else
                        accum -= v;
                } else if ((fv & Y_CHANGE_IS_ZERO) == 0) {
                    if (!f.is_safe_offset (offset, 2))
                        return false;
                    accum += f.geti16 (offset);
                    offset += 2;
                }
                outl.py[base_pt + i] = (float) accum;
            }
            return true;
        }

        private static bool decode_contour (uint8[] fl, int fl_base, int base_pt, int count, SftOutline outl) {
            if (count < 2)
                return true;
            int loose_end = 0;
            if (((int) fl[fl_base] & POINT_IS_ON_CURVE) != 0) {
                loose_end = base_pt++;
                fl_base++;
                count--;
            } else if (((int) fl[fl_base + count - 1] & POINT_IS_ON_CURVE) != 0) {
                loose_end = base_pt + (--count);
            } else {
                double mx = 0.5 * (outl.px[base_pt] + outl.px[base_pt + count - 1]);
                double my = 0.5 * (outl.py[base_pt] + outl.py[base_pt + count - 1]);
                loose_end = outl.add_point (mx, my);
                if (loose_end < 0)
                    return false;
            }
            int beg = loose_end;
            int ctrl = 0;
            bool got_ctrl = false;
            for (int i = 0; i < count; i++) {
                int cur = base_pt + i;
                if (((int) fl[fl_base + i] & POINT_IS_ON_CURVE) != 0) {
                    if (got_ctrl) {
                        if (!outl.add_curve (beg, cur, ctrl))
                            return false;
                    } else {
                        if (!outl.add_line (beg, cur))
                            return false;
                    }
                    beg = cur;
                    got_ctrl = false;
                } else {
                    if (got_ctrl) {
                        double mx = 0.5 * (outl.px[ctrl] + outl.px[cur]);
                        double my = 0.5 * (outl.py[ctrl] + outl.py[cur]);
                        int center = outl.add_point (mx, my);
                        if (center < 0)
                            return false;
                        if (!outl.add_curve (beg, center, ctrl))
                            return false;
                        beg = center;
                    }
                    ctrl = cur;
                    got_ctrl = true;
                }
            }
            if (got_ctrl) {
                if (!outl.add_curve (beg, loose_end, ctrl))
                    return false;
            } else {
                if (!outl.add_line (beg, loose_end))
                    return false;
            }
            return true;
        }

        private static bool simple_outline (SftFont f, int offset, int num_contours, SftOutline outl) {
            int base_pt = outl.num_points;
            if (!f.is_safe_offset (offset, num_contours * 2 + 2))
                return false;
            int num_pts = f.getu16 (offset + (num_contours - 1) * 2) + 1;
            if (num_pts <= 0 || num_pts >= 65535 || base_pt + num_pts > 65535)
                return false;
            while (outl.cap_points < base_pt + num_pts) {
                if (!outl.grow_points ())
                    return false;
            }
            var end_pts = new int[num_contours];
            for (int i = 0; i < num_contours; i++) {
                end_pts[i] = f.getu16 (offset);
                offset += 2;
            }
            for (int i = 0; i < num_contours - 1; i++) {
                if (end_pts[i + 1] < end_pts[i] + 1)
                    return false;
            }
            offset += 2 + f.getu16 (offset);

            var fl = new uint8[num_pts];
            if (!simple_flags (f, ref offset, num_pts, fl))
                return false;
            if (!simple_points (f, offset, num_pts, fl, outl, base_pt))
                return false;
            outl.num_points += num_pts;

            int beg = 0;
            for (int i = 0; i < num_contours; i++) {
                int count = end_pts[i] - beg + 1;
                if (!decode_contour (fl, beg, base_pt + beg, count, outl))
                    return false;
                beg = end_pts[i] + 1;
            }
            return true;
        }

        private static bool compound_outline (SftFont f, int offset, int rec_depth, SftOutline outl) {
            if (rec_depth >= 4)
                return false;
            var local = new double[6];
            while (true) {
                for (int k = 0; k < 6; k++)
                    local[k] = 0.0;
                if (!f.is_safe_offset (offset, 4))
                    return false;
                int fl = f.getu16 (offset);
                int glyph = f.getu16 (offset + 2);
                offset += 4;
                if ((fl & ACTUAL_XY_OFFSETS) == 0)
                    return false;
                if ((fl & OFFSETS_ARE_LARGE) != 0) {
                    if (!f.is_safe_offset (offset, 4))
                        return false;
                    local[4] = (double) f.geti16 (offset);
                    local[5] = (double) f.geti16 (offset + 2);
                    offset += 4;
                } else {
                    if (!f.is_safe_offset (offset, 2))
                        return false;
                    local[4] = (double) f.geti8 (offset);
                    local[5] = (double) f.geti8 (offset + 1);
                    offset += 2;
                }
                if ((fl & GOT_A_SINGLE_SCALE) != 0) {
                    if (!f.is_safe_offset (offset, 2))
                        return false;
                    local[0] = (double) f.geti16 (offset) / 16384.0;
                    local[3] = local[0];
                    offset += 2;
                } else if ((fl & GOT_AN_X_AND_Y_SCALE) != 0) {
                    if (!f.is_safe_offset (offset, 4))
                        return false;
                    local[0] = (double) f.geti16 (offset) / 16384.0;
                    local[3] = (double) f.geti16 (offset + 2) / 16384.0;
                    offset += 4;
                } else if ((fl & GOT_A_SCALE_MATRIX) != 0) {
                    if (!f.is_safe_offset (offset, 8))
                        return false;
                    local[0] = (double) f.geti16 (offset) / 16384.0;
                    local[1] = (double) f.geti16 (offset + 2) / 16384.0;
                    local[2] = (double) f.geti16 (offset + 4) / 16384.0;
                    local[3] = (double) f.geti16 (offset + 6) / 16384.0;
                    offset += 8;
                } else {
                    local[0] = 1.0;
                    local[3] = 1.0;
                }
                int sub_outline = 0;
                try {
                    sub_outline = outline_offset! (f, glyph);
                } catch {
                    return false;
                }
                if (sub_outline != 0) {
                    int base_pt = outl.num_points;
                    if (!decode_outline (f, sub_outline, rec_depth + 1, outl))
                        return false;
                    for (int i = base_pt; i < outl.num_points; i++) {
                        double x = outl.px[i];
                        double y = outl.py[i];
                        outl.px[i] = (float) (x * local[0] + y * local[2] + local[4]);
                        outl.py[i] = (float) (x * local[1] + y * local[3] + local[5]);
                    }
                }
                if ((fl & THERE_ARE_MORE_COMPONENTS) == 0)
                    break;
            }
            return true;
        }

        private static bool decode_outline (SftFont f, int offset, int rec_depth, SftOutline outl) {
            if (!f.is_safe_offset (offset, 10))
                return false;
            int num_contours = f.geti16 (offset);
            if (num_contours > 0)
                return simple_outline (f, offset + 10, num_contours, outl);
            if (num_contours < 0)
                return compound_outline (f, offset + 10, rec_depth, outl);
            return true;
        }

        private static bool is_flat (SftOutline outl, int b, int e, int c) {
            double ax = outl.px[b];
            double ay = outl.py[b];
            double gx = outl.px[c] - ax;
            double gy = outl.py[c] - ay;
            double hx = outl.px[e] - ax;
            double hy = outl.py[e] - ay;
            return d_abs (gx * hy - hx * gy) <= 2.0;
        }

        private static bool tesselate_curve (int b, int e, int c, SftOutline outl) {
            var sb = new int[10];
            var se = new int[10];
            var sc = new int[10];
            int top = 0;
            while (true) {
                if (is_flat (outl, b, e, c) || top >= 10) {
                    if (!outl.add_line (b, e))
                        return false;
                    if (top == 0)
                        break;
                    top--;
                    b = sb[top];
                    e = se[top];
                    c = sc[top];
                } else {
                    int ctrl0 = outl.add_point (0.5 * (outl.px[b] + outl.px[c]), 0.5 * (outl.py[b] + outl.py[c]));
                    int ctrl1 = outl.add_point (0.5 * (outl.px[c] + outl.px[e]), 0.5 * (outl.py[c] + outl.py[e]));
                    if (ctrl0 < 0 || ctrl1 < 0)
                        return false;
                    int pivot = outl.add_point (0.5 * (outl.px[ctrl0] + outl.px[ctrl1]), 0.5 * (outl.py[ctrl0] + outl.py[ctrl1]));
                    if (pivot < 0)
                        return false;
                    sb[top] = b;
                    se[top] = pivot;
                    sc[top] = ctrl0;
                    top++;
                    b = pivot;
                    c = ctrl1;
                }
            }
            return true;
        }

        private static void draw_line (float[] area, float[] cover, int w, int h, double ox, double oy, double gx, double gy) {
            double dx = gx - ox;
            double dy = gy - oy;
            int dir_x = i_sign (dx);
            int dir_y = i_sign (dy);
            if (dir_y == 0)
                return;

            double incr_x = (dir_x != 0) ? d_abs (1.0 / dx) : 1.0;
            double incr_y = d_abs (1.0 / dy);
            int px = 0;
            int py = 0;
            double next_x = 0.0;
            double next_y = 0.0;
            int num_steps = 0;

            if (dir_x == 0) {
                px = fast_floor (ox);
                next_x = 100.0;
            } else if (dir_x > 0) {
                px = fast_floor (ox);
                next_x = incr_x - (ox - (double) px) * incr_x;
                num_steps += fast_ceil (gx) - fast_floor (ox) - 1;
            } else {
                px = fast_ceil (ox) - 1;
                next_x = (ox - (double) px) * incr_x;
                num_steps += fast_ceil (ox) - fast_floor (gx) - 1;
            }

            if (dir_y > 0) {
                py = fast_floor (oy);
                next_y = incr_y - (oy - (double) py) * incr_y;
                num_steps += fast_ceil (gy) - fast_floor (oy) - 1;
            } else {
                py = fast_ceil (oy) - 1;
                next_y = (oy - (double) py) * incr_y;
                num_steps += fast_ceil (oy) - fast_floor (gy) - 1;
            }

            double prev_dist = 0.0;
            double next_dist = d_min (next_x, next_y);
            double half_dx = 0.5 * dx;
            int total = w * h;

            for (int step = 0; step < num_steps; step++) {
                double x_avg = ox + (prev_dist + next_dist) * half_dx;
                double y_diff = (next_dist - prev_dist) * dy;
                if (px >= 0 && px < w && py >= 0 && py < h) {
                    int ci = py * w + px;
                    if (ci >= 0 && ci < total) {
                        cover[ci] += (float) y_diff;
                        area[ci] += (float) ((1.0 - (x_avg - (double) px)) * y_diff);
                    }
                }
                prev_dist = next_dist;
                if (next_x < next_y) {
                    px += dir_x;
                    next_x += incr_x;
                } else {
                    py += dir_y;
                    next_y += incr_y;
                }
                next_dist = d_min (next_x, next_y);
            }

            double x_avg_end = ox + (prev_dist + 1.0) * half_dx;
            double y_diff_end = (1.0 - prev_dist) * dy;
            if (px >= 0 && px < w && py >= 0 && py < h) {
                int ci = py * w + px;
                if (ci >= 0 && ci < total) {
                    cover[ci] += (float) y_diff_end;
                    area[ci] += (float) ((1.0 - (x_avg_end - (double) px)) * y_diff_end);
                }
            }
        }

        public int render (int glyph, SftImage image) {
            if (font == null || image.width <= 0 || image.height <= 0)
                return -1;
            var f = (SftFont) font;
            int outline = 0;
            try {
                outline = outline_offset! (f, glyph);
            } catch {
                return -1;
            }
            if (outline == 0)
                return 0;
            var box = new int[4];
            if (glyph_bbox (outline, box) < 0)
                return -1;

            double t0 = x_scale / (double) f.units_per_em;
            double t4 = x_offset - (double) box[0];
            double t3 = ((flags & SFT_DOWNWARD_Y) != 0) ? (-y_scale / (double) f.units_per_em) : (y_scale / (double) f.units_per_em);
            double t5 = ((flags & SFT_DOWNWARD_Y) != 0) ? ((double) box[3] - y_offset) : (y_offset - (double) box[1]);

            var outl = new SftOutline ();
            if (!decode_outline (f, outline, 0, outl))
                return -1;

            double max_x = (double) image.width - 1e-9;
            double max_y = (double) image.height - 1e-9;
            for (int i = 0; i < outl.num_points; i++) {
                double x = outl.px[i] * t0 + t4;
                double y = outl.py[i] * t3 + t5;
                if (x < 0.0) x = 0.0;
                if (x >= (double) image.width) x = max_x;
                if (y < 0.0) y = 0.0;
                if (y >= (double) image.height) y = max_y;
                outl.px[i] = (float) x;
                outl.py[i] = (float) y;
            }

            for (int i = 0; i < outl.num_curves; i++) {
                if (!tesselate_curve (outl.cbeg[i], outl.cend[i], outl.cctrl[i], outl))
                    return -1;
            }

            int num_px = image.width * image.height;
            var area = new float[num_px];
            var cover = new float[num_px];
            for (int i = 0; i < outl.num_lines; i++) {
                int b = outl.lbeg[i];
                int e = outl.lend[i];
                draw_line (area, cover, image.width, image.height, (double) outl.px[b], (double) outl.py[b], (double) outl.px[e], (double) outl.py[e]);
            }

            double accum = 0.0;
            for (int i = 0; i < num_px; i++) {
                double v = d_abs (accum + (double) area[i]);
                if (v > 1.0)
                    v = 1.0;
                int iv = (int) (v * 255.0 + 0.5);
                if (iv > 255)
                    iv = 255;
                image.pixels[i] = (uint8) iv;
                accum += (double) cover[i];
            }
            return 0;
        }
    }
}
