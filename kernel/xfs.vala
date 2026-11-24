// Read/Write XFS (v4/v5 on-disk format) filesystem driver over ATA PIO.
// Features: superblock validation, shortform/extent bounds checks, inode cache,
// 8-slot 4 KiB block cache, rep movsb copy, and persistent file create/write/unlink.

namespace Planet.Kernel {

    [AsmBody(@"
        # xfs_memcpy(dst in rdi, src in rsi, len in rdx)
        mov %rdx, %rcx
        test %rcx, %rcx
        jle _xm_done
        .byte 0xfc
        .byte 0xf3, 0xa4
    _xm_done:
        ret
    ")]
    public extern void xfs_memcpy (int dst, int src, int len);

    public sealed class Xfs : Object {
        private static bool xfs_mounted = false;
        private static int xfs_blocksize = 4096;
        private static int xfs_agblocks = 0;
        private static int xfs_dblocks = 0;
        private static int xfs_agblklog = 0;
        private static int xfs_inodesize = 256;
        private static int xfs_inopblog = 0;
        private static int xfs_rootino = 128;
        private static int xfs_sec_buf = 0;
        // Bounce frame for ATA transfers that must not land in the caller's
        // buffer. It is allocated once with `xfs_sec_buf`: a per-call frame can
        // fall outside the supervisor window a user CR3 maps, and `rep insw`
        // into it faults (seen when the compositor self-test grew).
        private static int xfs_bounce = 0;
        private static int xfs_cached_ino = 0;

        // Allocator state for persistent XFS writes (initialized by scan_alloc_state)
        private static int xfs_alloc_ready = 0;
        private static int xfs_next_ino = 0;
        private static int xfs_max_ino = 0;
        private static int xfs_next_blk = 0;

        // 8-slot 4 KiB sector-group cache (keyed by LBA aligned to 8 sectors)
        private const int XFS_CACHE_SLOTS = 8;
        private static int xfs_bcache_mem = 0;
        private static int[] xfs_bcache_lba;
        private static int xfs_bcache_next = 0;

        private static bool is_pow2 (int v) {
            return v > 0 && (v & (v - 1)) == 0;
        }

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

        private static void be16_write (int addr, int v) {
            mmio_write8 (addr + 0, (v >> 8) & 0xFF);
            mmio_write8 (addr + 1, v & 0xFF);
        }

        private static void be32_write (int addr, int v) {
            mmio_write8 (addr + 0, (v >> 24) & 0xFF);
            mmio_write8 (addr + 1, (v >> 16) & 0xFF);
            mmio_write8 (addr + 2, (v >> 8) & 0xFF);
            mmio_write8 (addr + 3, v & 0xFF);
        }

        private static void be64_write (int addr, int v) {
            be32_write (addr + 0, (v >> 32) & 0xFFFFFFFF);
            be32_write (addr + 4, v & 0xFFFFFFFF);
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

        private static int inode_lba (int ino, out int off) {
            int ag = ino >> (xfs_agblklog + xfs_inopblog);
            int rel = ino & ((1 << (xfs_agblklog + xfs_inopblog)) - 1);
            int agbno = rel >> xfs_inopblog;
            int idx = rel & ((1 << xfs_inopblog) - 1);
            int linear_blk = ag * xfs_agblocks + agbno;
            int byte_off = idx * xfs_inodesize;
            off = byte_off & 511;
            return linear_blk * (xfs_blocksize / 512) + (byte_off / 512);
        }

        public static void invalidate_cache () {
            xfs_cached_ino = -1;
            if (xfs_bcache_lba != null) {
                for (int i = 0; i < XFS_CACHE_SLOTS; i++)
                    xfs_bcache_lba[i] = -1;
            }
        }

        public static bool is_mounted () {
            return xfs_mounted;
        }

        public static bool mount () {
            if (xfs_sec_buf == 0)
                xfs_sec_buf = Pmm.alloc_frame ();
            if (xfs_sec_buf == 0)
                return false;
            if (xfs_bounce == 0)
                xfs_bounce = Pmm.alloc_frame ();
            if (xfs_bcache_mem == 0) {
                xfs_bcache_mem = Pmm.alloc_contiguous (XFS_CACHE_SLOTS);
                xfs_bcache_lba = new int[XFS_CACHE_SLOTS];
            }
            invalidate_cache ();
            if (!Ata.read_sector (0, xfs_sec_buf))
                return false;
            int magic = be32 (xfs_sec_buf);
            if (magic != 0x58465342) // "XFSB"
                return false;
            int bs = be32 (xfs_sec_buf + 4);
            int dblks = be64 (xfs_sec_buf + 8);
            int agb = be32 (xfs_sec_buf + 84);
            int rino = be64 (xfs_sec_buf + 56);
            int isz = be16 (xfs_sec_buf + 104);
            int aglog = read_u8 (xfs_sec_buf + 124);
            int inolog = read_u8 (xfs_sec_buf + 123);

            if (!is_pow2 (bs) || bs < 512 || bs > 65536)
                return false;
            if (!is_pow2 (isz) || isz < 256 || isz > 2048)
                return false;
            if (agb <= 0 || rino <= 0 || aglog < 1 || aglog > 31 || inolog < 1 || inolog > 8)
                return false;

            xfs_blocksize = bs;
            xfs_agblocks = agb;
            xfs_dblocks = (dblks > 0) ? dblks : agb;
            xfs_rootino = rino;
            xfs_inodesize = isz;
            xfs_agblklog = aglog;
            xfs_inopblog = inolog;
            xfs_alloc_ready = 0;
            xfs_mounted = true;
            return true;
        }

        private static bool load_inode (int ino, int buf) {
            if (!xfs_mounted || ino <= 0)
                return false;
            if (xfs_cached_ino == ino && buf == xfs_sec_buf)
                return true;
            int off = 0;
            int lba = inode_lba (ino, out off);
            if (!Ata.read_sectors (lba, 4, buf)) {
                xfs_cached_ino = -1;
                return false;
            }
            int magic = be16 (buf + off);
            if (magic != 0x494E) { // "IN"
                xfs_cached_ino = -1;
                return false;
            }
            if (buf == xfs_sec_buf)
                xfs_cached_ino = ino;
            return true;
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

        private static void scan_dir_alloc (int dir_ino, int depth, ref int min_ino, ref int max_ino, ref int max_blk) {
            if (depth > 3)
                return;
            int tmp = Pmm.alloc_frame ();
            if (tmp == 0)
                return;
            if (!load_inode (dir_ino, tmp)) {
                Pmm.free_frame (tmp);
                return;
            }
            int off = inode_off (dir_ino);
            int dbase = tmp + off;
            if (read_u8 (dbase + 5) != 1) {
                Pmm.free_frame (tmp);
                return;
            }
            int ver = read_u8 (dbase + 4);
            int df = dbase + ((ver >= 3) ? 176 : 100);
            int count = read_u8 (df);
            int i8count = read_u8 (df + 1);
            int ino_sz = (i8count > 0) ? 8 : 4;
            int cur = df + 4 + ino_sz;
            for (int i = 0; i < count; i++) {
                if (cur + 3 + ino_sz > tmp + 2048)
                    break;
                int nlen = read_u8 (cur);
                int ino_addr = cur + 3 + nlen;
                int child = (i8count > 0) ? be64 (ino_addr) : (be32 (ino_addr) & 0xFFFFFFFF);
                if (child > 0) {
                    if (child < min_ino) min_ino = child;
                    if (child > max_ino) max_ino = child;
                    if (load_inode (child, xfs_sec_buf)) {
                        int coff = inode_off (child);
                        int cbase = xfs_sec_buf + coff;
                        int fmt = read_u8 (cbase + 5);
                        if (fmt == 2) {
                            int cver = read_u8 (cbase + 4);
                            int cdf_off = (cver >= 3) ? 176 : 100;
                            int nextents = be32 (cbase + 76);
                            int max_ext = (xfs_inodesize - cdf_off) / 16;
                            if (nextents > max_ext) nextents = max_ext;
                            for (int e = 0; e < nextents; e++) {
                                int rec = cbase + cdf_off + e * 16;
                                int w0 = be64 (rec);
                                int w1 = be64 (rec + 8);
                                int sb = ((w0 & 0x1FF) << 43) | ((w1 >> 21) & 0x7FFFFFFFFFF);
                                int bc = w1 & 0x1FFFFF;
                                if (sb + bc > max_blk)
                                    max_blk = sb + bc;
                            }
                        } else if (fmt == 1) {
                            scan_dir_alloc (child, depth + 1, ref min_ino, ref max_ino, ref max_blk);
                        }
                    }
                }
                cur = ino_addr + ino_sz;
            }
            Pmm.free_frame (tmp);
        }

        private static void scan_alloc_state () {
            if (xfs_alloc_ready != 0 || !xfs_mounted)
                return;
            int min_ino = 0x7FFFFFFF;
            int max_ino = 0;
            int max_blk = 0;
            scan_dir_alloc (xfs_rootino, 0, ref min_ino, ref max_ino, ref max_blk);
            int ino_blk = (min_ino < 0x7FFFFFFF) ? (min_ino >> xfs_inopblog) : 1000;
            xfs_max_ino = (ino_blk + 8) << xfs_inopblog; // 8 inode blocks = 128 inodes
            xfs_next_ino = (max_ino > 0) ? (max_ino + 1) : (ino_blk << xfs_inopblog);
            int data_start = ino_blk + 8;
            xfs_next_blk = (max_blk > data_start) ? max_blk : data_start;
            xfs_alloc_ready = 1;
        }

        public static int root_ino () {
            return xfs_rootino;
        }

        public static bool is_dir (int ino) {
            if (!load_inode (ino, xfs_sec_buf))
                return false;
            int off = inode_off (ino);
            return (be16 (xfs_sec_buf + off + 2) & 0xF000) == 0x4000;
        }

        public static int dir_parent (int dir_ino) {
            if (!load_inode (dir_ino, xfs_sec_buf))
                return 0;
            int off = inode_off (dir_ino);
            int ino_base = xfs_sec_buf + off;
            if (read_u8 (ino_base + 5) != 1)
                return 0;
            int ver = read_u8 (ino_base + 4);
            int df = ino_base + ((ver >= 3) ? 176 : 100);
            int i8count = read_u8 (df + 1);
            return (i8count > 0) ? be64 (df + 4) : (be32 (df + 4) & 0xFFFFFFFF);
        }

        public static int lookup_dir (int dir_ino, int name_ptr, int name_len) {
            if (!xfs_mounted || dir_ino <= 0 || name_ptr == 0 || name_len <= 0 || name_len > 255)
                return 0;
            if (!load_inode (dir_ino, xfs_sec_buf))
                return 0;
            int off = inode_off (dir_ino);
            int ino_base = xfs_sec_buf + off;
            int ino_end = xfs_sec_buf + 2048;
            int fmt = read_u8 (ino_base + 5);
            if (fmt != 1) // shortform directory
                return 0;
            int ver = read_u8 (ino_base + 4);
            int df = ino_base + ((ver >= 3) ? 176 : 100);
            if (df + 8 > ino_end)
                return 0;
            int count = read_u8 (df);
            int i8count = read_u8 (df + 1);
            int ino_sz = (i8count > 0) ? 8 : 4;
            int cur = df + 4 + ino_sz;
            for (int i = 0; i < count; i++) {
                if (cur + 3 + ino_sz > ino_end)
                    break;
                int nlen = read_u8 (cur);
                int name_addr = cur + 3;
                int ino_addr = name_addr + nlen;
                if (ino_addr + ino_sz > ino_end)
                    break;
                int child_ino = (i8count > 0) ? be64 (ino_addr) : (be32 (ino_addr) & 0xFFFFFFFF);
                if (name_matches (name_addr, nlen, name_ptr, name_len))
                    return child_ino;
                cur = ino_addr + ino_sz;
            }
            return 0;
        }

        public static int lookup_root (int name_ptr, int name_len) {
            return lookup_dir (xfs_rootino, name_ptr, name_len);
        }

        public static int list_dir (int dir_ino, int buf, int max_bytes) {
            if (!xfs_mounted || dir_ino <= 0 || buf == 0 || max_bytes <= 0)
                return -1;
            if (!load_inode (dir_ino, xfs_sec_buf))
                return -1;
            int off = inode_off (dir_ino);
            int ino_base = xfs_sec_buf + off;
            int ino_end = xfs_sec_buf + 2048;
            int fmt = read_u8 (ino_base + 5);
            if (fmt != 1)
                return -1;
            int ver = read_u8 (ino_base + 4);
            int df = ino_base + ((ver >= 3) ? 176 : 100);
            if (df + 8 > ino_end)
                return -1;
            int count = read_u8 (df);
            int i8count = read_u8 (df + 1);
            int ino_sz = (i8count > 0) ? 8 : 4;
            int cur = df + 4 + ino_sz;
            int pos = 0;
            for (int i = 0; i < count; i++) {
                if (cur + 3 + ino_sz > ino_end)
                    break;
                int nlen = read_u8 (cur);
                int name_addr = cur + 3;
                int ino_addr = name_addr + nlen;
                if (ino_addr + ino_sz > ino_end)
                    break;
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
                cur = ino_addr + ino_sz;
            }
            return pos;
        }

        public static int list_root (int buf, int max_bytes) {
            return list_dir (xfs_rootino, buf, max_bytes);
        }

        public static int file_size (int ino) {
            if (!load_inode (ino, xfs_sec_buf))
                return -1;
            int off = inode_off (ino);
            return be64 (xfs_sec_buf + off + 56);
        }

        public static int create_file (int name_ptr, int name_len) {
            if (!xfs_mounted || name_ptr == 0 || name_len <= 0 || name_len > 255)
                return -1;
            scan_alloc_state ();
            int existing = lookup_root (name_ptr, name_len);
            if (existing > 0) {
                int eoff = 0;
                int elba = inode_lba (existing, out eoff);
                if (!Ata.read_sector (elba, xfs_sec_buf))
                    return -1;
                int eb = xfs_sec_buf + eoff;
                be64_write (eb + 56, 0); // size = 0
                be32_write (eb + 76, 0); // nextents = 0
                if (!Ata.write_sector (elba, xfs_sec_buf))
                    return -1;
                invalidate_cache ();
                return existing;
            }

            if (xfs_next_ino >= xfs_max_ino)
                return -1;
            int new_ino = xfs_next_ino;
            xfs_next_ino++;

            // Initialize new XFS v2 extent-based file inode on disk
            int ioff = 0;
            int ilba = inode_lba (new_ino, out ioff);
            if (!Ata.read_sector (ilba, xfs_sec_buf))
                return -1;
            int ib = xfs_sec_buf + ioff;
            for (int i = 0; i < xfs_inodesize; i += 4)
                mmio_write32 (ib + i, 0);
            be16_write (ib + 0, 0x494E); // "IN"
            be16_write (ib + 2, 0x81A4); // S_IFREG | 0644
            mmio_write8 (ib + 4, 2);     // version 2
            mmio_write8 (ib + 5, 2);     // XFS_DINODE_FMT_EXTENTS
            if (!Ata.write_sector (ilba, xfs_sec_buf))
                return -1;

            // Append entry to root shortform directory (4 sectors of root inode)
            int roff = 0;
            int rlba = inode_lba (xfs_rootino, out roff);
            if (!Ata.read_sectors (rlba, 4, xfs_sec_buf))
                return -1;
            int rbase = xfs_sec_buf + roff;
            int ver = read_u8 (rbase + 4);
            int df = rbase + ((ver >= 3) ? 176 : 100);
            int count = read_u8 (df);
            int i8count = read_u8 (df + 1);
            int ino_sz = (i8count > 0) ? 8 : 4;
            int cur = df + 4 + ino_sz;
            for (int i = 0; i < count; i++) {
                int nlen = read_u8 (cur);
                cur = cur + 3 + nlen + ino_sz;
            }
            int dir_limit = xfs_sec_buf + 2048;
            if (be16 (rbase + xfs_inodesize) == 0x494E)
                dir_limit = rbase + xfs_inodesize;
            if (count >= 250 || cur + 3 + name_len + ino_sz > dir_limit)
                return -1;
            mmio_write8 (cur + 0, name_len);
            be16_write (cur + 1, 0);
            for (int k = 0; k < name_len; k++)
                mmio_write8 (cur + 3 + k, read_u8 (name_ptr + k));
            if (i8count > 0)
                be64_write (cur + 3 + name_len, new_ino);
            else
                be32_write (cur + 3 + name_len, new_ino);
            mmio_write8 (df, count + 1);
            if (!Ata.write_sectors (rlba, 4, xfs_sec_buf))
                return -1;
            invalidate_cache ();
            return new_ino;
        }

        public static int unlink_root (int name_ptr, int name_len) {
            if (!xfs_mounted || name_ptr == 0 || name_len <= 0 || name_len > 255)
                return -1;
            int roff = 0;
            int rlba = inode_lba (xfs_rootino, out roff);
            if (!Ata.read_sectors (rlba, 4, xfs_sec_buf))
                return -1;
            int rbase = xfs_sec_buf + roff;
            if (read_u8 (rbase + 5) != 1)
                return -1;
            int ver = read_u8 (rbase + 4);
            int df = rbase + ((ver >= 3) ? 176 : 100);
            int count = read_u8 (df);
            int i8count = read_u8 (df + 1);
            int ino_sz = (i8count > 0) ? 8 : 4;
            int cur = df + 4 + ino_sz;
            int end_ptr = cur;
            int found_start = -1;
            int found_end = -1;
            for (int i = 0; i < count; i++) {
                int nlen = read_u8 (cur);
                int nxt = cur + 3 + nlen + ino_sz;
                if (found_start < 0 && name_matches (cur + 3, nlen, name_ptr, name_len)) {
                    found_start = cur;
                    found_end = nxt;
                }
                cur = nxt;
                end_ptr = nxt;
            }
            if (found_start < 0)
                return -1;
            int tail = end_ptr - found_end;
            for (int k = 0; k < tail; k++)
                mmio_write8 (found_start + k, read_u8 (found_end + k));
            mmio_write8 (df, count - 1);
            if (!Ata.write_sectors (rlba, 4, xfs_sec_buf))
                return -1;
            invalidate_cache ();
            return 0;
        }

        public static int write_file (int ino, int offset, int src_buf, int len) {
            if (!xfs_mounted || ino <= 0 || src_buf == 0 || offset < 0 || len <= 0)
                return 0;
            scan_alloc_state ();
            int ioff = 0;
            int ilba = inode_lba (ino, out ioff);
            if (!Ata.read_sector (ilba, xfs_sec_buf))
                return -1;
            int ib = xfs_sec_buf + ioff;
            if (be16 (ib) != 0x494E || read_u8 (ib + 5) != 2)
                return -1;
            int fsize = be64 (ib + 56);
            int ver = read_u8 (ib + 4);
            int df_off = (ver >= 3) ? 176 : 100;
            int df = ib + df_off;
            int nextents = be32 (ib + 76);
            int max_ext = (xfs_inodesize - df_off) / 16;

            int end_byte = offset + len;
            int need_blks = (end_byte + xfs_blocksize - 1) / xfs_blocksize;
            int cur_blks = 0;
            for (int e = 0; e < nextents && e < max_ext; e++) {
                int w1 = be64 (df + e * 16 + 8);
                cur_blks += (w1 & 0x1FFFFF);
            }
            if (need_blks > cur_blks) {
                int add_blks = need_blks - cur_blks;
                if (xfs_next_blk + add_blks > xfs_dblocks)
                    return -1;
                if (nextents > 0) {
                    int lrec = df + (nextents - 1) * 16;
                    int lw0 = be64 (lrec);
                    int lw1 = be64 (lrec + 8);
                    int lsb = ((lw0 & 0x1FF) << 43) | ((lw1 >> 21) & 0x7FFFFFFFFFF);
                    int lbc = lw1 & 0x1FFFFF;
                    if (lsb + lbc == xfs_next_blk) {
                        be64_write (lrec + 8, ((lsb & 0x7FFFFFFFFFF) << 21) | ((lbc + add_blks) & 0x1FFFFF));
                        xfs_next_blk += add_blks;
                        add_blks = 0;
                    }
                }
                if (add_blks > 0) {
                    if (nextents >= max_ext)
                        return -1;
                    int nrec = df + nextents * 16;
                    int sb = xfs_next_blk;
                    be64_write (nrec + 0, ((cur_blks & 0x3FFFFFFFFFFFFF) << 9) | ((sb >> 43) & 0x1FF));
                    be64_write (nrec + 8, ((sb & 0x7FFFFFFFFFF) << 21) | (add_blks & 0x1FFFFF));
                    nextents++;
                    be32_write (ib + 76, nextents);
                    xfs_next_blk += add_blks;
                }
            }

            int tmp = xfs_bounce;
            if (tmp == 0) {
                tmp = Pmm.alloc_frame ();
                xfs_bounce = tmp;
            }
            if (tmp == 0)
                return -1;
            int written = 0;
            int skip = offset;
            int secs_per_blk = xfs_blocksize / 512;
            for (int e = 0; e < nextents && written < len; e++) {
                int rec = df + e * 16;
                int w0 = be64 (rec);
                int w1 = be64 (rec + 8);
                int sb = ((w0 & 0x1FF) << 43) | ((w1 >> 21) & 0x7FFFFFFFFFF);
                int bc = w1 & 0x1FFFFF;
                int lba = fsbno_to_lba (sb);
                int total_secs = bc * secs_per_blk;
                for (int s = 0; s < total_secs && written < len; s++) {
                    if (skip >= 512) {
                        skip -= 512;
                        continue;
                    }
                    int rem = len - written;
                    int chunk = 512 - skip;
                    if (chunk > rem)
                        chunk = rem;
                    if (skip > 0 || chunk < 512) {
                        if (!Ata.read_sector (lba + s, tmp))
                            return written;
                    }
                    xfs_memcpy (tmp + skip, src_buf + written, chunk);
                    if (!Ata.write_sector (lba + s, tmp))
                        return written;
                    written += chunk;
                    skip = 0;
                }
            }
            if (offset + written > fsize)
                be64_write (ib + 56, offset + written);
            Ata.write_sector (ilba, xfs_sec_buf);
            invalidate_cache ();
            return written;
        }

        private static int read_cached_block (int base_lba, int secs) {
            if (xfs_bcache_mem == 0 || xfs_bcache_lba == null || secs > 8)
                return 0;
            for (int i = 0; i < XFS_CACHE_SLOTS; i++) {
                if (xfs_bcache_lba[i] == base_lba)
                    return xfs_bcache_mem + i * 4096;
            }
            int slot = xfs_bcache_next;
            xfs_bcache_next = (xfs_bcache_next + 1) % XFS_CACHE_SLOTS;
            int dst = xfs_bcache_mem + slot * 4096;
            if (!Ata.read_sectors (base_lba, secs, dst)) {
                xfs_bcache_lba[slot] = -1;
                return 0;
            }
            xfs_bcache_lba[slot] = base_lba;
            return dst;
        }

        public static int read_file (int ino, int offset, int dst_buf, int max_bytes) {
            if (dst_buf == 0 || offset < 0 || max_bytes <= 0)
                return 0;
            if (!load_inode (ino, xfs_sec_buf))
                return -1;
            int off = inode_off (ino);
            int ino_base = xfs_sec_buf + off;
            int fsize = be64 (ino_base + 56);
            if (fsize <= 0 || offset >= fsize)
                return 0;
            int avail = fsize - offset;
            int to_read = (avail < max_bytes) ? avail : max_bytes;
            int fmt = read_u8 (ino_base + 5);
            int ver = read_u8 (ino_base + 4);
            int df_off = (ver >= 3) ? 176 : 100;
            int df = ino_base + df_off;
            if (fmt != 2) // extents
                return -1;
            int nextents = be32 (ino_base + 76);
            int max_ext = (xfs_inodesize - df_off) / 16;
            if (nextents < 0 || nextents > max_ext)
                nextents = max_ext;
            int copied = 0;
            int skip = offset;
            int tmp = xfs_bounce;
            if (tmp == 0) {
                tmp = Pmm.alloc_frame ();
                xfs_bounce = tmp;
            }
            if (tmp == 0)
                return -1;
            for (int e = 0; e < nextents && copied < to_read; e++) {
                int rec = df + e * 16;
                int w0 = be64 (rec);
                int w1 = be64 (rec + 8);
                int startblock = ((w0 & 0x1FF) << 43) | ((w1 >> 21) & 0x7FFFFFFFFFF);
                int blockcount = w1 & 0x1FFFFF;
                if (startblock <= 0 || blockcount <= 0)
                    continue;
                int lba = fsbno_to_lba (startblock);
                int total_secs = blockcount * (xfs_blocksize / 512);
                int s = 0;
                while (s < total_secs && copied < to_read) {
                    if (skip >= 512) {
                        skip = skip - 512;
                        s++;
                        continue;
                    }
                    int rem_bytes = to_read - copied;
                    int batch = 1;
                    if (skip == 0 && rem_bytes > 512) {
                        int need_secs = (rem_bytes + 511) / 512;
                        int avail_secs = total_secs - s;
                        batch = (need_secs < avail_secs) ? need_secs : avail_secs;
                        if (batch > 8)
                            batch = 8;
                    }
                    int src_ptr = 0;
                    if (s % 8 == 0 && total_secs - s >= 8) {
                        src_ptr = read_cached_block (lba + s, 8);
                        if (src_ptr != 0 && skip == 0 && rem_bytes > 512) {
                            batch = 8;
                        }
                    }
                    if (src_ptr == 0) {
                        if (!Ata.read_sectors (lba + s, batch, tmp))
                            return copied;
                        src_ptr = tmp;
                    }
                    int chunk = batch * 512 - skip;
                    if (chunk > rem_bytes)
                        chunk = rem_bytes;
                    xfs_memcpy (dst_buf + copied, src_ptr + skip, chunk);
                    copied = copied + chunk;
                    skip = 0;
                    s += batch;
                }
            }
            return copied;
        }
    }
}
