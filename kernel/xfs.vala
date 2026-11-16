// Read-only XFS (v4/v5 on-disk format) filesystem driver over ATA PIO.

namespace Planet.Kernel {

    private bool xfs_mounted = false;
    private int xfs_blocksize = 4096;
    private int xfs_agblocks = 0;
    private int xfs_agblklog = 0;
    private int xfs_inodesize = 256;
    private int xfs_inopblog = 0;
    private int xfs_rootino = 128;
    private int xfs_sec_buf = 0;

    public class Xfs : Object {

        private static int be16 (int addr) {
            int addr_aligned = addr & ~3;
            int w = mmio_read32 (addr_aligned);
            int shift = (addr & 3) * 8;
            int b0 = (w >> shift) & 0xFF;
            int b1;
            if ((addr & 3) < 3) {
                b1 = (w >> (shift + 8)) & 0xFF;
            } else {
                b1 = mmio_read32 (addr_aligned + 4) & 0xFF;
            }
            return (b0 << 8) | b1;
        }

        private static int be32 (int addr) {
            int b0 = read_u8 (addr);
            int b1 = read_u8 (addr + 1);
            int b2 = read_u8 (addr + 2);
            int b3 = read_u8 (addr + 3);
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
        }

        private static int be64 (int addr) {
            int hi = be32 (addr) & 0xFFFFFFFF;
            int lo = be32 (addr + 4) & 0xFFFFFFFF;
            return (hi << 32) | lo;
        }

        private static int read_u8 (int addr) {
            int w = mmio_read32 (addr & ~3);
            return (w >> ((addr & 3) * 8)) & 0xFF;
        }

        private static int fsbno_to_lba (int fsbno) {
            int ag = fsbno >> xfs_agblklog;
            int agbno = fsbno & ((1 << xfs_agblklog) - 1);
            int linear_blk = ag * xfs_agblocks + agbno;
            return linear_blk * (xfs_blocksize / 512);
        }

        public static bool mount () {
            if (xfs_sec_buf == 0)
                xfs_sec_buf = Pmm.alloc_frame ();
            if (xfs_sec_buf == 0)
                return false;
            if (!Ata.read_sector (0, xfs_sec_buf))
                return false;
            int magic = be32 (xfs_sec_buf);
            if (magic != 0x58465342) // "XFSB"
                return false;
            xfs_blocksize = be32 (xfs_sec_buf + 4);
            xfs_agblocks = be32 (xfs_sec_buf + 84);
            xfs_rootino = be64 (xfs_sec_buf + 56);
            xfs_inodesize = be16 (xfs_sec_buf + 104);
            xfs_agblklog = read_u8 (xfs_sec_buf + 124);
            xfs_inopblog = read_u8 (xfs_sec_buf + 123);
            xfs_mounted = true;
            return true;
        }

        private static bool load_inode (int ino, int buf) {
            if (!xfs_mounted)
                return false;
            int ag = ino >> (xfs_agblklog + xfs_inopblog);
            int rel = ino & ((1 << (xfs_agblklog + xfs_inopblog)) - 1);
            int agbno = rel >> xfs_inopblog;
            int idx = rel & ((1 << xfs_inopblog) - 1);
            int linear_blk = ag * xfs_agblocks + agbno;
            int byte_off = idx * xfs_inodesize;
            int lba = linear_blk * (xfs_blocksize / 512) + (byte_off / 512);
            if (!Ata.read_sector (lba, buf))
                return false;
            int off = byte_off & 511;
            int magic = be16 (buf + off);
            return magic == 0x494E; // "IN"
        }

        private static int inode_off (int ino) {
            int rel = ino & ((1 << (xfs_agblklog + xfs_inopblog)) - 1);
            int idx = rel & ((1 << xfs_inopblog) - 1);
            return (idx * xfs_inodesize) & 511;
        }

        private static bool name_matches (int dir_name_addr, int namelen, int target_ptr, int target_len) {
            if (namelen != target_len)
                return false;
            for (int i = 0; i < namelen; i++) {
                if (read_u8 (dir_name_addr + i) != read_u8 (target_ptr + i))
                    return false;
            }
            return true;
        }

        public static int lookup_root (int name_ptr, int name_len) {
            if (!xfs_mounted)
                return 0;
            if (!load_inode (xfs_rootino, xfs_sec_buf))
                return 0;
            int off = inode_off (xfs_rootino);
            int ino_base = xfs_sec_buf + off;
            int fmt = read_u8 (ino_base + 5);
            if (fmt != 1) // shortform directory
                return 0;
            int ver = read_u8 (ino_base + 4);
            int df = ino_base + ((ver >= 3) ? 176 : 100);
            int count = read_u8 (df);
            int i8count = read_u8 (df + 1);
            int cur = df + 4 + ((i8count > 0) ? 8 : 4);
            for (int i = 0; i < count; i++) {
                int nlen = read_u8 (cur);
                int name_addr = cur + 3;
                int ino_addr = name_addr + nlen;
                int child_ino = (i8count > 0) ? be64 (ino_addr) : (be32 (ino_addr) & 0xFFFFFFFF);
                if (name_matches (name_addr, nlen, name_ptr, name_len))
                    return child_ino;
                cur = ino_addr + ((i8count > 0) ? 8 : 4);
            }
            return 0;
        }

        public static int list_root (int buf, int max_bytes) {
            if (!xfs_mounted || max_bytes <= 0)
                return -1;
            if (!load_inode (xfs_rootino, xfs_sec_buf))
                return -1;
            int off = inode_off (xfs_rootino);
            int ino_base = xfs_sec_buf + off;
            int fmt = read_u8 (ino_base + 5);
            if (fmt != 1)
                return -1;
            int ver = read_u8 (ino_base + 4);
            int df = ino_base + ((ver >= 3) ? 176 : 100);
            int count = read_u8 (df);
            int i8count = read_u8 (df + 1);
            int cur = df + 4 + ((i8count > 0) ? 8 : 4);
            int pos = 0;
            for (int i = 0; i < count; i++) {
                int nlen = read_u8 (cur);
                int name_addr = cur + 3;
                int ino_addr = name_addr + nlen;
                for (int k = 0; k < nlen; k++) {
                    if (pos < max_bytes) {
                        mmio_write8 (buf + pos, read_u8 (name_addr + k));
                        pos = pos + 1;
                    }
                }
                if (pos < max_bytes) {
                    mmio_write8 (buf + pos, '\n');
                    pos = pos + 1;
                }
                cur = ino_addr + ((i8count > 0) ? 8 : 4);
            }
            return pos;
        }

        public static int file_size (int ino) {
            if (!load_inode (ino, xfs_sec_buf))
                return -1;
            int off = inode_off (ino);
            return be64 (xfs_sec_buf + off + 56);
        }

        public static int read_file (int ino, int dst_buf, int max_bytes) {
            if (!load_inode (ino, xfs_sec_buf))
                return -1;
            int off = inode_off (ino);
            int ino_base = xfs_sec_buf + off;
            int fsize = be64 (ino_base + 56);
            int to_read = (fsize < max_bytes) ? fsize : max_bytes;
            int fmt = read_u8 (ino_base + 5);
            int ver = read_u8 (ino_base + 4);
            int df = ino_base + ((ver >= 3) ? 176 : 100);
            if (fmt != 2) // extents
                return -1;
            int nextents = be32 (ino_base + 76);
            int copied = 0;
            int tmp = Pmm.alloc_frame ();
            if (tmp == 0)
                return -1;
            for (int e = 0; e < nextents && copied < to_read; e++) {
                int rec = df + e * 16;
                int w0 = be64 (rec);
                int w1 = be64 (rec + 8);
                int startblock = ((w0 & 0x1FF) << 43) | ((w1 >> 21) & 0x7FFFFFFFFFF);
                int blockcount = w1 & 0x1FFFFF;
                int lba = fsbno_to_lba (startblock);
                int total_secs = blockcount * (xfs_blocksize / 512);
                for (int s = 0; s < total_secs && copied < to_read; s++) {
                    if (!Ata.read_sector (lba + s, tmp)) {
                        Pmm.free_frame (tmp);
                        return copied;
                    }
                    int chunk = to_read - copied;
                    if (chunk > 512)
                        chunk = 512;
                    for (int bi = 0; bi < chunk; bi++) {
                        mmio_write8 (dst_buf + copied + bi, read_u8 (tmp + bi));
                    }
                    copied = copied + chunk;
                }
            }
            Pmm.free_frame (tmp);
            return copied;
        }
    }
}
