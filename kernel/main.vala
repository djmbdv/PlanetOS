// PlanetOS freestanding kernel entry point.

using Planet.Rt;
using Planet.Kernel;

class KernelBanner {
    public string name;
    public int major;
    public int minor;

    public KernelBanner (string name, int major, int minor) {
        this.name = name;
        this.major = major;
        this.minor = minor;
    }

    public void announce () {
        print (@"$(this.name) v$(this.major).$(this.minor) booted in x86-64 Long Mode (freestanding Vala + planc)\n");
    }
}

async void ticker_task (Channel<int> ch, int target) {
    int last = 0;
    while (last < target) {
        int cur = Hal.ticks ();
        if (cur > last) {
            last = cur;
            ch.send (cur);
        } else {
            cpu_hlt ();
            yield;
        }
    }
    ch.close ();
}

async void logger_task (Channel<int> ch, int target) {
    for (int i = 0; i < target; i++) {
        var t = yield ch.recv ();
        print (@"irq0 tick=$t\n");
    }
}

int main () {
    cpu_enable_sse ();
    serial_init ();
    Vga.init ();
    var b = new KernelBanner ("PlanetOS", 0, 1);
    b.announce ();
    // The structures the compiler cannot place (page tables, rings, tables)
    // come from a fixed window: refuse to run on a window that overlaps itself
    // or runs into the boot stack / PMM / image.
    int layout_code = KernelLayout.verify ();
    print (@"layout:ok=$(layout_code == 0 ? 1 : 0)\n");
    Klog.write (Klog.CAT_BOOT, layout_code == 0 ? Klog.LVL_INFO : Klog.LVL_ERROR,
                layout_code == 0 ? "low-memory window verified" : "low-memory window broken");
    if (layout_code != 0) {
        print (@"layout:fail=$(layout_code)\n");
        while (true) {
            cpu_hlt ();
        }
    }
    Hal.print_cpu_vendor ();
    print (@"cpu:simd sse41=$(Hal.has_sse41 () ? 1 : 0) avx2=$(Hal.has_avx2 () ? 1 : 0)\n");
    Hal.init_interrupts ();
    Pmm.init ();
    Vmm.init ();
    Env.init ();
    Ramfs.init ();
    Syscalls.init ();

    int g1 = invoke_syscall (6, 0, 0, 0);
    int g2 = invoke_syscall (15, 3, 0, 16);
    int g3 = invoke_syscall (30, 0x10, 4, 0);
    bool guard_ok = (g1 == -1) && (g2 == -1) && (g3 == -1);
    print (@"sysguard:ok=$(guard_ok ? 1 : 0)\n");
    Keyboard.init ();
    Mouse.init ();

    int f0 = Pmm.free_frames ();
    int p1 = invoke_syscall (3, 0, 0, 0);
    int p2 = invoke_syscall (3, 0, 0, 0);
    print (@"pmm:free=$f0 p1=$p1 p2=$p2\n");
    invoke_syscall (4, p1, 0, 0);
    invoke_syscall (4, p2, 0, 0);
    int f1 = Pmm.free_frames ();
    print (@"pmm:restored=$(f1 == f0 ? 1 : 0)\n");

    var ch = new Channel<int> ();
    ticker_task.begin (ch, 3);
    logger_task.begin (ch, 3);
    Async.run ();

    int sc_ticks = invoke_syscall (2, 0, 0, 0);
    print (@"sys:ticks=$sc_ticks\n");

    int kb_empty = Keyboard.poll_scancode ();
    int kb_a = Keyboard.scancode_to_ascii (0x1E);
    print (@"kb:ok=$(kb_empty == -1 && kb_a == 'a' ? 1 : 0)\n");

    bool ata_ok = Ata.init ();
    if (ata_ok)
        print (@"ata:sectors=$(Ata.total_sectors ()) lba48=$(Ata.has_lba48 () ? 1 : 0)\n");

    VirtioGpu.init ();
    if (VirtioGpu.is_present ()) {
        print (@"virtio_gpu:found=1 w=$(VirtioGpu.display_width ()) h=$(VirtioGpu.display_height ()) virgl=$(VirtioGpu.has_virgl () ? 1 : 0) blob=$(VirtioGpu.has_blob () ? 1 : 0) ctx=$(VirtioGpu.has_ctx_init () ? 1 : 0) venus=$(VirtioGpu.has_venus () ? 1 : 0)\n");
        Klog.info (Klog.CAT_GPU, @"present virgl=$(VirtioGpu.has_virgl () ? 1 : 0) blob=$(VirtioGpu.has_blob () ? 1 : 0) venus=$(VirtioGpu.has_venus () ? 1 : 0)");
        Vga.activate_virtio_console ();
    } else {
        Klog.info (Klog.CAT_GPU, "no virtio-gpu device, using VGA");
    }

    int xok = Xfs.mount () ? 1 : 0;
    print (@"xfs:mounted=$xok\n");
    if (xok == 1) {
        int xbuf = Pmm.alloc_frame ();
        // Write "hello.txt" into xbuf+1024 to test SYS_OPEN / SYS_READ / SYS_CONSOLE_WRITE
        int nbuf = xbuf + 1024;
        mmio_write8 (nbuf + 0, 'h');
        mmio_write8 (nbuf + 1, 'e');
        mmio_write8 (nbuf + 2, 'l');
        mmio_write8 (nbuf + 3, 'l');
        mmio_write8 (nbuf + 4, 'o');
        mmio_write8 (nbuf + 5, '.');
        mmio_write8 (nbuf + 6, 't');
        mmio_write8 (nbuf + 7, 'x');
        mmio_write8 (nbuf + 8, 't');
        int fd = invoke_syscall (6, nbuf, 9, 0);
        int sz = invoke_syscall (9, fd, 0, 0);
        int nr = invoke_syscall (7, fd, xbuf, 128);
        print (@"xfs:fd=$fd sz=$sz nr=$nr\n");
        if (nr > 0)
            invoke_syscall (1, xbuf, nr, 0);
        invoke_syscall (8, fd, 0, 0);
        Pmm.free_frame (xbuf);
    }

    print ("kernel:ok\n");

    if (xok == 1) {
        int nbuf2 = Pmm.alloc_frame ();
        // Try shell.elf first, then init.elf
        mmio_write8 (nbuf2 + 0, 's');
        mmio_write8 (nbuf2 + 1, 'h');
        mmio_write8 (nbuf2 + 2, 'e');
        mmio_write8 (nbuf2 + 3, 'l');
        mmio_write8 (nbuf2 + 4, 'l');
        mmio_write8 (nbuf2 + 5, '.');
        mmio_write8 (nbuf2 + 6, 'e');
        mmio_write8 (nbuf2 + 7, 'l');
        mmio_write8 (nbuf2 + 8, 'f');
        int efd = invoke_syscall (6, nbuf2, 9, 0);
        if (efd < 0) {
            mmio_write8 (nbuf2 + 0, 'i');
            mmio_write8 (nbuf2 + 1, 'n');
            mmio_write8 (nbuf2 + 2, 'i');
            mmio_write8 (nbuf2 + 3, 't');
            mmio_write8 (nbuf2 + 4, '.');
            mmio_write8 (nbuf2 + 5, 'e');
            mmio_write8 (nbuf2 + 6, 'l');
            mmio_write8 (nbuf2 + 7, 'f');
            efd = invoke_syscall (6, nbuf2, 8, 0);
        }
        Pmm.free_frame (nbuf2);
        if (efd >= 0) {
            int esz = invoke_syscall (9, efd, 0, 0);
            int pages = (esz + 4095) / 4096;
            int ebuf = Pmm.alloc_contiguous (pages);
            if (ebuf != 0) {
                int got = 0;
                while (got < esz) {
                    int r = invoke_syscall (7, efd, ebuf + got, esz - got);
                    if (r <= 0)
                        break;
                    got = got + r;
                }
                invoke_syscall (8, efd, 0, 0);
                if (got == esz) {
                    Sched.init ();
                    ElfLoader.load_and_run (ebuf, esz);
                }
            }
        }
    }

    invoke_syscall (11, 0, 0, 0);
    return 0;
}
