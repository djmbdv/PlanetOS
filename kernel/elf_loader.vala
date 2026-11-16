// Minimal ELF64 userland loader and synchronous exec trampoline for PlanetOS.

namespace Planet.Kernel {

    private int exec_depth = 0;

    [AsmBody(@"
        push %rdi
        ret
    ")]
    public extern void jump_to_entry (int entry_addr);

    [AsmBody(@"
        # exec_trampoline(entry_addr in rdi, child_stack_top in rsi) -> exit_code in rax
        push %rbx
        push %rbp
        push %r12
        push %r13
        push %r14
        push %r15
        mov $0x106100, %rax
        mov %rsp, (%rax)
        mov %rsi, %rsp
        sti
        push %rdi
        ret
    ")]
    public extern int exec_trampoline (int entry_addr, int child_stack_top);

    [AsmBody(@"
        # exec_return_to_parent(exit_code in rdi) -> resumes exec_trampoline caller
        mov %rdi, %rax
        mov $0x106100, %rdx
        mov (%rdx), %rsp
        pop %r15
        pop %r14
        pop %r13
        pop %r12
        pop %rbp
        pop %rbx
        ret
    ")]
    public extern void exec_return_to_parent (int exit_code);

    public class ElfLoader : Object {
        private static int read_u8 (int addr) {
            int w = mmio_read32 (addr & ~3);
            return (w >> ((addr & 3) * 8)) & 0xFF;
        }

        private static int read_u16 (int addr) {
            return read_u8 (addr) | (read_u8 (addr + 1) << 8);
        }

        public static int load_image (int buf, int size) {
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

                Pmm.reserve_range (p_vaddr, p_memsz);

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
            jump_to_entry (entry);
            return true;
        }

        public static int exec_from_xfs (int name_ptr, int name_len) {
            int rslot = Ramfs.find (name_ptr, name_len);
            int ino = (rslot >= 0) ? 0 : Xfs.lookup_root (name_ptr, name_len);
            if (rslot < 0 && ino <= 0)
                return -1;
            int esz = (rslot >= 0) ? Ramfs.file_size (rslot) : Xfs.file_size (ino);
            if (esz < 64)
                return -1;
            int pages = (esz + 4095) / 4096;
            int ebuf = Pmm.alloc_contiguous (pages);
            if (ebuf == 0)
                return -1;
            int got = (rslot >= 0) ? Ramfs.read (rslot, 0, ebuf, esz) : Xfs.read_file (ino, ebuf, esz);
            int entry = (got == esz) ? load_image (ebuf, esz) : 0;
            for (int p = 0; p < pages; p++) {
                Pmm.free_frame (ebuf + p * 4096);
            }
            if (entry == 0)
                return -1;

            int stack_pages = 4;
            int child_stack = Pmm.alloc_contiguous (stack_pages);
            if (child_stack == 0)
                return -1;

            exec_depth = exec_depth + 1;
            int code = exec_trampoline (entry, child_stack + stack_pages * 4096);
            for (int p = 0; p < stack_pages; p++) {
                Pmm.free_frame (child_stack + p * 4096);
            }
            return code;
        }
    }
}
