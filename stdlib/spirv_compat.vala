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
        private int code_size = 0;
        private int input_id = 0;
        private bool input_ready = false;
        private double[] fvals;
        private double[] vec_r;
        private double[] vec_g;
        private double[] vec_b;
        private double[] vec_a;

        // True when the module reads gl_FragCoord, i.e. it is a per-pixel shader.
        public bool has_input () { return input_ready; }

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

        private static int to255 (double v) {
            int n = (int) (v * 255.0);
            if (n < 0) return 0;
            if (n > 255) return 255;
            return n;
        }

        public static double f32_bits_to_double (uint32 bits) {
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

            int max_ids = bound + 4;
            fvals = new double[max_ids];
            vec_r = new double[max_ids];
            vec_g = new double[max_ids];
            vec_b = new double[max_ids];
            vec_a = new double[max_ids];

            run (0, 0, false);
            valid = true;
        }

        private void clear_scratch () {
            for (int i = 0; i < fvals.length; i++) {
                fvals[i] = 0.0;
                vec_r[i] = 0.0;
                vec_g[i] = 0.0;
                vec_b[i] = 0.0;
                vec_a[i] = 0.0;
            }
        }

        private void run (int px, int py, bool per_pixel) {
            uint8[] buf = code;
            int total = code_size / 4;
            clear_scratch ();
            r = 0.0;
            g = 0.0;
            b = 0.0;
            a = 1.0;
            if (!per_pixel)
                insns = 0;

            int wi = 5;
            while (wi < total) {
                uint32 hdr = word_at (buf, wi);
                int wc = (int) (hdr >> 16);
                int opc = (int) (hdr & 0xFFFF);
                if (wc <= 0 || wi + wc > total)
                    break;
                if (!per_pixel)
                    insns = insns + 1;

                if (opc == 43 && wc >= 4) { // OpConstant
                    int res = (int) word_at (buf, wi + 2);
                    fvals[res] = f32_bits_to_double (word_at (buf, wi + 3));
                } else if (opc == 59 && wc >= 4) { // OpVariable
                    int var_id = (int) word_at (buf, wi + 2);
                    int storage = (int) word_at (buf, wi + 3);
                    if (storage == 1) { // Input
                        input_id = var_id;
                        input_ready = true;
                    }
                } else if (opc == 129 && wc >= 5) { // OpFAdd
                    int res = (int) word_at (buf, wi + 2);
                    fvals[res] = fvals[(int) word_at (buf, wi + 3)] + fvals[(int) word_at (buf, wi + 4)];
                } else if (opc == 131 && wc >= 5) { // OpFSub
                    int res = (int) word_at (buf, wi + 2);
                    fvals[res] = fvals[(int) word_at (buf, wi + 3)] - fvals[(int) word_at (buf, wi + 4)];
                } else if (opc == 133 && wc >= 5) { // OpFMul
                    int res = (int) word_at (buf, wi + 2);
                    fvals[res] = fvals[(int) word_at (buf, wi + 3)] * fvals[(int) word_at (buf, wi + 4)];
                } else if (opc == 136 && wc >= 5) { // OpFDiv
                    int res = (int) word_at (buf, wi + 2);
                    double den = fvals[(int) word_at (buf, wi + 4)];
                    fvals[res] = (den != 0.0) ? fvals[(int) word_at (buf, wi + 3)] / den : 0.0;
                } else if (opc == 80 && wc >= 7) { // OpCompositeConstruct (vec4)
                    int res = (int) word_at (buf, wi + 2);
                    vec_r[res] = fvals[(int) word_at (buf, wi + 3)];
                    vec_g[res] = fvals[(int) word_at (buf, wi + 4)];
                    vec_b[res] = fvals[(int) word_at (buf, wi + 5)];
                    vec_a[res] = fvals[(int) word_at (buf, wi + 6)];
                } else if (opc == 81 && wc >= 5) { // OpCompositeExtract
                    int res = (int) word_at (buf, wi + 2);
                    int src = (int) word_at (buf, wi + 3);
                    int comp = (int) word_at (buf, wi + 4);
                    if (comp == 0)
                        fvals[res] = vec_r[src];
                    else if (comp == 1)
                        fvals[res] = vec_g[src];
                    else if (comp == 2)
                        fvals[res] = vec_b[src];
                    else
                        fvals[res] = vec_a[src];
                } else if (opc == 62 && wc >= 3) { // OpStore
                    int ptr = (int) word_at (buf, wi + 1);
                    int obj = (int) word_at (buf, wi + 2);
                    fvals[ptr] = fvals[obj];
                    r = vec_r[obj];
                    g = vec_g[obj];
                    b = vec_b[obj];
                    a = vec_a[obj];
                } else if (opc == 61 && wc >= 4) { // OpLoad
                    int res = (int) word_at (buf, wi + 2);
                    int ptr = (int) word_at (buf, wi + 3);
                    if (per_pixel && ptr == input_id) {
                        // gl_FragCoord with OriginUpperLeft
                        vec_r[res] = (double) px + 0.5;
                        vec_g[res] = (double) py + 0.5;
                        vec_b[res] = 0.0;
                        vec_a[res] = 1.0;
                    } else {
                        fvals[res] = fvals[ptr];
                    }
                }
                wi = wi + wc;
            }
            if (a <= 0.0)
                a = 1.0;
        }
    }
}
