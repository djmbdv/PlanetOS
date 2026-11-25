// Minimal ELF64 userland loader and synchronous exec trampoline for PlanetOS.

namespace Planet.Kernel {

    [AsmBody(@"
        mov %rsi, %rsp
        push %rdi
        ret
    ")]
    public extern void jump_to_entry (int entry_addr, int stack_ptr);

    [AsmBody(@"
        # exec_trampoline(entry in rdi, user_rsp in rsi, user_cr3 in rdx, slot in rcx) -> exit_code in rax
        push %rbx
        push %rbp
        push %r12
        push %r13
        push %r14
        push %r15
        mov %rsp, (%rcx)
        mov %cr3, %rax
        mov %rax, 8(%rcx)
        mov $0x104104, %r8
        mov (%r8), %rax
        mov %rax, 16(%rcx)
        mov %rsp, (%r8)
        mov %rdx, %cr3
        push $0x1B
        push %rsi
        push $0x202
        push $0x23
        push %rdi
        iretq
    ")]
    public extern int exec_trampoline (int entry_addr, int user_rsp, int user_cr3, int slot_addr);

    [AsmBody(@"
        # exec_return_to_parent(exit_code in rdi, slot in rsi) -> resumes exec_trampoline caller
        mov %rdi, %rax
        mov 16(%rsi), %r8
        mov $0x104104, %r9
        mov %r8, (%r9)
        mov 8(%rsi), %r8
        mov %r8, %cr3
        mov (%rsi), %rsp
        pop %r15
        pop %r14
        pop %r13
        pop %r12
        pop %rbp
        pop %rbx
        ret
    ")]
    public extern void exec_return_to_parent (int exit_code, int slot_addr);

    [AsmBody(@"
        add $16, %rdi
        mov %rdi, %rax
        ret
    ")]
    private extern int __el_str_data (string s);

    public sealed class ElfLoader : Object {
        // planc.elf is expected to build large programs on-target and its codegen
        // recurses per expression, so the old 64 KiB of usable stack left no
        // headroom: compiling the c2vala SDK died writing into the guard page.
        private const int USER_STACK_PAGES = 257; // 1 guard + 256 usable (1 MiB)

        public static int exec_depth = 0;
        private const int MAX_SHARED_DLIBS = 24;
        private static bool shared_dlibs_probed = false;
        private static int shared_dlib_count = 0;
        private static int[] shared_ro_vaddr;
        private static int[] shared_ro_size;
        private static int[] shared_data_vaddr;
        private static int[] shared_data_fsz;
        private static int[] shared_data_msz;
        private static int[] shared_data_tmpl;
        private static int[] shared_name_hash;
        private static int[] shared_ht_addr;
        private static int[] shared_ht_buckets;
        private static int[] shared_imp_buf;
        private static int[] shared_imp_count;
        private static int[] shared_deps_mask;
        private static int glib_dlib_idx = 0;
        private static int last_loaded_dlib_mask = 0;

        private static int fnv1a_64_mem (int ptr, int len) {
            int h = (int) 0xcbf29ce484222325;
            for (int i = 0; i < len; i++) {
                h = h ^ read_u8 (ptr + i);
                h = h * 0x100000001b3;
            }
            if (h == 0)
                h = 1;
            return h;
        }

        private static int find_dlib_index (int dlib_hash) {
            for (int i = 0; i < shared_dlib_count; i++) {
                if (shared_name_hash[i] == dlib_hash)
                    return i;
            }
            return -1;
        }

        private static int resolve_symbol_hash (int dlib_hash, int sym_hash) {
            int i = find_dlib_index (dlib_hash);
            if (i < 0)
                return 0;
            int buckets = shared_ht_buckets[i];
            int ht = shared_ht_addr[i];
            if (buckets <= 0 || ht == 0)
                return 0;
            int mask = buckets - 1;
            int idx = sym_hash & mask;
            for (int step = 0; step < buckets; step++) {
                int kh = mmio_read64 (ht + idx * 16);
                if (kh == 0)
                    return 0;
                if (kh == sym_hash)
                    return mmio_read64 (ht + idx * 16 + 8);
                idx = (idx + 1) & mask;
            }
            return 0;
        }

        private static int skip_plan_exports (int buf, int size, int exp_count, int meta_off) {
            int pos = meta_off;
            for (int i = 0; i < exp_count && pos + 12 <= size; i++) {
                int nlen = mmio_read32 (buf + pos + 8) & 0xFFFFFFFF;
                pos += 12;
                if (nlen <= 0 || pos + nlen > size)
                    return -1;
                pos += nlen;
            }
            return pos;
        }

        // Each .dlib in /library/<name>/ is loaded once into the window Pmm.init reserves
        // (0x1800000..0x2000000), and each process maps the same read-only pages.
        private static void ensure_shared_dlib_ino (int id, int name_ptr, int name_len) {
            if (id <= 0 || shared_dlib_count >= MAX_SHARED_DLIBS)
                return;
            int sz = Xfs.file_size (id);
            if (sz < 160)
                return;
            int pages = (sz + 4095) / 4096;
            int buf = Pmm.alloc_contiguous (pages);
            if (buf == 0)
                return;
            int got = Xfs.read_file (id, 0, buf, sz);
            if (got != sz || (mmio_read32 (buf) & 0xFFFFFFFF) != 0x4E414C50 || read_u16 (buf + 6) != 1) {
                for (int p = 0; p < pages; p++)
                    Pmm.free_frame (buf + p * 4096);
                return;
            }
            int hdr_ver = read_u16 (buf + 4);
            if (hdr_ver != 1) {
                // The kernel links against these images by absolute address, so a
                // header from another ABI generation is refused instead of jumped into.
                Klog.error (Klog.CAT_EXEC, "shared dlib: unsupported ABI version (rebuild it)");
                for (int p = 0; p < pages; p++)
                    Pmm.free_frame (buf + p * 4096);
                return;
            }
            int sec_count = mmio_read32 (buf + 24) & 0xFFFFFFFF;
            if (sec_count < 3 || 64 + sec_count * 32 > got) {
                for (int p = 0; p < pages; p++)
                    Pmm.free_frame (buf + p * 4096);
                return;
            }
            int s0_va = mmio_read64 (buf + 64);
            int s0_off = mmio_read64 (buf + 72);
            int s0_fsz = mmio_read64 (buf + 80);
            int s1_va = mmio_read64 (buf + 96);
            int s1_off = mmio_read64 (buf + 104);
            int s1_fsz = mmio_read64 (buf + 112);
            int s1_msz = mmio_read64 (buf + 120);
            int ro_end = s1_va + ((s1_msz > 0) ? s1_msz : 1);
            int ro_sz = ro_end - s0_va;
            // 0x1800000..0x2000000 is the window Pmm.init reserves for the
            // shared dlibs; a section starts a bit past the base (the .plan
            // header), so check the range and not the exact value.
            if (s0_va < 0x1800000 || s0_va >= 0x2000000 || ro_sz <= 0
                || ro_end > 0x2000000 || s0_off + s0_fsz > got || s1_off + s1_fsz > got) {
                Klog.error (Klog.CAT_EXEC, "shared dlib: unexpected image base");
                for (int p = 0; p < pages; p++)
                    Pmm.free_frame (buf + p * 4096);
                return;
            }
            Pmm.reserve_range (s0_va, ro_sz);
            for (int b = 0; b < s0_fsz; b++)
                mmio_write8 (s0_va + b, read_u8 (buf + s0_off + b));
            for (int b = 0; b < s1_fsz; b++)
                mmio_write8 (s1_va + b, read_u8 (buf + s1_off + b));

            int idx = shared_dlib_count;
            shared_ro_vaddr[idx] = s0_va;
            shared_ro_size[idx] = ro_sz;
            shared_data_vaddr[idx] = 0;
            shared_data_fsz[idx] = 0;
            shared_data_msz[idx] = 0;
            shared_data_tmpl[idx] = 0;
            shared_name_hash[idx] = fnv1a_64_mem (name_ptr, name_len);
            shared_ht_addr[idx] = 0;
            shared_ht_buckets[idx] = 0;
            shared_imp_buf[idx] = 0;
            shared_imp_count[idx] = 0;

            int exp_count = mmio_read32 (buf + 28) & 0xFFFFFFFF;
            int imp_count = mmio_read32 (buf + 32) & 0xFFFFFFFF;
            int ht_buckets = mmio_read32 (buf + 36) & 0xFFFFFFFF;
            int meta_off = mmio_read64 (buf + 40);
            int meta_cur = skip_plan_exports (buf, got, exp_count, meta_off);
            if (meta_cur >= 0 && ht_buckets > 0 && meta_cur + ht_buckets * 16 <= got) {
                int ht_bytes = ht_buckets * 16;
                int ht_pages = (ht_bytes + 4095) / 4096;
                int ht_mem = Pmm.alloc_contiguous (ht_pages);
                if (ht_mem != 0) {
                    for (int b = 0; b < ht_bytes; b++)
                        mmio_write8 (ht_mem + b, read_u8 (buf + meta_cur + b));
                    shared_ht_addr[idx] = ht_mem;
                    shared_ht_buckets[idx] = ht_buckets;
                }
                meta_cur += ht_bytes;
            }
            if (meta_cur >= 0 && imp_count > 0 && meta_cur + imp_count * 24 <= got) {
                int ib_bytes = imp_count * 24;
                int ib_pages = (ib_bytes + 4095) / 4096;
                int ib_mem = Pmm.alloc_contiguous (ib_pages);
                if (ib_mem != 0) {
                    for (int b = 0; b < ib_bytes; b++)
                        mmio_write8 (ib_mem + b, read_u8 (buf + meta_cur + b));
                    shared_imp_buf[idx] = ib_mem;
                    shared_imp_count[idx] = imp_count;
                }
            }

            int s2_va = mmio_read64 (buf + 128);
            int s2_off = mmio_read64 (buf + 136);
            int s2_fsz = mmio_read64 (buf + 144);
            int s2_msz = mmio_read64 (buf + 152);
            // Sections 0/1 are .text and .rodata, shared read-only. Section 2 is
            // .data + .bss: its image is kept as a template so each process gets a
            // private copy.
            if (s2_msz > 0 && s2_off + s2_fsz <= got) {
                Pmm.reserve_range (s2_va, s2_msz);
                for (int b = 0; b < s2_fsz; b++)
                    mmio_write8 (s2_va + b, read_u8 (buf + s2_off + b));
                for (int b = s2_fsz; b < s2_msz; b++)
                    mmio_write8 (s2_va + b, 0);
                int dpages = (s2_fsz > 0) ? ((s2_fsz + 4095) / 4096) : 0;
                if (dpages > 0) {
                    int tmpl = Pmm.alloc_contiguous (dpages);
                    if (tmpl != 0) {
                        for (int b = 0; b < s2_fsz; b++)
                            mmio_write8 (tmpl + b, read_u8 (buf + s2_off + b));
                        shared_data_tmpl[idx] = tmpl;
                        shared_data_fsz[idx] = s2_fsz;
                    }
                }
                shared_data_vaddr[idx] = s2_va;
                shared_data_msz[idx] = s2_msz;
            }
            shared_dlib_count = shared_dlib_count + 1;
            for (int p = 0; p < pages; p++)
                Pmm.free_frame (buf + p * 4096);
        }

        private static bool is_dlib_name (int ptr, int len) {
            if (len <= 5)
                return false;
            return read_u8 (ptr + len - 5) == '.'
                && read_u8 (ptr + len - 4) == 'd'
                && read_u8 (ptr + len - 3) == 'l'
                && read_u8 (ptr + len - 2) == 'i'
                && read_u8 (ptr + len - 1) == 'b';
        }

        private static void ensure_shared_dlibs_in (int dir_ino, int depth) {
            if (dir_ino <= 0 || !Xfs.is_dir (dir_ino))
                return;
            int list_buf = Pmm.alloc_frame ();
            if (list_buf == 0)
                return;
            int n = Xfs.list_dir (dir_ino, list_buf, 4096);
            int start = 0;
            for (int i = 0; i <= n; i++) {
                if (i == n || read_u8 (list_buf + i) == '\n') {
                    int len = i - start;
                    if (len > 0) {
                        int cino = Xfs.lookup_dir (dir_ino, list_buf + start, len);
                        if (is_dlib_name (list_buf + start, len)) {
                            ensure_shared_dlib_ino (cino, list_buf + start, len);
                        } else if (depth == 0 && cino > 0 && Xfs.is_dir (cino)) {
                            ensure_shared_dlibs_in (cino, depth + 1);
                        }
                    }
                    start = i + 1;
                }
            }
            Pmm.free_frame (list_buf);
        }

        private static void ensure_shared_dlibs () {
            if (shared_dlibs_probed)
                return;
            shared_dlibs_probed = true;
            shared_ro_vaddr = new int[MAX_SHARED_DLIBS];
            shared_ro_size = new int[MAX_SHARED_DLIBS];
            shared_data_vaddr = new int[MAX_SHARED_DLIBS];
            shared_data_fsz = new int[MAX_SHARED_DLIBS];
            shared_data_msz = new int[MAX_SHARED_DLIBS];
            shared_data_tmpl = new int[MAX_SHARED_DLIBS];
            shared_name_hash = new int[MAX_SHARED_DLIBS];
            shared_ht_addr = new int[MAX_SHARED_DLIBS];
            shared_ht_buckets = new int[MAX_SHARED_DLIBS];
            shared_imp_buf = new int[MAX_SHARED_DLIBS];
            shared_imp_count = new int[MAX_SHARED_DLIBS];
            shared_deps_mask = new int[MAX_SHARED_DLIBS];

            int lib_ino = Xfs.lookup_root (__el_str_data ("library"), 7);
            if (lib_ino > 0 && Xfs.is_dir (lib_ino))
                ensure_shared_dlibs_in (lib_ino, 0);
            int stdlib_ino = Xfs.lookup_root (__el_str_data ("stdlib"), 6);
            if (stdlib_ino > 0 && Xfs.is_dir (stdlib_ino))
                ensure_shared_dlibs_in (stdlib_ino, 0);

            glib_dlib_idx = find_dlib_index (fnv1a_64_mem (__el_str_data ("glib.dlib"), 9));

            // Second pass: resolve cross-.dlib GOT slots and record direct dep masks.
            for (int i = 0; i < shared_dlib_count; i++) {
                shared_deps_mask[i] = 0;
                int ib = shared_imp_buf[i];
                int ic = shared_imp_count[i];
                if (ib == 0 || ic <= 0)
                    continue;
                int dv = shared_data_vaddr[i];
                int df = shared_data_fsz[i];
                int dt = shared_data_tmpl[i];
                for (int k = 0; k < ic; k++) {
                    int dh = mmio_read64 (ib + k * 24 + 0);
                    int sh = mmio_read64 (ib + k * 24 + 8);
                    int gv = mmio_read64 (ib + k * 24 + 16);
                    int didx = find_dlib_index (dh);
                    if (didx >= 0)
                        shared_deps_mask[i] = shared_deps_mask[i] | (1 << didx);
                    int target = resolve_symbol_hash (dh, sh);
                    if (target != 0 && gv >= dv && gv + 8 <= dv + df) {
                        mmio_write64 (gv, target);
                        if (dt != 0)
                            mmio_write64 (dt + (gv - dv), target);
                    }
                }
                int ipages = (ic * 24 + 4095) / 4096;
                for (int p = 0; p < ipages; p++)
                    Pmm.free_frame (ib + p * 4096);
                shared_imp_buf[i] = 0;
                shared_imp_count[i] = 0;
            }

            // Transitive closure of .dlib dependencies.
            for (int step = 0; step < shared_dlib_count; step++) {
                for (int i = 0; i < shared_dlib_count; i++) {
                    int m = shared_deps_mask[i];
                    for (int j = 0; j < shared_dlib_count; j++) {
                        if ((m & (1 << j)) != 0)
                            m = m | shared_deps_mask[j];
                    }
                    shared_deps_mask[i] = m;
                }
            }
        }

        private static void map_shared_dlib_one (int user_cr3, int ro_vaddr, int ro_size,
                                                 int data_vaddr, int data_fsz, int data_msz, int data_tmpl) {
            if (ro_vaddr == 0 || ro_size <= 0)
                return;
            Vmm.map_user_range_ro (user_cr3, ro_vaddr, ro_size);
            if (data_vaddr != 0 && data_msz > 0) {
                int first = data_vaddr & ~0xFFF;
                int last = (data_vaddr + data_msz - 1) & ~0xFFF;
                int dpages = ((last - first) / 4096) + 1;
                int priv = Pmm.alloc_contiguous (dpages);
                if (priv == 0)
                    return;
                for (int i = 0; i < dpages; i++)
                    zero_page_4k (priv + i * 4096);
                int off_in_page = data_vaddr & 0xFFF;
                for (int b = 0; b < data_fsz; b++)
                    mmio_write8 (priv + off_in_page + b, read_u8 (data_tmpl + b));
                for (int i = 0; i < dpages; i++)
                    Vmm.map_user_4k_phys (user_cr3, first + i * 4096, priv + i * 4096, 0x07);
            }
        }

        private static void map_shared_dlibs_into (int user_cr3, int needed_mask) {
            ensure_shared_dlibs ();
            int full_mask = needed_mask;
            if (glib_dlib_idx >= 0)
                full_mask = full_mask | (1 << glib_dlib_idx);
            for (int i = 0; i < shared_dlib_count; i++) {
                if ((needed_mask & (1 << i)) != 0)
                    full_mask = full_mask | shared_deps_mask[i];
            }
            for (int i = 0; i < shared_dlib_count; i++) {
                if ((full_mask & (1 << i)) != 0) {
                    map_shared_dlib_one (user_cr3, shared_ro_vaddr[i], shared_ro_size[i],
                        shared_data_vaddr[i], shared_data_fsz[i], shared_data_msz[i], shared_data_tmpl[i]);
                }
            }
        }
        private static int read_u8 (int addr) {
            int w = mmio_read32 (addr & ~3);
            return (w >> ((addr & 3) * 8)) & 0xFF;
        }

        private static int read_u16 (int addr) {
            return read_u8 (addr) | (read_u8 (addr + 1) << 8);
        }

        private static int load_plan_image (int buf, int size, int user_cr3) {
            if (size < 64)
                return 0;
            int kind = read_u16 (buf + 6);
            if (kind != 0) {
                print ("plan: cannot execute .dlib directly\n");
                return 0;
            }
            int entry = mmio_read64 (buf + 16);
            int sec_count = mmio_read32 (buf + 24) & 0xFFFFFFFF;
            if (sec_count <= 0 || 64 + sec_count * 32 > size) {
                print ("plan: bad section table\n");
                return 0;
            }
            for (int i = 0; i < sec_count; i++) {
                int sh = buf + 64 + i * 32;
                int vaddr = mmio_read64 (sh + 0);
                int foff = mmio_read64 (sh + 8);
                int fsz = mmio_read64 (sh + 16);
                int msz = mmio_read64 (sh + 24);
                if (msz <= 0)
                    continue;
                if (vaddr < 0x800000 || vaddr + msz > 0x40000000 || foff + fsz > size) {
                    print ("plan: invalid section bounds\n");
                    return 0;
                }
                Pmm.reserve_range (vaddr, msz);
                if (user_cr3 != 0)
                    Vmm.map_user_range (user_cr3, vaddr, msz);
                for (int b = 0; b < fsz; b++)
                    mmio_write8 (vaddr + b, read_u8 (buf + foff + b));
                for (int b = fsz; b < msz; b++)
                    mmio_write8 (vaddr + b, 0);
            }
            int exp_count = mmio_read32 (buf + 28) & 0xFFFFFFFF;
            int imp_count = mmio_read32 (buf + 32) & 0xFFFFFFFF;
            int ht_buckets = mmio_read32 (buf + 36) & 0xFFFFFFFF;
            int meta_off = mmio_read64 (buf + 40);
            if (imp_count > 0) {
                ensure_shared_dlibs ();
                int cur = skip_plan_exports (buf, size, exp_count, meta_off);
                if (cur >= 0) {
                    cur += ht_buckets * 16;
                    for (int k = 0; k < imp_count && cur + 24 <= size; k++) {
                        int dh = mmio_read64 (buf + cur + 0);
                        int sh = mmio_read64 (buf + cur + 8);
                        int gv = mmio_read64 (buf + cur + 16);
                        int didx = find_dlib_index (dh);
                        if (didx >= 0)
                            last_loaded_dlib_mask = last_loaded_dlib_mask | (1 << didx);
                        int target = resolve_symbol_hash (dh, sh);
                        if (target != 0 && gv >= 0x800000 && gv < 0x40000000)
                            mmio_write64 (gv, target);
                        cur += 24;
                    }
                }
            }
            return entry;
        }

        public static int load_image (int buf, int size, int user_cr3 = 0) {
            last_loaded_dlib_mask = 0;
            if (size < 64)
                return 0;
            int magic = mmio_read32 (buf) & 0xFFFFFFFF;
            if (magic == 0x4E414C50)
                return load_plan_image (buf, size, user_cr3);
            if (magic != 0x464C457F) {
                print ("elf: bad magic\n");
                return 0;
            }
            int machine = read_u16 (buf + 18);
            if (machine != 62) {
                print ("elf: not x86-64\n");
                return 0;
            }

            int entry = mmio_read64 (buf + 24);
            int phoff = mmio_read64 (buf + 32);
            int phentsize = read_u16 (buf + 54);
            int phnum = read_u16 (buf + 56);

            for (int i = 0; i < phnum; i++) {
                int ph = buf + phoff + i * phentsize;
                int p_type = mmio_read32 (ph) & 0xFFFFFFFF;
                if (p_type == 0x70000001) {
                    int imp_off = mmio_read64 (ph + 8);
                    int imp_sz = mmio_read64 (ph + 32);
                    if (imp_off > 0 && imp_sz >= 24 && imp_off + imp_sz <= size) {
                        ensure_shared_dlibs ();
                        int imp_count = imp_sz / 24;
                        for (int k = 0; k < imp_count; k++) {
                            int rec = buf + imp_off + k * 24;
                            int dh = mmio_read64 (rec + 0);
                            int sh = mmio_read64 (rec + 8);
                            int gv = mmio_read64 (rec + 16);
                            int didx = find_dlib_index (dh);
                            if (didx >= 0)
                                last_loaded_dlib_mask = last_loaded_dlib_mask | (1 << didx);
                            int target = resolve_symbol_hash (dh, sh);
                            if (target != 0 && gv >= 0x800000 && gv < 0x40000000)
                                mmio_write64 (gv, target);
                        }
                    }
                    continue;
                }
                if (p_type != 1)
                    continue;
                int p_offset = mmio_read64 (ph + 8);
                int p_vaddr = mmio_read64 (ph + 16);
                int p_filesz = mmio_read64 (ph + 32);
                int p_memsz = mmio_read64 (ph + 40);

                if (p_vaddr < 0x800000 || p_memsz < 0 || p_vaddr + p_memsz > 0x40000000) {
                    print ("elf: invalid vaddr (not a PlanetOS binary)\n");
                    return 0;
                }

                Pmm.reserve_range (p_vaddr, p_memsz);
                if (user_cr3 != 0) {
                    Vmm.map_user_range (user_cr3, p_vaddr, p_memsz);
                }

                for (int b = 0; b < p_filesz; b++) {
                    mmio_write8 (p_vaddr + b, read_u8 (buf + p_offset + b));
                }
                for (int b = p_filesz; b < p_memsz; b++) {
                    mmio_write8 (p_vaddr + b, 0);
                }
            }
            return entry;
        }

        public static bool load_and_run (int buf, int size) {
            int entry = load_image (buf, size);
            if (entry == 0)
                return false;
            ensure_shared_dlibs ();
            int sp = KernelLayout.LEGACY_STACK;
            int str = KernelLayout.LEGACY_ARGV;
            mmio_write8 (str + 0, 's');
            mmio_write8 (str + 1, 'h');
            mmio_write8 (str + 2, 0);
            mmio_write64 (sp + 0, 1);   // argc = 1
            mmio_write64 (sp + 8, str); // argv[0] = "sh"
            mmio_write64 (sp + 16, 0);  // argv[1] = NULL
            jump_to_entry (entry, sp);
            return true;
        }

        private static int prepare_process (int name_ptr, int name_len, int cmdline_ptr,
                                            out int out_stack_base, out int out_arg_sp, out int out_user_cr3) {
            out_stack_base = 0;
            out_arg_sp = 0;
            out_user_cr3 = 0;
            int id = -1;
            int kind = Vfs.resolve (name_ptr, name_len, out id);
            if (kind != Vfs.KIND_FILE && kind != Vfs.KIND_XFS)
                return 0;
            // Stage cmdline in IO_SCRATCH and run under kernel CR3 so ebuf and
            // child_stack are always identity-mapped regardless of caller CR3.
            int cmd_scratch = 0;
            if (cmdline_ptr != 0) {
                cmd_scratch = KernelLayout.IO_SCRATCH + 1024;
                int ci = 0;
                while (ci < 1000) {
                    int cb = read_u8 (cmdline_ptr + ci);
                    mmio_write8 (cmd_scratch + ci, cb);
                    if (cb == 0)
                        break;
                    ci = ci + 1;
                }
                mmio_write8 (cmd_scratch + 1000, 0);
            }
            int saved_cr3 = vmm_read_cr3 ();
            if (saved_cr3 != KernelLayout.PAGE_TABLES)
                vmm_write_cr3 (KernelLayout.PAGE_TABLES);

            int esz = (kind == Vfs.KIND_FILE) ? Ramfs.file_size (id) : Xfs.file_size (id);
            if (esz < 64) {
                if (saved_cr3 != KernelLayout.PAGE_TABLES)
                    vmm_write_cr3 (saved_cr3);
                return 0;
            }
            int pages = (esz + 4095) / 4096;
            int ebuf = Pmm.alloc_contiguous (pages);
            if (ebuf == 0) {
                if (saved_cr3 != KernelLayout.PAGE_TABLES)
                    vmm_write_cr3 (saved_cr3);
                return 0;
            }
            int user_cr3 = Vmm.create_user_space ();
            if (user_cr3 == 0) {
                for (int p = 0; p < pages; p++)
                    Pmm.free_frame (ebuf + p * 4096);
                if (saved_cr3 != KernelLayout.PAGE_TABLES)
                    vmm_write_cr3 (saved_cr3);
                return 0;
            }
            int got = (kind == Vfs.KIND_FILE) ? Ramfs.read (id, 0, ebuf, esz) : Xfs.read_file (id, 0, ebuf, esz);
            int entry = (got == esz) ? load_image (ebuf, esz, user_cr3) : 0;
            for (int p = 0; p < pages; p++) {
                Pmm.free_frame (ebuf + p * 4096);
            }
            if (entry == 0) {
                Vmm.destroy_user_space (user_cr3);
                if (saved_cr3 != KernelLayout.PAGE_TABLES)
                    vmm_write_cr3 (saved_cr3);
                return 0;
            }
            map_shared_dlibs_into (user_cr3, last_loaded_dlib_mask);

            int stack_pages = USER_STACK_PAGES;
            int child_stack = Pmm.alloc_contiguous (stack_pages);
            if (child_stack == 0) {
                Vmm.destroy_user_space (user_cr3);
                if (saved_cr3 != KernelLayout.PAGE_TABLES)
                    vmm_write_cr3 (saved_cr3);
                return 0;
            }
            Vmm.map_user_range (user_cr3, child_stack + 4096, (stack_pages - 1) * 4096);
            Vmm.unmap_user_4k (user_cr3, child_stack);

            // Build Linux-compatible argc/argv[] at top of child_stack
            int stack_top = child_stack + stack_pages * 4096;
            int str_base = stack_top - 1024;
            int argc = 0;
            int ptr_base = str_base - 256;
            int s_pos = 0;
            if (cmd_scratch != 0) {
                int i = 0;
                while (i < 1000) {
                    int b = read_u8 (cmd_scratch + i);
                    if (b == 0)
                        break;
                    while (b == ' ') {
                        i = i + 1;
                        b = read_u8 (cmd_scratch + i);
                    }
                    if (b == 0)
                        break;
                    if (argc < 30) {
                        mmio_write64 (ptr_base + 8 + argc * 8, str_base + s_pos);
                        argc = argc + 1;
                    }
                    while (b != 0 && b != ' ' && s_pos < 1020) {
                        mmio_write8 (str_base + s_pos, b);
                        s_pos = s_pos + 1;
                        i = i + 1;
                        b = read_u8 (cmd_scratch + i);
                    }
                    mmio_write8 (str_base + s_pos, 0);
                    s_pos = s_pos + 1;
                }
            }
            if (argc == 0) {
                mmio_write64 (ptr_base + 8, str_base);
                for (int k = 0; k < name_len && k < 250; k++) {
                    mmio_write8 (str_base + k, read_u8 (name_ptr + k));
                }
                mmio_write8 (str_base + name_len, 0);
                argc = 1;
            }
            mmio_write64 (ptr_base + 0, argc);
            mmio_write64 (ptr_base + 8 + argc * 8, 0);
            if (saved_cr3 != KernelLayout.PAGE_TABLES)
                vmm_write_cr3 (saved_cr3);
            out_stack_base = child_stack;
            out_arg_sp = ptr_base;
            out_user_cr3 = user_cr3;
            return entry;
        }

        public static int exec_from_xfs (int name_ptr, int name_len, int cmdline_ptr) {
            int child_stack = 0;
            int ptr_base = 0;
            int user_cr3 = 0;
            int entry = prepare_process (name_ptr, name_len, cmdline_ptr, out child_stack, out ptr_base, out user_cr3);
            if (entry == 0)
                return -1;
            if (exec_depth >= KernelLayout.EXEC_MAX_DEPTH) {
                // The saved-context slots are a fixed window: nesting deeper
                // would run past EXEC_SLOTS into the mouse ring, so refuse the
                // exec instead of overwriting it.
                Vmm.destroy_user_space (user_cr3);
                for (int p = 0; p < USER_STACK_PAGES; p++) {
                    Pmm.free_frame (child_stack + p * 4096);
                }
                return -1;
            }
            int prev_cr3 = Sched.current_cr3 ();
            int prev_rsp0 = Hal.get_tss_rsp0 ();
            exec_depth = exec_depth + 1;
            int slot = KernelLayout.EXEC_SLOTS + (exec_depth - 1) * KernelLayout.EXEC_SLOT_SIZE;
            Sched.set_current_exec_ctx (user_cr3, 0);
            int code = exec_trampoline (entry, ptr_base, user_cr3, slot);
            Sched.set_current_exec_ctx (prev_cr3, prev_rsp0);
            Vmm.destroy_user_space (user_cr3);
            for (int p = 0; p < USER_STACK_PAGES; p++) {
                Pmm.free_frame (child_stack + p * 4096);
            }
            if (exec_depth == 0 && Fb.width () > 0) {
                Fb.close ();
            }
            return code;
        }

        public static int spawn_from_xfs (int name_ptr, int name_len, int cmdline_ptr) {
            int child_stack = 0;
            int ptr_base = 0;
            int user_cr3 = 0;
            int entry = prepare_process (name_ptr, name_len, cmdline_ptr, out child_stack, out ptr_base, out user_cr3);
            if (entry == 0)
                return -1;
            int tid = Sched.spawn_user_ready (entry, ptr_base, child_stack, USER_STACK_PAGES, user_cr3, name_ptr, name_len);
            if (tid < 0) {
                Vmm.destroy_user_space (user_cr3);
                for (int p = 0; p < USER_STACK_PAGES; p++) {
                    Pmm.free_frame (child_stack + p * 4096);
                }
            }
            return tid;
        }
    }
}
