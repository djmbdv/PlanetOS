// VFS path resolution over the read-only XFS root and the writable RAMFS
// directories. Paths are always resolved from the root; the shell turns its
// working directory into an absolute path before calling a syscall.

namespace Planet.Kernel {

    public class Vfs : Object {
        public const int KIND_NONE = 0;
        public const int KIND_XFS = 1;
        public const int KIND_FILE = 2;
        public const int KIND_DIR = 3;

        private static int byte_at (int addr) {
            int w = mmio_read32 (addr & ~3);
            return (w >> ((addr & 3) * 8)) & 0xFF;
        }

        private static bool is_dot (int ptr, int len) {
            return len == 1 && byte_at (ptr) == '.';
        }

        private static bool is_dotdot (int ptr, int len) {
            return len == 2 && byte_at (ptr) == '.' && byte_at (ptr + 1) == '.';
        }

        public static bool reserved_name (int ptr, int len) {
            return is_dot (ptr, len) || is_dotdot (ptr, len);
        }

        private static int parent_dir (int dir) {
            if (dir < 0)
                return -1;
            return Ramfs.parent_of (dir);
        }

        public static bool is_descendant (int dir, int ancestor) {
            int cur = dir;
            while (true) {
                if (cur == ancestor)
                    return true;
                if (cur < 0)
                    return false;
                cur = Ramfs.parent_of (cur);
            }
        }

        // Resolves an existing path. `id` receives the XFS inode (KIND_XFS) or
        // the RAMFS slot (KIND_FILE/KIND_DIR; -1 for the root directory).
        public static int resolve (int path_ptr, int path_len, out int id) {
            id = -1;
            if (path_len <= 0)
                return KIND_DIR;
            if (path_ptr == 0 || path_len > 4096)
                return KIND_NONE;
            int dir = -1;
            int i = 0;
            while (i < path_len) {
                while (i < path_len && byte_at (path_ptr + i) == '/')
                    i = i + 1;
                if (i >= path_len)
                    break;
                int start = i;
                while (i < path_len && byte_at (path_ptr + i) != '/') {
                    if (byte_at (path_ptr + i) == 0)
                        return KIND_NONE;
                    i = i + 1;
                }
                int clen = i - start;
                if (clen > 255)
                    return KIND_NONE;
                bool last = true;
                int k = i;
                while (k < path_len) {
                    if (byte_at (path_ptr + k) != '/') {
                        last = false;
                        break;
                    }
                    k = k + 1;
                }
                if (is_dot (path_ptr + start, clen)) {
                    if (last) {
                        id = dir;
                        return KIND_DIR;
                    }
                    continue;
                }
                if (is_dotdot (path_ptr + start, clen)) {
                    if (last) {
                        id = parent_dir (dir);
                        return KIND_DIR;
                    }
                    dir = parent_dir (dir);
                    continue;
                }
                if (!last) {
                    int child = Ramfs.find_in (dir, path_ptr + start, clen);
                    if (child < 0 || Ramfs.kind_of (child) != 2)
                        return KIND_NONE;
                    dir = child;
                    continue;
                }
                int slot = Ramfs.find_in (dir, path_ptr + start, clen);
                if (slot >= 0) {
                    id = slot;
                    return (Ramfs.kind_of (slot) == 2) ? KIND_DIR : KIND_FILE;
                }
                if (dir == -1) {
                    int ino = Xfs.lookup_root (path_ptr + start, clen);
                    if (ino > 0) {
                        id = ino;
                        return KIND_XFS;
                    }
                }
                return KIND_NONE;
            }
            id = dir;
            return KIND_DIR;
        }

        // Splits a path into the parent directory and its last component.
        // Returns the parent RAMFS slot (-1 for the root) or -2 if the parent
        // does not exist or is not a directory.
        public static int resolve_parent (int path_ptr, int path_len, out int base_ptr, out int base_len) {
            base_ptr = 0;
            base_len = 0;
            int end = path_len;
            while (end > 0 && byte_at (path_ptr + end - 1) == '/')
                end = end - 1;
            if (end == 0)
                return -2;
            int bstart = end;
            while (bstart > 0 && byte_at (path_ptr + bstart - 1) != '/')
                bstart = bstart - 1;
            base_ptr = path_ptr + bstart;
            base_len = end - bstart;
            if (bstart == 0)
                return -1;
            int pid = -1;
            int pkind = resolve (path_ptr, bstart - 1, out pid);
            if (pkind != KIND_DIR)
                return -2;
            return pid;
        }
    }
}
