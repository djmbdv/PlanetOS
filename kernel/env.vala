// Kernel environment variable table for PlanetOS (inherited by all userland processes).

namespace Planet.Kernel {

    [AsmBody(@"
        movzbq (%rdi), %rax
        ret
    ")]
    private extern int env_read_u8 (int addr);

    public sealed class Env : Object {
        private const int ENV_MAX_VARS = 32;
        private static string[] env_keys;
        private static string[] env_vals;
        private static int env_count = 0;

        private static string copy_from_user (int ptr, int len) {
            if (ptr == 0 || len <= 0)
                return "";
            var b = new uint8[len + 1];
            for (int i = 0; i < len; i++) {
                b[i] = (uint8) env_read_u8 (ptr + i);
            }
            b[len] = 0;
            // Build string cleanly from bytes
            string s = "";
            string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
            for (int i = 0; i < len; i++) {
                uint8 c = b[i];
                if (c >= 32 && c <= 126)
                    s = s + ascii.substring ((int) c - 32, 1);
            }
            return s;
        }

        public static void set_kv (string k, string v) {
            if (k.length == 0)
                return;
            for (int i = 0; i < env_count; i++) {
                if (env_keys[i] == k) {
                    env_vals[i] = v;
                    return;
                }
            }
            if (env_count < ENV_MAX_VARS) {
                env_keys[env_count] = k;
                env_vals[env_count] = v;
                env_count = env_count + 1;
            }
        }

        public static void init () {
            env_keys = new string[ENV_MAX_VARS];
            env_vals = new string[ENV_MAX_VARS];
            env_count = 0;
            set_kv ("OS", "PlanetOS");
            set_kv ("ARCH", "x86_64");
            set_kv ("TARGET", "planetos");
            set_kv ("SHELL", "shell.elf");
        }

        public static int sys_get (int k_ptr, int k_len, int out_buf, int max_len) {
            string k = copy_from_user (k_ptr, k_len);
            for (int i = 0; i < env_count; i++) {
                if (env_keys[i] == k) {
                    string v = env_vals[i];
                    int n = (v.length < max_len) ? v.length : max_len;
                    for (int j = 0; j < n; j++) {
                        mmio_write8 (out_buf + j, (int) v[j]);
                    }
                    return n;
                }
            }
            return -1;
        }

        public static int sys_set (int k_ptr, int k_len, int v_ptr, int v_len) {
            string k = copy_from_user (k_ptr, k_len);
            if (k.length == 0)
                return -1;
            if (v_ptr == 0) {
                for (int i = 0; i < env_count; i++) {
                    if (env_keys[i] == k) {
                        int last = env_count - 1;
                        if (i != last) {
                            env_keys[i] = env_keys[last];
                            env_vals[i] = env_vals[last];
                        }
                        env_keys[last] = "";
                        env_vals[last] = "";
                        env_count = last;
                        return 0;
                    }
                }
                return 0;
            }
            string v = copy_from_user (v_ptr, v_len);
            set_kv (k, v);
            return 0;
        }
    }
}
