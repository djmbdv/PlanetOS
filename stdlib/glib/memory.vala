// Pure-Vala GLib.Memory with AVX2 copy/set and page-backed allocator for PlanetOS.
using Planet;

namespace GLib {

    [AsmBody(@"
        # __mem_copy_avx2(dst in rdi, src in rsi, n in rdx)
        cmp $32, %rdx
        jb _mc_tail
    _mc_avx:
        .byte 0xc5, 0xfe, 0x6f, 0x06
        .byte 0xc5, 0xfe, 0x7f, 0x07
        add $32, %rsi
        add $32, %rdi
        sub $32, %rdx
        cmp $32, %rdx
        jae _mc_avx
        .byte 0xc5, 0xf8, 0x77
    _mc_tail:
        test %rdx, %rdx
        jz _mc_done
    _mc_byte:
        .byte 0x8a, 0x06
        .byte 0x88, 0x07
        inc %rsi
        inc %rdi
        dec %rdx
        jnz _mc_byte
    _mc_done:
        ret
    ")]
    private extern void __mem_copy_avx2 (int dst, int src, size_t n);

    [AsmBody(@"
        # __mem_copy_back(dst in rdi, src in rsi, n in rdx) - AVX2 32B/iter + 1B tail
        test %rdx, %rdx
        jz _mb_done
        add %rdx, %rdi
        add %rdx, %rsi
        cmp $32, %rdx
        jb _mb_tail
    _mb_avx:
        sub $32, %rsi
        sub $32, %rdi
        .byte 0xc5, 0xfe, 0x6f, 0x06
        .byte 0xc5, 0xfe, 0x7f, 0x07
        sub $32, %rdx
        cmp $32, %rdx
        jae _mb_avx
        .byte 0xc5, 0xf8, 0x77
    _mb_tail:
        test %rdx, %rdx
        jz _mb_done
    _mb_loop:
        dec %rdi
        dec %rsi
        .byte 0x8a, 0x06
        .byte 0x88, 0x07
        dec %rdx
        jnz _mb_loop
    _mb_done:
        ret
    ")]
    private extern void __mem_copy_back (int dst, int src, size_t n);

    [AsmBody(@"
        # __mem_set_avx2(dst in rdi, val in rsi, n in rdx)
        mov %esi, %eax
        and $0xff, %eax
        .byte 0x69, 0xc0, 0x01, 0x01, 0x01, 0x01
        cmp $32, %rdx
        jb _ms_tail
        .byte 0xc5, 0xf9, 0x6e, 0xc0
        .byte 0xc4, 0xe2, 0x7d, 0x58, 0xc0
    _ms_avx:
        .byte 0xc5, 0xfe, 0x7f, 0x07
        add $32, %rdi
        sub $32, %rdx
        cmp $32, %rdx
        jae _ms_avx
        .byte 0xc5, 0xf8, 0x77
    _ms_tail:
        test %rdx, %rdx
        jz _ms_done
    _ms_byte:
        .byte 0x88, 0x07
        inc %rdi
        dec %rdx
        jnz _ms_byte
    _ms_done:
        ret
    ")]
    private extern void __mem_set_avx2 (int dst, int val, size_t n);

    [AsmBody(@"
        # __mem_cmp(s1 in rdi, s2 in rsi, n in rdx) -> rax - AVX2 32B/iter + bsf mismatch
        cmp $32, %rdx
        jb _mp_tail
    _mp_avx:
        .byte 0xc5, 0xfe, 0x6f, 0x07
        .byte 0xc5, 0xfe, 0x6f, 0x0e
        .byte 0xc5, 0xfd, 0x74, 0xc1
        .byte 0xc5, 0xfd, 0xd7, 0xc0
        .byte 0x83, 0xf8, 0xff
        jne _mp_mismatch
        add $32, %rdi
        add $32, %rsi
        sub $32, %rdx
        cmp $32, %rdx
        jae _mp_avx
        .byte 0xc5, 0xf8, 0x77
        jmp _mp_tail
    _mp_mismatch:
        .byte 0xc5, 0xf8, 0x77
        .byte 0xf7, 0xd0
        .byte 0x0f, 0xbc, 0xc8
        .byte 0x0f, 0xb6, 0x04, 0x0f
        .byte 0x0f, 0xb6, 0x0c, 0x0e
        sub %rcx, %rax
        ret
    _mp_tail:
        xor %eax, %eax
        test %rdx, %rdx
        jz _mp_done
    _mp_loop:
        .byte 0x0f, 0xb6, 0x07
        .byte 0x0f, 0xb6, 0x0e
        cmp %ecx, %eax
        jne _mp_diff
        inc %rdi
        inc %rsi
        dec %rdx
        jnz _mp_loop
        xor %eax, %eax
        ret
    _mp_diff:
        sub %rcx, %rax
    _mp_done:
        ret
    ")]
    private extern int __mem_cmp (int s1, int s2, size_t n);

    [AsmBody(@"
        # __mem_poke64(addr in rdi, val in rsi)
        mov %rsi, (%rdi)
        ret
    ")]
    private extern void __mem_poke64 (int addr, int val);

    [AsmBody(@"
        # __mem_peek64(addr in rdi) -> rax
        mov (%rdi), %rax
        ret
    ")]
    private extern int __mem_peek64 (int addr);

    /**
     * Raw memory operations and page-backed allocator (GLib.Memory).
     */
    public class Memory : Object {
        private const int ALLOC_MAGIC = 0x4D454D50; // "MEMP"
        private const int HDR_BYTES = 16;

        public static void copy (int dest, int src, size_t n) {
            if (dest == 0 || src == 0 || n == 0 || dest == src)
                return;
            __mem_copy_avx2 (dest, src, n);
        }

        public static void move (int dest, int src, size_t n) {
            if (dest == 0 || src == 0 || n == 0 || dest == src)
                return;
            if (dest > src && (uint64) dest < (uint64) src + (uint64) n)
                __mem_copy_back (dest, src, n);
            else
                __mem_copy_avx2 (dest, src, n);
        }

        public static void set (int dest, int val, size_t n) {
            if (dest == 0 || n == 0)
                return;
            __mem_set_avx2 (dest, val, n);
        }

        public static int cmp (int s1, int s2, size_t n) {
            if (n == 0 || s1 == s2)
                return 0;
            if (s1 == 0)
                return -1;
            if (s2 == 0)
                return 1;
            return __mem_cmp (s1, s2, n);
        }

        public static int malloc (size_t n_bytes) {
            if (n_bytes == 0)
                return 0;
            uint64 total = (uint64) n_bytes + (uint64) HDR_BYTES;
            if (total < (uint64) n_bytes || total > (uint64) (1024 * 4096))
                return 0;
            int pages = (int) ((total + 4095UL) / 4096UL);
            int base_addr = Sys.alloc_pages (pages);
            if (base_addr <= 0)
                return 0;
            __mem_poke64 (base_addr + 0, ALLOC_MAGIC);
            __mem_poke64 (base_addr + 8, pages);
            return base_addr + HDR_BYTES;
        }

        public static int malloc0 (size_t n_bytes) {
            int p = malloc (n_bytes);
            if (p != 0)
                set (p, 0, n_bytes);
            return p;
        }

        public static void free (int mem) {
            if (mem <= HDR_BYTES)
                return;
            int base_addr = mem - HDR_BYTES;
            if (base_addr < 0x100000 || (base_addr & 0xFFF) != 0)
                return;
            if (__mem_peek64 (base_addr + 0) != ALLOC_MAGIC)
                return;
            int pages = __mem_peek64 (base_addr + 8);
            if (pages <= 0 || pages > 1024)
                return;
            __mem_poke64 (base_addr + 0, 0);
            for (int i = 0; i < pages; i++)
                Sys.free_page (base_addr + i * 4096);
        }

        public static int realloc (int mem, size_t n_bytes) {
            if (mem == 0)
                return malloc (n_bytes);
            if (n_bytes == 0) {
                free (mem);
                return 0;
            }
            int base_addr = mem - HDR_BYTES;
            if (base_addr < 0x100000 || (base_addr & 0xFFF) != 0 || __mem_peek64 (base_addr + 0) != ALLOC_MAGIC)
                return 0;
            int old_pages = __mem_peek64 (base_addr + 8);
            if (old_pages <= 0 || old_pages > 1024)
                return 0;
            size_t old_cap = (size_t) (old_pages * 4096 - HDR_BYTES);
            if (n_bytes <= old_cap)
                return mem;
            int np = malloc (n_bytes);
            if (np == 0)
                return 0;
            copy (np, mem, old_cap);
            free (mem);
            return np;
        }

        public static int dup (int mem, uint byte_size) {
            if (mem == 0 || byte_size == 0)
                return 0;
            int p = malloc ((size_t) byte_size);
            if (p != 0)
                copy (p, mem, (size_t) byte_size);
            return p;
        }
    }
}
