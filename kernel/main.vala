// Minimal freestanding PlanetOS kernel entry point.

using Planet.Rt;

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

int main () {
    serial_init ();
    var b = new KernelBanner ("PlanetOS", 0, 1);
    b.announce ();
    print ("kernel:ok\n");
    qemu_debug_exit (0);
    return 0;
}
