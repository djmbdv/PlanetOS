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

    [AsmBody(@"
        # data pointer of an int[] (header is 16 bytes)
        add $16, %rdi
        mov %rdi, %rax
        ret
    ")]
    private extern int __iarr_data (int[] a);

    [AsmBody(@"
        # __call_ptr2(fn in rdi, a0 in rsi, a1 in rdx) -> rax
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        .byte 0xff, 0xd0
        ret
    ")]
    private extern int __call_ptr2 (int fn_addr, int a0, int a1);

    [AsmBody(@"
        # __call_ptr3(fn in rdi, a0 in rsi, a1 in rdx, a2 in rcx) -> rax
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        mov %rcx, %rdx
        .byte 0xff, 0xd0
        ret
    ")]
    private extern int __call_ptr3 (int fn_addr, int a0, int a1, int a2);

    [AsmBody(@"
        # __call_ptr_d1(fn in rdi, x in xmm0) -> xmm0
        .byte 0xff, 0xd7
        ret
    ")]
    private extern double __call_ptr_d1 (int fn_addr, double x);

    [AsmBody(@"
        # __call_ptr_d2(fn in rdi, a in xmm0, b in xmm1) -> xmm0
        .byte 0xff, 0xd7
        ret
    ")]
    private extern double __call_ptr_d2 (int fn_addr, double a, double b);

    [AsmBody(@"
        # __call_ptr_i2d(fn in rdi, a0 in rsi, a1 in rdx) -> xmm0
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        .byte 0xff, 0xd0
        ret
    ")]
    private extern double __call_ptr_i2d (int fn_addr, int a0, int a1);

    [AsmBody(@"
        # data pointer of a double[] (header is 16 bytes)
        add $16, %rdi
        mov %rdi, %rax
        ret
    ")]
    private extern int __darr_data (double[] a);

    [AsmBody(@"
        # __sys_poke8(addr in rdi, val in rsi)
        mov %sil, (%rdi)
        ret
    ")]
    private extern void __sys_poke8 (int addr, int val);

    [AsmBody(@"
        # __sys_peek32(addr in rdi) -> eax
        mov (%rdi), %eax
        ret
    ")]
    private extern int __sys_peek32 (int addr);

    [AsmBody(@"
        # __sys_poke32(addr in rdi, val in esi)
        mov %esi, (%rdi)
        ret
    ")]
    private extern void __sys_poke32 (int addr, int val);

    public class Sys : Object {
        public const int MAX_PATH = 512;
        // One int 0x80 transfer; Sys.read/write chunk larger requests behind it
        // so no caller has to know about this limit.
        public const int MAX_IO = 65536;
        public const int MAX_FDS = 16;
        public const int USER_MIN_ADDR = 0x1000;
        public const int USER_MAX_ADDR = 0x40000000;
        public const int MAX_KLOG_RECORDS = 1024;

        // errno values, mirrored from the kernel (SYS_ERRNO).
        public const int EIO = 5;
        public const int EBADF = 9;
        public const int ENOENT = 2;
        public const int EACCES = 13;
        public const int EEXIST = 17;
        public const int ENOTDIR = 20;
        public const int EISDIR = 21;
        public const int EINVAL = 22;
        public const int ENOSPC = 28;
        public const int EPIPE = 32;
        public const int ETIMEDOUT = 110;

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

        public static int rtc_time () {
            return __sys4 (34, 0, 0, 0, 0);
        }

        public static int tid () {
            return __sys4 (62, 0, 0, 0, 0);
        }

        public static string getenv (string key) {
            if (key.length == 0 || key.length > MAX_PATH)
                return "";
            var buf = new uint8[512];
            int n = __sys4 (35, __str_data (key), key.length, __arr_data (buf), 512);
            if (n <= 0)
                return "";
            int len = 0;
            for (int i = 0; i < n; i++) {
                uint8 c = buf[i];
                if (c >= 32 && c <= 126) {
                    buf[len] = c;
                    len = len + 1;
                }
            }
            if (len == 0)
                return "";
            return __planc_host_bytes_to_str (buf, len);
        }

        public static int setenv (string key, string val) {
            if (key.length == 0 || key.length > MAX_PATH || val.length > MAX_IO)
                return -1;
            return __sys4 (36, __str_data (key), key.length, __str_data (val), val.length);
        }

        public static int unsetenv (string key) {
            if (key.length == 0 || key.length > MAX_PATH)
                return -1;
            return __sys4 (36, __str_data (key), key.length, 0, 0);
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
            if (addr < 0x100000 || (addr & 0xFFF) != 0)
                return -1;
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
            if (fd < 0 || count < 0 || count > buf.length)
                return -1;
            if (count == 0)
                return 0;
            int buf_addr = __arr_data (buf);
            int done = 0;
            while (done < count) {
                int want = count - done;
                if (want > MAX_IO)
                    want = MAX_IO;
                int r = __sys4 (7, fd, buf_addr + done, want, 0);
                if (r <= 0) {
                    if (done > 0)
                        break;
                    return r;
                }
                done = done + r;
                if (r < want)
                    break;
            }
            return done;
        }

        // Reads into an existing buffer at `offset`. This lets callers fill a
        // large destination directly instead of allocating a temporary slice
        // per read.
        public static int read_into (int fd, uint8[] buf, int offset, int count) {
            if (fd < 0 || offset < 0 || count < 0 || count > buf.length - offset)
                return -1;
            if (count == 0)
                return 0;
            int buf_addr = __arr_data (buf) + offset;
            int done = 0;
            while (done < count) {
                int want = count - done;
                if (want > MAX_IO)
                    want = MAX_IO;
                int r = __sys4 (7, fd, buf_addr + done, want, 0);
                if (r <= 0) {
                    if (done > 0)
                        break;
                    return r;
                }
                done = done + r;
                if (r < want)
                    break;
            }
            return done;
        }

        // Writes a slice of an existing buffer without copying it first.
        public static int write_from (int fd, uint8[] buf, int offset, int count) {
            if (fd < 0 || offset < 0 || count < 0 || count > buf.length - offset)
                return -1;
            if (count == 0)
                return 0;
            int buf_addr = __arr_data (buf) + offset;
            int done = 0;
            while (done < count) {
                int want = count - done;
                if (want > MAX_IO)
                    want = MAX_IO;
                int w = __sys4 (15, fd, buf_addr + done, want, 0);
                if (w <= 0) {
                    if (done > 0)
                        break;
                    return w;
                }
                done = done + w;
                if (w < want)
                    break;
            }
            return done;
        }

        public static int write (int fd, uint8[] buf, int count) {
            if (fd < 0 || count < 0 || count > buf.length)
                return -1;
            if (count == 0)
                return 0;
            int buf_addr = __arr_data (buf);
            int done = 0;
            while (done < count) {
                int want = count - done;
                if (want > MAX_IO)
                    want = MAX_IO;
                int w = __sys4 (15, fd, buf_addr + done, want, 0);
                if (w <= 0) {
                    if (done > 0)
                        break;
                    return w;
                }
                done = done + w;
                if (w < want)
                    break;
            }
            return done;
        }

        public static int write_str (int fd, string s, int count) {
            if (fd < 0 || count < 0 || count > s.length)
                return -1;
            if (count == 0)
                return 0;
            int str_addr = __str_data (s);
            int done = 0;
            while (done < count) {
                int want = count - done;
                if (want > MAX_IO)
                    want = MAX_IO;
                int w = __sys4 (15, fd, str_addr + done, want, 0);
                if (w <= 0) {
                    if (done > 0)
                        break;
                    return w;
                }
                done = done + w;
                if (w < want)
                    break;
            }
            return done;
        }

        public static int file_size (int fd) {
            if (fd < 3)
                return -1;
            return __sys4 (9, fd, 0, 0, 0);
        }

        // --- errors and metadata --------------------------------------------

        // Last error of this process, set by the kernel on a failing syscall.
        public static int errno_code () {
            return __sys4 (54, 0, 0, 0, 0);
        }

        public static string strerror (int err) {
            if (err == ENOENT) return "no such file or directory";
            if (err == EACCES) return "permission denied";
            if (err == EEXIST) return "already exists";
            if (err == ENOTDIR) return "not a directory";
            if (err == EISDIR) return "is a directory";
            if (err == EINVAL) return "invalid argument";
            if (err == ENOSPC) return "no space left on device";
            if (err == EPIPE) return "broken pipe";
            if (err == ETIMEDOUT) return "timed out";
            if (err == EIO) return "input/output error";
            return "error";
        }

        // Kind (0 none, 1 file, 2 dir) and byte size, with errno on failure.
        public static int stat_ex (string path, out int size) {
            size = 0;
            if (!path_ok (path))
                return 0;
            var buf = new uint8[16];
            int r = __sys4 (55, __str_data (path), path.length, __arr_data (buf), 0);
            if (r < 0)
                return 0;
            size = (int) ((uint32) buf[4] | ((uint32) buf[5] << 8)
                          | ((uint32) buf[6] << 16) | ((uint32) buf[7] << 24));
            return buf[0];
        }

        // --- waiting --------------------------------------------------------

        // Blocks until *addr != expected or the timeout elapses (0 = forever).
        // Returns 0 when the value changed, -1 on error (ETIMEDOUT).
        public static int wait_addr (int[] word, int expected, int timeout_ms) {
            return __sys4 (57, __iarr_data (word), expected, timeout_ms, 0);
        }

        public static int wake_addr (int[] word, int count) {
            return __sys4 (58, __iarr_data (word), count, 0, 0);
        }

        public static int sleep_ms (int ms) {
            return __sys4 (60, ms, 0, 0, 0);
        }

        // Waits until one of `fds` is ready; returns a bitmask of ready
        // entries (bit i = fds[i]), 0 on timeout, -1 on error.
        public static int poll (int[] fds, int timeout_ms) {
            return __sys4 (59, __iarr_data (fds), fds.length, timeout_ms, 0);
        }

        // Polls the first `nfds` entries of a reusable buffer.
        public static int poll_n (int[] fds, int nfds, int timeout_ms) {
            if (nfds < 0 || nfds > fds.length)
                return -1;
            return __sys4 (59, __iarr_data (fds), nfds, timeout_ms, 0);
        }

        public static int int_arr_addr (int[] a) {
            return __iarr_data (a);
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
            if (!path_ok (name) || cmdline.length > MAX_IO)
                return -1;
            return __sys4 (13, __str_data (name), name.length, __str_data (cmdline), 0);
        }

        public static int spawn (string name, string cmdline) {
            if (!path_ok (name) || cmdline.length > MAX_IO)
                return -1;
            return __sys4 (16, __str_data (name), name.length, __str_data (cmdline), 0);
        }

        public static int wait (int tid) {
            return __sys4 (17, tid, 0, 0, 0);
        }

        public static int wait_nb (int tid) {
            return __sys4 (48, tid, 0, 0, 0);
        }

        public static int kill (int tid) {
            return __sys4 (49, tid, 0, 0, 0);
        }

        public static int map_user_at (int vaddr, int size) {
            // The kernel owns the real floor (the first frame the Pmm can hand
            // out) because this call is also how a client attaches a surface the
            // compositor allocated, which often lands below 16 MiB.
            if (vaddr < USER_MIN_ADDR || size <= 0 || size > 0x800000 || vaddr + size > USER_MAX_ADDR)
                return -1;
            return __sys4 (50, vaddr, size, 0, 0);
        }

        // A2: turns a block this task owns into a capability, and lets another
        // task map it without owning the frames.
        public static int grant (int addr, int len) {
            return __sys4 (63, addr, len, 0, 0);
        }

        public static int grant_share (int handle, int tid) {
            return __sys4 (64, handle, tid, 0, 0);
        }

        public static int protect_user_ro (int vaddr, int size) {
            if (vaddr < USER_MIN_ADDR || size <= 0 || size > 0x800000 || vaddr + size > USER_MAX_ADDR)
                return -1;
            return __sys4 (52, vaddr, size, 0, 0);
        }

        public static int map_user_ro_at (int vaddr, int size) {
            if (vaddr < USER_MIN_ADDR || size <= 0 || size > 0x800000 || vaddr + size > USER_MAX_ADDR)
                return -1;
            return __sys4 (53, vaddr, size, 0, 0);
        }

        public static void poke8 (int addr, int val) {
            if (addr < USER_MIN_ADDR)
                return;
            __sys_poke8 (addr, val);
        }

        // 32-bit word accessors, used by the shared window-surface protocol: the
        // header is a handful of words both processes read and write in place.
        public static int peek32 (int addr) {
            if (addr < USER_MIN_ADDR || addr > USER_MAX_ADDR - 4)
                return 0;
            return __sys_peek32 (addr);
        }

        public static void poke32 (int addr, int val) {
            if (addr < USER_MIN_ADDR || addr > USER_MAX_ADDR - 4)
                return;
            __sys_poke32 (addr, val);
        }

        public static int call_ptr2 (int fn_addr, int a0, int a1) {
            if (fn_addr < USER_MIN_ADDR)
                return -1;
            return __call_ptr2 (fn_addr, a0, a1);
        }

        public static int call_ptr3 (int fn_addr, int a0, int a1, int a2) {
            if (fn_addr < USER_MIN_ADDR)
                return -1;
            return __call_ptr3 (fn_addr, a0, a1, a2);
        }

        public static double call_ptr_d1 (int fn_addr, double x) {
            if (fn_addr < USER_MIN_ADDR)
                return 0.0;
            return __call_ptr_d1 (fn_addr, x);
        }

        public static double call_ptr_d2 (int fn_addr, double a, double b) {
            if (fn_addr < USER_MIN_ADDR)
                return 0.0;
            return __call_ptr_d2 (fn_addr, a, b);
        }

        public static double call_ptr_i2d (int fn_addr, int a0, int a1) {
            if (fn_addr < USER_MIN_ADDR)
                return 0.0;
            return __call_ptr_i2d (fn_addr, a0, a1);
        }

        public static int double_arr_addr (double[] a) {
            return __darr_data (a);
        }

        // Data pointer of a Vala string (without its 16-byte header).
        public static int str_addr (string s) {
            return __str_data (s);
        }

        public static int byte_arr_addr (uint8[] a) {
            return __arr_data (a);
        }

        public static int list_tasks (uint8[] buf, int max_bytes) {
            if (!range_ok (buf, max_bytes))
                return -1;
            return __sys4 (18, __arr_data (buf), max_bytes, 0, 0);
        }

        public static int set_stdio (int in_fd, int out_fd) {
            // Handles are opaque values (`index | generation << 8`), so the
            // only local check is the -1 sentinel; the kernel validates them.
            if (in_fd != -1 && in_fd < 3)
                return -1;
            if (out_fd != -1 && out_fd < 3)
                return -1;
            return __sys4 (19, in_fd, out_fd, 0, 0);
        }

        // --- VirtIO-GPU / Venus 3D -----------------------------------------

        public static int gpu_info () {
            return __sys4 (37, 0, 0, 0, 0);
        }

        public static int gpu_ctx_create (int ctx_id, int capset_id) {
            return __sys4 (38, ctx_id, capset_id, 0, 0);
        }

        public static int gpu_ctx_destroy (int ctx_id) {
            return __sys4 (39, ctx_id, 0, 0, 0);
        }

        public static int gpu_submit_3d (int ctx_id, uint8[] cmd_buf, int cmd_bytes) {
            if (!range_ok (cmd_buf, cmd_bytes))
                return -1;
            return __sys4 (40, ctx_id, __arr_data (cmd_buf), cmd_bytes, 0);
        }

        public static int gpu_cursor_move (int x, int y) {
            return __sys4 (41, x, y, 0, 0);
        }

        public static int gpu_cursor_set (uint8[] rgba_64x64, int hot_x, int hot_y) {
            if (!range_ok (rgba_64x64, 16384))
                return -1;
            return __sys4 (42, __arr_data (rgba_64x64), hot_x, hot_y, 0);
        }

        public static int gpu_blob_create (int ctx_id, int res_id, int size) {
            if (size <= 0)
                return 0;
            return __sys4 (43, ctx_id, res_id, size, 0);
        }

        public static int gpu_resource_destroy (int ctx_id, int res_id, int pa, int size) {
            if (pa != 0 && pa < 0x100000)
                return -1;
            return __sys4 (46, ctx_id, res_id, pa, size);
        }

        public static int gpu_3d_create (int ctx_id, int res_id, int width, int height) {
            if (width <= 0 || height <= 0 || width > 4096 || height > 4096)
                return 0;
            return __sys4 (47, ctx_id, res_id, width, height);
        }

        public static int gpu_3d_readback (int ctx_id, int res_id, int width, int height) {
            if (width <= 0 || height <= 0 || width > 4096 || height > 4096)
                return -1;
            return __sys4 (51, ctx_id, res_id, width, height);
        }

        // --- kernel log ----------------------------------------------------

        // Copies up to `max_records` 64-byte records into `buf`, oldest first.
        public static int klog_read (uint8[] buf, int max_records) {
            if (max_records <= 0 || max_records > MAX_KLOG_RECORDS || buf.length < max_records * 64)
                return -1;
            return __sys4 (44, __arr_data (buf), max_records, 0, 0);
        }

        // Same, for callers that already hold a raw page address.
        public static int klog_read_at (int addr, int max_records) {
            if (addr < USER_MIN_ADDR || max_records <= 0 || max_records > MAX_KLOG_RECORDS)
                return -1;
            return __sys4 (44, addr, max_records, 0, 0);
        }

        public static int klog_set_level (int level) {
            return __sys4 (45, 0, level, 0, 0);
        }

        public static int klog_set_category (int cat, bool on) {
            return __sys4 (45, 1, cat, on ? 1 : 0, 0);
        }

        public static int klog_clear () {
            return __sys4 (45, 2, 0, 0, 0);
        }

        // level in the low byte, category mask in the next one
        public static int klog_state () {
            return __sys4 (45, 3, 0, 0, 0);
        }

        public static int klog_total () {
            return __sys4 (45, 4, 0, 0, 0);
        }

        // Appends a record to the kernel ring: category (0..7), level
        // (0 error, 1 warn, 2 info, 3 debug) and the message bytes.
        public static int klog_write (int cat, int level, string msg) {
            return __sys4 (56, cat, level, __str_data (msg), msg.length);
        }

        // Version of the syscall ABI this binary was built against; compared
        // with SYS_ABI_VERSION at load time by the dlib users.
        public const int ABI_VERSION = 2;

        public static int abi_version () {
            return __sys4 (61, 0, 0, 0, 0);
        }
    }
}
