// Minimal ELF64 userland loader for PlanetOS.

namespace Planet.Kernel {

    [AsmBody(@"
        push %rdi
        ret
    ")]
    public extern void jump_to_entry (int entry_addr);

    public class ElfLoader : Object {
        private static int read_u8 (int addr) {
            int w = mmio_read32 (addr & ~3);
            return (w >> ((addr & 3) * 8)) & 0xFF;
        }

        private static int read_u16 (int addr) {
            return read_u8 (addr) | (read_u8 (addr + 1) << 8);
        }

        public static bool load_and_run (int buf, int size) {
            if (size < 64)
                return false;
            int magic = mmio_read32 (buf) & 0xFFFFFFFF;
            if (magic != 0x464C457F) {
                print ("elf: bad magic\n");
                return false;
            }
            int machine = read_u16 (buf + 18);
            if (machine != 62) {
                print ("elf: not x86-64\n");
                return false;
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

            print ("elf: jumping to init.elf\n");
            jump_to_entry (entry);
            return true;
        }
    }
}
