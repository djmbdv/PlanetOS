// Categorised kernel log: a ring of fixed records that subsystems write to and
// userland reads back with SYS_KLOG_READ, so a failure can be inspected after
// the fact instead of by adding prints and rebuilding.
//
// Nothing is emitted until a category is enabled, and the level filter keeps the
// default quiet: `log` in the shell shows the state, `log input debug` turns a
// subsystem up, `dmesg` prints what was recorded.
//
// Record layout in KernelLayout.KLOG_RING (64 bytes each):
//   +0  category       +4  level        +8  text length
//   +12 reserved       +16 tick         +24 text[40]

namespace Planet.Kernel {

    public sealed class Klog : Object {
        private const int REC_SIZE = 64;
        private const int REC_TEXT = 40;
        private const int REC_SLOTS = 128;

        // Runtime filter state.
        private static int klog_mask = 0xFF;   // all categories on
        private static int klog_level = 2;     // Klog.LVL_INFO
        private static int klog_head = 0;
        private static int klog_total = 0;
        // Categories. A category is enabled/disabled independently so one noisy
        // subsystem does not have to drown out the others.
        public const int CAT_BOOT  = 0;
        public const int CAT_INPUT = 1;
        public const int CAT_GPU   = 2;
        public const int CAT_MEM   = 3;
        public const int CAT_VFS   = 4;
        public const int CAT_SCHED = 5;
        public const int CAT_EXEC  = 6;
        public const int CAT_USER  = 7;
        public const int CAT_MAX   = 8;

        // Levels: records above the current level are dropped.
        public const int LVL_ERROR = 0;
        public const int LVL_WARN  = 1;
        public const int LVL_INFO  = 2;
        public const int LVL_DEBUG = 3;

        private static int slot_addr (int slot) {
            return KernelLayout.KLOG_RING + slot * REC_SIZE;
        }

        private static void store (int cat, int level, string msg) {
            int rec = slot_addr (klog_head);
            int len = msg.length;
            if (len > REC_TEXT)
                len = REC_TEXT;
            mmio_write32 (rec + 0, cat);
            mmio_write32 (rec + 4, level);
            mmio_write32 (rec + 8, len);
            mmio_write32 (rec + 12, 0);
            mmio_write32 (rec + 16, Hal.ticks ());
            for (int i = 0; i < REC_TEXT; i++)
                mmio_write8 (rec + 24 + i, 0);
            for (int i = 0; i < len; i++)
                mmio_write8 (rec + 24 + i, msg[i]);
            klog_head = (klog_head + 1) % REC_SLOTS;
            klog_total = klog_total + 1;
        }

        public static void write (int cat, int level, string msg) {
            if (cat < 0 || cat >= CAT_MAX || level < 0 || level > LVL_DEBUG)
                return;
            if ((klog_mask & (1 << cat)) == 0 || level > klog_level)
                return;
            store (cat, level, msg);
        }

        // Same as write (), but copies the text straight from a user buffer so
        // SYS_KLOG_WRITE does not have to build a Vala string first.
        public static void write_bytes (int cat, int level, int ptr, int len) {
            if (cat < 0 || cat >= CAT_MAX || level < 0 || level > LVL_DEBUG)
                return;
            if ((klog_mask & (1 << cat)) == 0 || level > klog_level)
                return;
            if (ptr == 0 || len <= 0)
                return;
            int rec = slot_addr (klog_head);
            int n = (len > REC_TEXT) ? REC_TEXT : len;
            mmio_write32 (rec + 0, cat);
            mmio_write32 (rec + 4, level);
            mmio_write32 (rec + 8, n);
            mmio_write32 (rec + 12, 0);
            mmio_write32 (rec + 16, Hal.ticks ());
            for (int i = 0; i < REC_TEXT; i++)
                mmio_write8 (rec + 24 + i, 0);
            for (int i = 0; i < n; i++)
                mmio_write8 (rec + 24 + i, mmio_read32 ((ptr + i) & ~3) >> ((ptr + i) & 3) * 8);
            klog_head = (klog_head + 1) % REC_SLOTS;
            klog_total = klog_total + 1;
        }

        public static void error (int cat, string msg) { write (cat, LVL_ERROR, msg); }
        public static void warn (int cat, string msg)  { write (cat, LVL_WARN, msg); }
        public static void info (int cat, string msg)  { write (cat, LVL_INFO, msg); }
        public static void debug (int cat, string msg) { write (cat, LVL_DEBUG, msg); }

        public static int level () {
            return klog_level;
        }

        public static int mask () {
            return klog_mask;
        }

        public static int total () {
            return klog_total;
        }

        public static void set_level (int level) {
            if (level >= LVL_ERROR && level <= LVL_DEBUG)
                klog_level = level;
        }

        public static void set_category (int cat, bool on) {
            if (cat < 0 || cat >= CAT_MAX)
                return;
            if (on)
                klog_mask = klog_mask | (1 << cat);
            else
                klog_mask = klog_mask & ~(1 << cat);
        }

        public static bool enabled (int cat) {
            if (cat < 0 || cat >= CAT_MAX)
                return false;
            return (klog_mask & (1 << cat)) != 0;
        }

        public static void clear () {
            klog_head = 0;
            klog_total = 0;
        }

        // Copies the last `max` records, oldest first, into userland. Returns
        // the number of records written; the caller must provide max * 64 bytes.
        public static int read_records (int out_ptr, int max) {
            if (out_ptr == 0 || max <= 0)
                return 0;
            int have = (klog_total < REC_SLOTS) ? klog_total : REC_SLOTS;
            int n = (have < max) ? have : max;
            int first = klog_head - n;
            while (first < 0)
                first = first + REC_SLOTS;
            for (int i = 0; i < n; i++) {
                int src = slot_addr ((first + i) % REC_SLOTS);
                int dst = out_ptr + i * REC_SIZE;
                for (int b = 0; b < REC_SIZE; b = b + 4)
                    mmio_write32 (dst + b, mmio_read32 (src + b));
            }
            return n;
        }
    }
}
