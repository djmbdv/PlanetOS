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
    serial_init ();
    var b = new KernelBanner ("PlanetOS", 0, 1);
    b.announce ();
    Hal.print_cpu_vendor ();
    Hal.init_interrupts ();
    Pmm.init ();
    Syscalls.init ();

    int f0 = Pmm.free_frames ();
    int p1 = invoke_syscall (3, 0, 0);
    int p2 = invoke_syscall (3, 0, 0);
    print (@"pmm:free=$f0 p1=$p1 p2=$p2\n");
    invoke_syscall (4, p1, 0);
    invoke_syscall (4, p2, 0);
    int f1 = Pmm.free_frames ();
    print (@"pmm:restored=$(f1 == f0 ? 1 : 0)\n");

    var ch = new Channel<int> ();
    ticker_task.begin (ch, 3);
    logger_task.begin (ch, 3);
    Async.run ();

    int sc_ticks = invoke_syscall (2, 0, 0);
    print (@"sys:ticks=$sc_ticks\n");
    print ("kernel:ok\n");
    qemu_debug_exit (0);
    return 0;
}
