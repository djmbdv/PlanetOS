// Minimal ELF64 userland loader and synchronous exec trampoline for PlanetOS.

namespace Planet.Kernel {

    private int exec_depth = 0;

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

    public class ElfLoader : Object {
        private static int read_u8 (int addr) {
            int w = mmio_read32 (addr & ~3);
            return (w >> ((addr & 3) * 8)) & 0xFF;
        }

        private static int read_u16 (int addr) {
            return read_u8 (addr) | (read_u8 (addr + 1) << 8);
        }

        public static int load_image (int buf, int size, int user_cr3 = 0) {
            if (size < 64)
                return 0;
            int magic = mmio_read32 (buf) & 0xFFFFFFFF;
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
            int sp = 0x1FE000;
            int str = 0x1FE800;
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
            int esz = (kind == Vfs.KIND_FILE) ? Ramfs.file_size (id) : Xfs.file_size (id);
            if (esz < 64)
                return 0;
            int pages = (esz + 4095) / 4096;
            int ebuf = Pmm.alloc_contiguous (pages);
            if (ebuf == 0)
                return 0;
            int user_cr3 = Vmm.create_user_space ();
            if (user_cr3 == 0) {
                for (int p = 0; p < pages; p++)
                    Pmm.free_frame (ebuf + p * 4096);
                return 0;
            }
            int got = (kind == Vfs.KIND_FILE) ? Ramfs.read (id, 0, ebuf, esz) : Xfs.read_file (id, 0, ebuf, esz);
            int entry = (got == esz) ? load_image (ebuf, esz, user_cr3) : 0;
            for (int p = 0; p < pages; p++) {
                Pmm.free_frame (ebuf + p * 4096);
            }
            if (entry == 0) {
                Vmm.destroy_user_space (user_cr3);
                return 0;
            }

            int stack_pages = 17; // 1 bottom guard page + 16 usable stack pages
            int child_stack = Pmm.alloc_contiguous (stack_pages);
            if (child_stack == 0) {
                Vmm.destroy_user_space (user_cr3);
                return 0;
            }
            Vmm.map_user_range (user_cr3, child_stack + 4096, 16 * 4096);
            Vmm.unmap_user_4k (user_cr3, child_stack);

            // Build Linux-compatible argc/argv[] at top of child_stack
            int stack_top = child_stack + stack_pages * 4096;
            int str_base = stack_top - 1024;
            int argc = 0;
            int ptr_base = str_base - 256;
            int s_pos = 0;
            if (cmdline_ptr != 0) {
                int i = 0;
                while (i < 1000) {
                    int b = read_u8 (cmdline_ptr + i);
                    if (b == 0)
                        break;
                    while (b == ' ') {
                        i = i + 1;
                        b = read_u8 (cmdline_ptr + i);
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
                        b = read_u8 (cmdline_ptr + i);
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
            int prev_cr3 = Sched.current_cr3 ();
            int prev_rsp0 = Hal.get_tss_rsp0 ();
            exec_depth = exec_depth + 1;
            int slot = 0x106200 + (exec_depth - 1) * 32;
            Sched.set_current_exec_ctx (user_cr3, 0);
            int code = exec_trampoline (entry, ptr_base, user_cr3, slot);
            Sched.set_current_exec_ctx (prev_cr3, prev_rsp0);
            Vmm.destroy_user_space (user_cr3);
            for (int p = 0; p < 17; p++) {
                Pmm.free_frame (child_stack + p * 4096);
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
            int tid = Sched.spawn_user_ready (entry, ptr_base, child_stack, 17, user_cr3, name_ptr, name_len);
            if (tid < 0) {
                Vmm.destroy_user_space (user_cr3);
                for (int p = 0; p < 17; p++) {
                    Pmm.free_frame (child_stack + p * 4096);
                }
            }
            return tid;
        }
    }
}
