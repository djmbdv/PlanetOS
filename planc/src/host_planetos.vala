// PlanetOS userland host adapter (compiled with --target=planetos using int 0x80 syscalls).

namespace Planc {

    public class Host : Object {

        [AsmBody(@"
            mov %rdi, %rax
            mov %rsi, %rdi
            mov %rdx, %rsi
            mov %rcx, %rdx
            int $0x80
            ret
        ")]
        private static extern int sys (int num, int a0, int a1, int a2);

        [AsmBody(@"
            # sys_open_str(string* rdi) -> fd
            mov 8(%rdi), %rsi
            add $16, %rdi
            mov $6, %rax
            xor %edx, %edx
            int $0x80
            ret
        ")]
        private static extern int sys_open_str (string path);

        [AsmBody(@"
            # sys_create_str(string* rdi) -> fd
            mov 8(%rdi), %rsi
            add $16, %rdi
            mov $14, %rax
            xor %edx, %edx
            int $0x80
            ret
        ")]
        private static extern int sys_create_str (string path);

        [AsmBody(@"
            # sys_read_arr(int fd, uint8[] buf, int count)
            add $16, %rsi
            mov $7, %rax
            int $0x80
            ret
        ")]
        private static extern int sys_read_arr (int fd, uint8[] buf, int count);

        [AsmBody(@"
            # sys_write_arr(int fd, uint8[] buf, int count)
            add $16, %rsi
            mov $15, %rax
            int $0x80
            ret
        ")]
        private static extern int sys_write_arr (int fd, uint8[] buf, int count);

        public static void eprint (string s) {
            print (s);
        }

        public static void eprintln (string s) {
            print (s + "\n");
        }

        public static void println (string s) {
            print (s + "\n");
        }

        public static void panic (string msg) {
            print ("planc: fatal: " + msg + "\n");
            exit (134);
        }

        public static string read_file (string path) throws FileError {
            int fd = sys_open_str (path);
            if (fd < 0)
                throw new FileError.FAILED (@"cannot open '$path'");
            int sz = sys (9, fd, 0, 0);
            if (sz < 0) {
                sys (8, fd, 0, 0);
                throw new FileError.FAILED (@"cannot stat '$path'");
            }
            var buf = new uint8[sz];
            int got = 0;
            while (got < sz) {
                int r = sys_read_arr (fd, buf, sz - got);
                if (r <= 0)
                    break;
                got = got + r;
            }
            sys (8, fd, 0, 0);
            return bytes_to_string (buf, got);
        }

        public static void write_file (string path, uint8[] data) throws FileError {
            int fd = sys_create_str (path);
            if (fd < 0)
                throw new FileError.FAILED (@"cannot create '$path'");
            int nw = sys_write_arr (fd, data, data.length);
            sys (8, fd, 0, 0);
            if (nw != data.length)
                throw new FileError.FAILED (@"short write to '$path'");
        }

        public static void chmod_755 (string path) {
        }

        public static string bytes_to_string (uint8[] buf, int len) {
            return __planc_host_bytes_to_str (buf, len);
        }

        private static string hex_nibble (int d) {
            string hex = "0123456789abcdef";
            return hex.substring (d, 1);
        }

        public static string hex_u8 (uint8 v) {
            int iv = (int) v;
            int hi = (iv >> 4) & 0xf;
            int lo = iv & 0xf;
            return hex_nibble (hi) + hex_nibble (lo);
        }

        public static string hex_u32 (uint32 v) {
            int iv = (int) v;
            if (iv == 0)
                return "0";
            string out_str = "";
            for (int shift = 28; shift >= 0; shift -= 4) {
                int nib = (iv >> shift) & 0xf;
                if (nib != 0 || out_str.length > 0)
                    out_str = out_str + hex_nibble (nib);
            }
            return out_str;
        }
    }
}
