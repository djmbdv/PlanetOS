// Central userland syscall layer for PlanetOS.
//
// Only three small machine-code primitives live here:
//   __sys4      - the int 0x80 trampoline (rax=num, rdi/rsi/rdx/r8 = args)
//   __str_data  - data pointer of a Vala string (skips its 16-byte header)
//   __arr_data  - data pointer of a uint8[] (skips its 16-byte header)
//
// Every syscall is a typed Vala wrapper on top of those, so the calling
// convention is written once and each argument is checked before it reaches
// the kernel. Callers that need the raw form can use Sys.sys()/Sys.sys4().

namespace Planet {

    [AsmBody(@"
        # __sys4(num in rdi, a0 in rsi, a1 in rdx, a2 in rcx, a3 in r8)
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        mov %rcx, %rdx
        int $0x80
        ret
    ")]
    private extern int __sys4 (int num, int a0, int a1, int a2, int a3);

    [AsmBody(@"
        # data pointer of a string (header is 16 bytes)
        add $16, %rdi
        mov %rdi, %rax
        ret
    ")]
    private extern int __str_data (string s);

    [AsmBody(@"
        # data pointer of a uint8[] (header is 16 bytes)
        add $16, %rdi
        mov %rdi, %rax
        ret
    ")]
    private extern int __arr_data (uint8[] a);

    public class Sys : Object {
        public const int MAX_PATH = 512;
        public const int MAX_IO = 65536;

        // --- raw forms -----------------------------------------------------

        public static int sys (int num, int a0, int a1, int a2) {
            return __sys4 (num, a0, a1, a2, 0);
        }

        public static int sys4 (int num, int a0, int a1, int a2, int a3) {
            return __sys4 (num, a0, a1, a2, a3);
        }

        // --- helpers -------------------------------------------------------

        private static bool path_ok (string path) {
            return path.length > 0 && path.length <= MAX_PATH;
        }

        private static bool range_ok (uint8[] buf, int count) {
            return count >= 0 && count <= buf.length && count <= MAX_IO;
        }

        // --- console and time ----------------------------------------------

        public static int console_write (uint8[] buf, int count) {
            if (!range_ok (buf, count))
                return -1;
            return __sys4 (15, 1, __arr_data (buf), count, 0);
        }

        public static int ticks () {
            return __sys4 (2, 0, 0, 0, 0);
        }

        public static int yield_cpu () {
            return __sys4 (10, 0, 0, 0, 0);
        }

        public static int read_key () {
            return __sys4 (5, 0, 0, 0, 0);
        }

        // --- keyboard modifiers -------------------------------------------

        public const int MOD_SHIFT = 1;
        public const int MOD_CTRL = 2;
        public const int MOD_ALT = 4;
        public const int MOD_SUPER = 8;

        public static int key_mods () {
            return __sys4 (33, 0, 0, 0, 0);
        }

        public static bool mod_alt () { return (key_mods () & MOD_ALT) != 0; }
        public static bool mod_super () { return (key_mods () & MOD_SUPER) != 0; }
        public static bool mod_ctrl () { return (key_mods () & MOD_CTRL) != 0; }

        // --- memory --------------------------------------------------------

        public static int alloc_pages (int pages) {
            // 1024 pages = 4 MiB, enough for an 800x600x4 framebuffer (469 pages).
            if (pages <= 0 || pages > 1024)
                return -1;
            return __sys4 (3, pages, 0, 0, 0);
        }

        public static int free_page (int addr) {
            return __sys4 (4, addr, 0, 0, 0);
        }

        // --- files ---------------------------------------------------------

        public static int open (string path) {
            if (!path_ok (path))
                return -1;
            return __sys4 (6, __str_data (path), path.length, 0, 0);
        }

        public static int create (string path) {
            if (!path_ok (path))
                return -1;
            return __sys4 (14, __str_data (path), path.length, 0, 0);
        }

        public static int close (int fd) {
            if (fd < 3)
                return -1;
            return __sys4 (8, fd, 0, 0, 0);
        }

        public static int read (int fd, uint8[] buf, int count) {
            if (fd < 0 || !range_ok (buf, count))
                return -1;
            return __sys4 (7, fd, __arr_data (buf), count, 0);
        }

        public static int write (int fd, uint8[] buf, int count) {
            if (fd < 0 || !range_ok (buf, count))
                return -1;
            return __sys4 (15, fd, __arr_data (buf), count, 0);
        }

        public static int write_str (int fd, string s, int count) {
            if (fd < 0 || count < 0 || count > s.length || count > MAX_IO)
                return -1;
            return __sys4 (15, fd, __str_data (s), count, 0);
        }

        public static int file_size (int fd) {
            if (fd < 3)
                return -1;
            return __sys4 (9, fd, 0, 0, 0);
        }

        public static int seek (int fd, int offset) {
            if (fd < 3)
                return -1;
            return __sys4 (20, fd, offset, 0, 0);
        }

        public static int unlink (string path) {
            if (!path_ok (path))
                return -1;
            return __sys4 (28, __str_data (path), path.length, 0, 0);
        }

        public static int mkdir (string path) {
            if (!path_ok (path))
                return -1;
            return __sys4 (30, __str_data (path), path.length, 0, 0);
        }

        public static int stat (string path) {
            if (!path_ok (path))
                return 0;
            return __sys4 (32, __str_data (path), path.length, 0, 0);
        }

        public static int rename (string old_path, string new_path) {
            if (!path_ok (old_path) || !path_ok (new_path))
                return -1;
            return __sys4 (29, __str_data (old_path), old_path.length,
                           __str_data (new_path), new_path.length);
        }

        public static int readdir_path (string path, uint8[] buf, int max_bytes) {
            if (!path_ok (path) || !range_ok (buf, max_bytes))
                return -1;
            return __sys4 (31, __str_data (path), path.length, __arr_data (buf), max_bytes);
        }

        // --- processes -----------------------------------------------------

        public static int exec (string name, string cmdline) {
            if (!path_ok (name))
                return -1;
            return __sys4 (13, __str_data (name), name.length, __str_data (cmdline), 0);
        }

        public static int spawn (string name, string cmdline) {
            if (!path_ok (name))
                return -1;
            return __sys4 (16, __str_data (name), name.length, __str_data (cmdline), 0);
        }

        public static int wait (int tid) {
            return __sys4 (17, tid, 0, 0, 0);
        }

        public static int list_tasks (uint8[] buf, int max_bytes) {
            if (!range_ok (buf, max_bytes))
                return -1;
            return __sys4 (18, __arr_data (buf), max_bytes, 0, 0);
        }

        public static int set_stdio (int in_fd, int out_fd) {
            return __sys4 (19, in_fd, out_fd, 0, 0);
        }
    }
}
