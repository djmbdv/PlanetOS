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

    var ch = new Channel<int> ();
    ticker_task.begin (ch, 3);
    logger_task.begin (ch, 3);
    Async.run ();

    print ("kernel:ok\n");
    qemu_debug_exit (0);
    return 0;
}
