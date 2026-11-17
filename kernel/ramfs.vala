// In-memory writable RAMFS backed by 4 KiB PMM pages for PlanetOS VFS.

namespace Planet.Kernel {

    public class Ramfs : Object {
        private const int MAX_FILES = 32;
        private const int SLOT_SIZE = 256;
        private const int MAX_NAME = 64;
        private const int MAX_PAGES = 20; // 80 KiB max per RAMFS file

        // Slot layout (256 bytes):
        // +0:   kind (8B: 0 free, 1 file, 2 directory)
        // +8:   size (8B)
        // +16:  name_len (8B)
        // +24:  name[64]
        // +88:  page_addrs[20] (160B)
        // +248: parent slot (8B, -1 = root)

        private static int read_u8 (int addr) {
            int w = mmio_read32 (addr & ~3);
            return (w >> ((addr & 3) * 8)) & 0xFF;
        }

        public static void init () {
            for (int i = 0; i < (MAX_FILES * SLOT_SIZE) / 8; i++) {
                mmio_write64 (KernelLayout.RAMFS_TABLE + i * 8, 0);
            }
        }

        public static int kind_of (int s) {
            if (s < 0 || s >= MAX_FILES)
                return 0;
            return mmio_read64 (KernelLayout.RAMFS_TABLE + s * SLOT_SIZE);
        }

        public static int parent_of (int s) {
            if (s < 0 || s >= MAX_FILES)
                return -1;
            return mmio_read64 (KernelLayout.RAMFS_TABLE + s * SLOT_SIZE + 248);
        }

        public static int find_in (int parent, int name_ptr, int name_len) {
            if (name_len <= 0 || name_len > MAX_NAME)
                return -1;
            for (int s = 0; s < MAX_FILES; s++) {
                int slot = KernelLayout.RAMFS_TABLE + s * SLOT_SIZE;
                if (mmio_read64 (slot) == 0)
                    continue;
                if (mmio_read64 (slot + 248) != parent)
                    continue;
                int slen = mmio_read64 (slot + 16);
                if (slen != name_len)
                    continue;
                bool eq = true;
                for (int i = 0; i < name_len; i++) {
                    if (read_u8 (slot + 24 + i) != read_u8 (name_ptr + i)) {
                        eq = false;
                        break;
                    }
                }
                if (eq)
                    return s;
            }
            return -1;
        }

        public static int create_in (int parent, int name_ptr, int name_len, int kind) {
            if (name_len <= 0 || name_len > MAX_NAME)
                return -1;
            if (kind != 1 && kind != 2)
                return -1;
            int existing = find_in (parent, name_ptr, name_len);
            if (existing >= 0) {
                if (kind_of (existing) != kind)
                    return -1;
                if (kind == 2)
                    return -1;
                int slot = KernelLayout.RAMFS_TABLE + existing * SLOT_SIZE;
                for (int p = 0; p < MAX_PAGES; p++) {
                    int pa = mmio_read64 (slot + 88 + p * 8);
                    if (pa != 0) {
                        Pmm.free_frame (pa);
                        mmio_write64 (slot + 88 + p * 8, 0);
                    }
                }
                mmio_write64 (slot + 8, 0);
                return existing;
            }
            for (int s = 0; s < MAX_FILES; s++) {
                int slot = KernelLayout.RAMFS_TABLE + s * SLOT_SIZE;
                if (mmio_read64 (slot) == 0) {
                    mmio_write64 (slot + 0, kind);
                    mmio_write64 (slot + 8, 0);
                    mmio_write64 (slot + 16, name_len);
                    for (int i = 0; i < name_len; i++) {
                        mmio_write8 (slot + 24 + i, read_u8 (name_ptr + i));
                    }
                    for (int p = 0; p < MAX_PAGES; p++) {
                        mmio_write64 (slot + 88 + p * 8, 0);
                    }
                    mmio_write64 (slot + 248, parent);
                    return s;
                }
            }
            return -1;
        }

        public static bool has_children (int s) {
            for (int i = 0; i < MAX_FILES; i++) {
                int slot = KernelLayout.RAMFS_TABLE + i * SLOT_SIZE;
                if (mmio_read64 (slot) == 0)
                    continue;
                if (mmio_read64 (slot + 248) == s)
                    return true;
            }
            return false;
        }

        public static int unlink_slot (int s) {
            if (kind_of (s) == 0)
                return -1;
            int slot = KernelLayout.RAMFS_TABLE + s * SLOT_SIZE;
            for (int p = 0; p < MAX_PAGES; p++) {
                int pa = mmio_read64 (slot + 88 + p * 8);
                if (pa != 0) {
                    Pmm.free_frame (pa);
                    mmio_write64 (slot + 88 + p * 8, 0);
                }
            }
            mmio_write64 (slot + 0, 0);
            mmio_write64 (slot + 8, 0);
            mmio_write64 (slot + 16, 0);
            mmio_write64 (slot + 248, 0);
            return 0;
        }

        public static int rename_to (int s, int new_parent, int new_ptr, int new_len) {
            if (kind_of (s) == 0)
                return -1;
            if (new_len <= 0 || new_len > MAX_NAME)
                return -1;
            int existing = find_in (new_parent, new_ptr, new_len);
            if (existing >= 0 && existing != s)
                return -1;
            int slot = KernelLayout.RAMFS_TABLE + s * SLOT_SIZE;
            int old_len = mmio_read64 (slot + 16);
            for (int i = 0; i < new_len; i++) {
                mmio_write8 (slot + 24 + i, read_u8 (new_ptr + i));
            }
            for (int i = new_len; i < old_len; i++) {
                mmio_write8 (slot + 24 + i, 0);
            }
            mmio_write64 (slot + 16, new_len);
            mmio_write64 (slot + 248, new_parent);
            return 0;
        }

        public static int file_size (int s) {
            if (kind_of (s) == 0)
                return -1;
            return mmio_read64 (KernelLayout.RAMFS_TABLE + s * SLOT_SIZE + 8);
        }

        public static int read (int s, int pos, int dst_buf, int count) {
            if (kind_of (s) != 1)
                return -1;
            int fsz = file_size (s);
            if (fsz < 0 || pos >= fsz || count <= 0)
                return 0;
            int rem = fsz - pos;
            int n = (count < rem) ? count : rem;
            int slot = KernelLayout.RAMFS_TABLE + s * SLOT_SIZE;
            for (int i = 0; i < n; i++) {
                int off = pos + i;
                int pg_idx = off / 4096;
                int pg_off = off & 4095;
                int pa = mmio_read64 (slot + 88 + pg_idx * 8);
                int b = (pa != 0) ? read_u8 (pa + pg_off) : 0;
                mmio_write8 (dst_buf + i, b);
            }
            return n;
        }

        public static int write (int s, int pos, int src_buf, int count) {
            if (kind_of (s) != 1 || pos < 0 || count <= 0)
                return -1;
            int slot = KernelLayout.RAMFS_TABLE + s * SLOT_SIZE;
            int written = 0;
            for (int i = 0; i < count; i++) {
                int off = pos + i;
                int pg_idx = off / 4096;
                if (pg_idx >= MAX_PAGES)
                    break;
                int pa = mmio_read64 (slot + 88 + pg_idx * 8);
                if (pa == 0) {
                    pa = Pmm.alloc_frame ();
                    if (pa == 0)
                        break;
                    mmio_write64 (slot + 88 + pg_idx * 8, pa);
                }
                int pg_off = off & 4095;
                mmio_write8 (pa + pg_off, read_u8 (src_buf + i));
                written = written + 1;
            }
            int end_pos = pos + written;
            int cur_sz = mmio_read64 (slot + 8);
            if (end_pos > cur_sz)
                mmio_write64 (slot + 8, end_pos);
            return written;
        }

        public static int list_children (int parent, int dst_buf, int max_bytes) {
            if (max_bytes <= 0)
                return 0;
            int pos = 0;
            for (int s = 0; s < MAX_FILES; s++) {
                int slot = KernelLayout.RAMFS_TABLE + s * SLOT_SIZE;
                if (mmio_read64 (slot) == 0)
                    continue;
                if (mmio_read64 (slot + 248) != parent)
                    continue;
                int nlen = mmio_read64 (slot + 16);
                for (int i = 0; i < nlen; i++) {
                    if (pos < max_bytes) {
                        mmio_write8 (dst_buf + pos, read_u8 (slot + 24 + i));
                        pos = pos + 1;
                    }
                }
                if (pos < max_bytes) {
                    mmio_write8 (dst_buf + pos, '\n');
                    pos = pos + 1;
                }
            }
            return pos;
        }

        public static int list (int dst_buf, int max_bytes) {
            return list_children (-1, dst_buf, max_bytes);
        }
    }
}
