// Pure-Vala SPIR-V 1.0 module loader and SSA evaluator.
//
// This is the "shader runtime" shared by the graphics demos and the compositor:
// it loads a standard SPIR-V binary, validates the header and walks the constant
// arithmetic of the module to recover the fragment color a GPU would produce.
// PlanetOS has no Vulkan ICD yet (decision D-13), so this CPU evaluator is the
// reference implementation that a future driver backend must match.

using Planet;

namespace Spv {
    public class Module : Object {
        public bool valid = false;
        public string error = "";
        public string name = "";
        public int words = 0;
        public int insns = 0;
        public int bound = 0;
        public double r = 0.0;
        public double g = 0.0;
        public double b = 0.0;
        public double a = 1.0;

        private uint8[] code;
        private int[] wcache;
        private int code_size = 0;

        public uint8[] raw_bytes () { return code; }
        public int raw_size () { return code_size; }
        private int input_id = 0;
        private bool input_ready = false;
        private int output_id = 0;
        private bool output_ready = false;
        private int pc_id = 0;
        private bool pc_ready = false;
        private int exec_start_wi = 5;
        private double uni_time = 0.0;
        private double uni_width = 800.0;
        private double uni_height = 600.0;
        private double uni_p0 = 1.0;
        private double uni_p1 = 1.0;
        private double uni_p2 = 0.0;
        private double uni_p3 = 0.0;
        // Pixel-space origin subtracted from gl_FragCoord, so a GSK node can
        // evaluate the same shader in its own local coordinates.
        private double origin_x = 0.0;
        private double origin_y = 0.0;
        private bool[] is_const;
        private int[] pc_member;
        private int[] ivals;
        private double[] fvals;
        private double[] vec_r;
        private double[] vec_g;
        private double[] vec_b;
        private double[] vec_a;

        // True when the module reads gl_FragCoord, i.e. it is a per-pixel shader.
        public bool has_input () { return input_ready; }

        // True when the module reads push constants (time/width/height).
        public bool has_uniforms () { return pc_ready; }

        public void set_uniforms (double time, double width, double height) {
            uni_time = time;
            uni_width = width;
            uni_height = height;
        }

        // Effect parameters exposed to the shader as uniform_p0()..uniform_p3().
        public void set_params (double p0, double p1, double p2, double p3) {
            uni_p0 = p0;
            uni_p1 = p1;
            uni_p2 = p2;
            uni_p3 = p3;
        }

        public void set_origin (double x, double y) {
            origin_x = x;
            origin_y = y;
        }

        public double uniform_time_value () { return uni_time; }

        // Evaluates the fragment stage for one pixel (coordinates are the
        // FragmentCoord convention: pixel centre at x+0.5).
        public void pixel (int px, int py) {
            if (!valid || !input_ready)
                return;
            run (px, py, true);
        }

        public int ir () { return to255 (r); }
        public int ig () { return to255 (g); }
        public int ib () { return to255 (b); }
        public int ia () { return to255 (a); }

        private static double dfloor (double x) {
            return Math.floor (x);
        }

        private static double dsqrt (double x) {
            if (x <= 0.0)
                return 0.0;
            return Math.sqrt (x);
        }

        private static int to255 (double v) {
            int n = (int) (v * 255.0);
            if (n < 0) return 0;
            if (n > 255) return 255;
            return n;
        }

        public static double f32_bits_to_double (uint32 bits) {
            uint32 abs_bits = bits & 0x7FFFFFFFu;
            if (abs_bits == 0)
                return 0.0;
            double sign = ((bits & 0x80000000u) != 0) ? -1.0 : 1.0;
            int exp_raw = (int) ((bits >> 23) & 0xFF);
            uint32 mant = bits & 0x7FFFFFu;
            if (exp_raw == 0) {
                // Subnormal float32
                return sign * Math.ldexp ((double) mant / 8388608.0, -126);
            }
            if (exp_raw == 255) {
                // Inf / NaN: clamp to 0.0 for NaN or large finite fallback
                return (mant == 0) ? (sign * 1.0e38) : 0.0;
            }
            return sign * Math.ldexp (1.0 + (double) mant / 8388608.0, exp_raw - 127);
        }

        private static uint32 word_at (uint8[] buf, int word_idx) {
            int off = word_idx * 4;
            return (uint32) buf[off + 0]
                | ((uint32) buf[off + 1] << 8)
                | ((uint32) buf[off + 2] << 16)
                | ((uint32) buf[off + 3] << 24);
        }

        public static Module load (string path) {
            var m = new Module ();
            m.name = path;
            int fd = Sys.open (path);
            if (fd < 0) {
                m.error = @"cannot open '$path'";
                return m;
            }
            int sz = Sys.file_size (fd);
            if (sz < 20 || (sz % 4) != 0) {
                Sys.close (fd);
                m.error = "invalid .spv size";
                return m;
            }
            var buf = new uint8[sz];
            int got = 0;
            while (got < sz) {
                int want = sz - got;
                if (want > 4096)
                    want = 4096;
                var chunk = new uint8[want];
                int n = Sys.read (fd, chunk, want);
                if (n <= 0)
                    break;
                for (int i = 0; i < n; i++)
                    buf[got + i] = chunk[i];
                got = got + n;
            }
            Sys.close (fd);
            m.evaluate (buf, got);
            return m;
        }

        private void evaluate (uint8[] buf, int size) {
            if (size < 20) {
                error = "truncated module";
                return;
            }
            uint32 magic = word_at (buf, 0);
            bound = (int) word_at (buf, 3);
            if (magic != 0x07230203u) {
                error = "bad SPIR-V magic";
                return;
            }
            words = size / 4;
            code = buf;
            code_size = size;
            // Decode the module once: per-pixel evaluation then indexes words
            // directly instead of doing four byte loads per operand.
            wcache = new int[words];
            for (int i = 0; i < words; i++) {
                int off = i * 4;
                wcache[i] = (int) ((uint32) buf[off]
                    | ((uint32) buf[off + 1] << 8)
                    | ((uint32) buf[off + 2] << 16)
                    | ((uint32) buf[off + 3] << 24));
            }

            int max_ids = bound + 4;
            is_const = new bool[max_ids];
            pc_member = new int[max_ids];
            ivals = new int[max_ids];
            fvals = new double[max_ids];
            vec_r = new double[max_ids];
            vec_g = new double[max_ids];
            vec_b = new double[max_ids];
            vec_a = new double[max_ids];
            for (int i = 0; i < max_ids; i++)
                pc_member[i] = -1;

            // Pre-decode constants, interface variables, and entry point offset once.
            exec_start_wi = 5;
            bool found_label = false;
            int wi = 5;
            while (wi < words) {
                int hdr = wcache[wi];
                int wc = hdr >> 16;
                int opc = hdr & 0xFFFF;
                if (wc <= 0 || wi + wc > words)
                    break;
                insns = insns + 1;
                if (!found_label && opc == 248) { // OpLabel
                    exec_start_wi = wi + wc;
                    found_label = true;
                } else if (opc == 43 && wc >= 4) { // OpConstant
                    int res = wcache[wi + 2];
                    if (res >= 0 && res < max_ids) {
                        is_const[res] = true;
                        ivals[res] = wcache[wi + 3];
                        fvals[res] = f32_bits_to_double ((uint32) wcache[wi + 3]);
                    }
                } else if (opc == 59 && wc >= 4) { // OpVariable
                    int var_id = wcache[wi + 2];
                    int storage = wcache[wi + 3];
                    if (storage == 1) { // Input
                        input_id = var_id;
                        input_ready = true;
                    } else if (storage == 3) { // Output
                        output_id = var_id;
                        output_ready = true;
                    } else if (storage == 9) { // PushConstant
                        pc_id = var_id;
                        pc_ready = true;
                    }
                }
                wi = wi + wc;
            }

            run (0, 0, false);
            valid = true;
        }

        private bool valid_id (int id) {
            return id >= 0 && id < fvals.length;
        }

        private void clear_scratch () {
            for (int i = 0; i < fvals.length; i++) {
                if (is_const[i])
                    continue;
                fvals[i] = 0.0;
                ivals[i] = 0;
                vec_r[i] = 0.0;
                vec_g[i] = 0.0;
                vec_b[i] = 0.0;
                vec_a[i] = 0.0;
            }
        }

        private void run (int px, int py, bool per_pixel) {
            int[] w = wcache;
            int total = wcache.length;
            clear_scratch ();
            r = 0.0;
            g = 0.0;
            b = 0.0;
            a = 1.0;

            int wi = exec_start_wi;
            while (wi < total) {
                int hdr = w[wi];
                int wc = hdr >> 16;
                int opc = hdr & 0xFFFF;
                if (wc <= 0 || wi + wc > total)
                    break;

                if (opc == 65 && wc >= 5) { // OpAccessChain
                    int res = w[wi + 2];
                    int src = w[wi + 3];
                    int index = w[wi + 4];
                    if (src == pc_id && valid_id (res) && valid_id (index))
                        pc_member[res] = ivals[index];
                } else if (opc == 111 && wc >= 4) { // OpConvertSToF
                    int res = w[wi + 2];
                    int src = w[wi + 3];
                    if (valid_id (res) && valid_id (src))
                        fvals[res] = (double) ivals[src];
                } else if (opc == 126 && wc >= 4) { // OpSNegate
                    int res = w[wi + 2];
                    int src = w[wi + 3];
                    if (valid_id (res) && valid_id (src)) {
                        ivals[res] = -ivals[src];
                        fvals[res] = (double) ivals[res];
                    }
                } else if (opc == 127 && wc >= 4) { // OpFNegate
                    int res = w[wi + 2];
                    int src = w[wi + 3];
                    if (valid_id (res) && valid_id (src))
                        fvals[res] = -fvals[src];
                } else if (opc == 128 && wc >= 5) { // OpIAdd
                    int res = w[wi + 2];
                    int lhs = w[wi + 3];
                    int rhs = w[wi + 4];
                    if (valid_id (res) && valid_id (lhs) && valid_id (rhs)) {
                        ivals[res] = ivals[lhs] + ivals[rhs];
                        fvals[res] = (double) ivals[res];
                    }
                } else if (opc == 129 && wc >= 5) { // OpFAdd
                    int res = w[wi + 2];
                    int lhs = w[wi + 3];
                    int rhs = w[wi + 4];
                    if (valid_id (res) && valid_id (lhs) && valid_id (rhs))
                        fvals[res] = fvals[lhs] + fvals[rhs];
                } else if (opc == 130 && wc >= 5) { // OpISub
                    int res = w[wi + 2];
                    int lhs = w[wi + 3];
                    int rhs = w[wi + 4];
                    if (valid_id (res) && valid_id (lhs) && valid_id (rhs)) {
                        ivals[res] = ivals[lhs] - ivals[rhs];
                        fvals[res] = (double) ivals[res];
                    }
                } else if (opc == 131 && wc >= 5) { // OpFSub
                    int res = w[wi + 2];
                    int lhs = w[wi + 3];
                    int rhs = w[wi + 4];
                    if (valid_id (res) && valid_id (lhs) && valid_id (rhs))
                        fvals[res] = fvals[lhs] - fvals[rhs];
                } else if (opc == 132 && wc >= 5) { // OpIMul
                    int res = w[wi + 2];
                    int lhs = w[wi + 3];
                    int rhs = w[wi + 4];
                    if (valid_id (res) && valid_id (lhs) && valid_id (rhs)) {
                        ivals[res] = ivals[lhs] * ivals[rhs];
                        fvals[res] = (double) ivals[res];
                    }
                } else if (opc == 133 && wc >= 5) { // OpFMul
                    int res = w[wi + 2];
                    int lhs = w[wi + 3];
                    int rhs = w[wi + 4];
                    if (valid_id (res) && valid_id (lhs) && valid_id (rhs))
                        fvals[res] = fvals[lhs] * fvals[rhs];
                } else if (opc == 135 && wc >= 5) { // OpSDiv
                    int res = w[wi + 2];
                    int lhs = w[wi + 3];
                    int rhs = w[wi + 4];
                    if (valid_id (res) && valid_id (lhs) && valid_id (rhs)) {
                        int den = ivals[rhs];
                        ivals[res] = (den != 0) ? (ivals[lhs] / den) : 0;
                        fvals[res] = (double) ivals[res];
                    }
                } else if (opc == 136 && wc >= 5) { // OpFDiv
                    int res = w[wi + 2];
                    int lhs = w[wi + 3];
                    int rhs = w[wi + 4];
                    if (valid_id (res) && valid_id (lhs) && valid_id (rhs)) {
                        double den = fvals[rhs];
                        fvals[res] = (den != 0.0) ? fvals[lhs] / den : 0.0;
                    }
                } else if (opc == 139 && wc >= 5) { // OpSMod
                    int res = w[wi + 2];
                    int lhs = w[wi + 3];
                    int rhs = w[wi + 4];
                    if (valid_id (res) && valid_id (lhs) && valid_id (rhs)) {
                        int den = ivals[rhs];
                        ivals[res] = (den != 0) ? (ivals[lhs] % den) : 0;
                        fvals[res] = (double) ivals[res];
                    }
                } else if (opc == 141 && wc >= 5) { // OpFMod
                    int res = w[wi + 2];
                    int lhs = w[wi + 3];
                    int rhs = w[wi + 4];
                    if (valid_id (res) && valid_id (lhs) && valid_id (rhs)) {
                        double den = fvals[rhs];
                        fvals[res] = (den != 0.0) ? (fvals[lhs] - den * dfloor (fvals[lhs] / den)) : 0.0;
                    }
                } else if (opc == 80 && wc >= 7) { // OpCompositeConstruct (vec4)
                    int res = w[wi + 2];
                    int c0 = w[wi + 3];
                    int c1 = w[wi + 4];
                    int c2 = w[wi + 5];
                    int c3 = w[wi + 6];
                    if (valid_id (res) && valid_id (c0) && valid_id (c1) && valid_id (c2) && valid_id (c3)) {
                        vec_r[res] = fvals[c0];
                        vec_g[res] = fvals[c1];
                        vec_b[res] = fvals[c2];
                        vec_a[res] = fvals[c3];
                    }
                } else if (opc == 12 && wc >= 6) { // OpExtInst (GLSL.std.450)
                    int res = w[wi + 2];
                    int inst = w[wi + 4];
                    int ax = w[wi + 5];
                    int ay = (wc >= 7) ? w[wi + 6] : 0;
                    int az = (wc >= 8) ? w[wi + 7] : 0;
                    if (!valid_id (res) || !valid_id (ax)) {
                        wi = wi + wc;
                        continue;
                    }
                    double x = fvals[ax];
                    double y = (wc >= 7 && valid_id (ay)) ? fvals[ay] : 0.0;
                    double z = (wc >= 8 && valid_id (az)) ? fvals[az] : 0.0;
                    if (inst == 4) { // abs
                        fvals[res] = (x < 0.0) ? -x : x;
                    } else if (inst == 8) { // floor
                        fvals[res] = dfloor (x);
                    } else if (inst == 10) { // fract
                        fvals[res] = x - dfloor (x);
                    } else if (inst == 13) { // sin
                        fvals[res] = Math.sin (x);
                    } else if (inst == 14) { // cos
                        fvals[res] = Math.cos (x);
                    } else if (inst == 15) { // tan
                        fvals[res] = Math.tan (x);
                    } else if (inst == 26) { // pow
                        fvals[res] = Math.pow (x, y);
                    } else if (inst == 27) { // exp
                        fvals[res] = Math.exp (x);
                    } else if (inst == 28) { // log
                        fvals[res] = Math.log (x);
                    } else if (inst == 29) { // exp2
                        fvals[res] = Math.exp2 (x);
                    } else if (inst == 30) { // log2
                        fvals[res] = Math.log2 (x);
                    } else if (inst == 31) { // sqrt
                        fvals[res] = dsqrt (x);
                    } else if (inst == 37) { // min
                        fvals[res] = (x < y) ? x : y;
                    } else if (inst == 38) { // max
                        fvals[res] = (x > y) ? x : y;
                    } else if (inst == 43) { // clamp
                        double lo = (x < y) ? y : x;
                        fvals[res] = (lo > z) ? z : lo;
                    } else if (inst == 46) { // mix
                        fvals[res] = x * (1.0 - z) + y * z;
                    } else if (inst == 48) { // step
                        fvals[res] = (y < x) ? 0.0 : 1.0;
                    } else if (inst == 49) { // smoothstep
                        double t = (y > x) ? (z - x) / (y - x) : 0.0;
                        if (t < 0.0) t = 0.0;
                        if (t > 1.0) t = 1.0;
                        fvals[res] = t * t * (3.0 - 2.0 * t);
                    }
                } else if (opc == 81 && wc >= 5) { // OpCompositeExtract
                    int res = w[wi + 2];
                    int src = w[wi + 3];
                    int comp = w[wi + 4];
                    if (valid_id (res) && valid_id (src)) {
                        if (comp == 0)
                            fvals[res] = vec_r[src];
                        else if (comp == 1)
                            fvals[res] = vec_g[src];
                        else if (comp == 2)
                            fvals[res] = vec_b[src];
                        else
                            fvals[res] = vec_a[src];
                    }
                } else if (opc == 62 && wc >= 3) { // OpStore
                    int ptr = w[wi + 1];
                    int obj = w[wi + 2];
                    if (valid_id (ptr) && valid_id (obj)) {
                        fvals[ptr] = fvals[obj];
                        ivals[ptr] = ivals[obj];
                        vec_r[ptr] = vec_r[obj];
                        vec_g[ptr] = vec_g[obj];
                        vec_b[ptr] = vec_b[obj];
                        vec_a[ptr] = vec_a[obj];
                        if (!output_ready || ptr == output_id) {
                            r = vec_r[obj];
                            g = vec_g[obj];
                            b = vec_b[obj];
                            a = vec_a[obj];
                        }
                    }
                } else if (opc == 61 && wc >= 4) { // OpLoad
                    int res = w[wi + 2];
                    int ptr = w[wi + 3];
                    if (valid_id (res) && valid_id (ptr)) {
                        if (per_pixel && ptr == input_id) {
                            // gl_FragCoord with OriginUpperLeft, relative to the
                            // evaluation origin (a GSK node's top-left corner).
                            vec_r[res] = (double) px + 0.5 - origin_x;
                            vec_g[res] = (double) py + 0.5 - origin_y;
                            vec_b[res] = 0.0;
                            vec_a[res] = 1.0;
                        } else if (pc_member[ptr] >= 0) {
                            // 0 time, 1 width, 2 height, 3 pad, 4..7 effect params
                            int m = pc_member[ptr];
                            if (m == 0)
                                fvals[res] = uni_time;
                            else if (m == 1)
                                fvals[res] = uni_width;
                            else if (m == 2)
                                fvals[res] = uni_height;
                            else if (m == 4)
                                fvals[res] = uni_p0;
                            else if (m == 5)
                                fvals[res] = uni_p1;
                            else if (m == 6)
                                fvals[res] = uni_p2;
                            else if (m == 7)
                                fvals[res] = uni_p3;
                            else
                                fvals[res] = 0.0;
                        } else {
                            fvals[res] = fvals[ptr];
                            ivals[res] = ivals[ptr];
                            vec_r[res] = vec_r[ptr];
                            vec_g[res] = vec_g[ptr];
                            vec_b[res] = vec_b[ptr];
                            vec_a[res] = vec_a[ptr];
                        }
                    }
                }
                wi = wi + wc;
            }
        }
    }
}
