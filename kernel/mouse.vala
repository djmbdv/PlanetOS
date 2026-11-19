// PS/2 Mouse driver (IRQ12 / vector 44, 3-byte packet decoder).

namespace Planet.Kernel {

    public static void ps2_wait_write () {
        for (int i = 0; i < 10000; i++) {
            if ((port_in8 (0x64) & 0x02) == 0)
                return;
        }
    }

    public static void ps2_wait_read () {
        for (int i = 0; i < 10000; i++) {
            if ((port_in8 (0x64) & 0x01) != 0)
                return;
        }
    }

    public static void out64 (int cmd) { port_out8 (0x64, cmd); }
    public static void out60 (int data) { port_out8 (0x60, data); }
    public static int in60 () { return port_in8 (0x60); }
    public static int in64 () { return port_in8 (0x64); }

    [AsmBody(@"
        # Desenmascara IRQ2 (cascada en PIC maestro 0x21) e IRQ12 (raton en PIC esclavo 0xA1)
        in $0x21, %al
        and $0xFB, %al
        out %al, $0x21
        in $0xA1, %al
        and $0xEF, %al
        out %al, $0xA1
        ret
    ")]
    public extern void pic_unmask_irq12 ();

    [AsmBody(@"
        # Handler de interrupcion IRQ12 (vector 44): lee byte del raton en 0x60,
        # lo inserta en el ring buffer circular de 256 bytes en 0x106300 (head en 0x106400)
        # y envia EOI (0x20) al PIC esclavo (0xA0) y al maestro (0x20)
        push %rax
        push %rcx
        push %rdx
        mov $0x60, %dx
        in %dx, %al
        movzbl %al, %eax
        mov $0x106400, %rcx
        mov (%rcx), %edx
        and $255, %edx
        mov %al, 0x106300(%rdx)
        inc %edx
        and $255, %edx
        mov %edx, (%rcx)
        mov $0x20, %al
        out %al, $0xA0
        out %al, $0x20
        pop %rdx
        pop %rcx
        pop %rax
        iretq
    ")]
    public extern void isr_irq12 ();

    [AsmBody(@"
        lea isr_irq12(%rip), %rax
        ret
    ")]
    public extern int addr_isr_irq12 ();

    private int mouse_x = 400;
    private int mouse_y = 300;
    private int mouse_btn = 0;
    private int mouse_wheel = 0;
    private int mouse_phase = 0;
    private int mouse_b0 = 0;
    private int mouse_b1 = 0;
    private int mouse_b2 = 0;
    private bool mouse_has_wheel = false;

    // Counters: cheap, always on, and enough to tell "no bytes arrive" from
    // "bytes arrive but the decoder drops them" without per-event logging.
    private int mouse_bytes = 0;
    private int mouse_packets = 0;
    private int mouse_resync = 0;

    public class Mouse : Object {
        private static void send_mouse (int val) {
            ps2_wait_write ();
            out64 (0xD4);
            ps2_wait_write ();
            out60 (val);
            ps2_wait_read ();
            // Drain everything the device answered (ACK plus anything it had
            // queued). Leaving a byte behind used to put the packet decoder
            // one byte out of phase for the rest of the session.
            for (int i = 0; i < 8 && (in64 () & 0x01) != 0; i++)
                in60 ();
        }

        private static void send_mouse_arg (int cmd, int arg) {
            send_mouse (cmd);
            send_mouse (arg);
        }

        private static int query_mouse_id () {
            ps2_wait_write ();
            out64 (0xD4);
            ps2_wait_write ();
            out60 (0xF2);
            ps2_wait_read ();
            int ack = in60 ();
            int id = 0;
            if (ack == 0xFA) {
                ps2_wait_read ();
                if ((in64 () & 0x01) != 0)
                    id = in60 ();
            }
            for (int i = 0; i < 8 && (in64 () & 0x01) != 0; i++)
                in60 ();
            return id;
        }

        public static void init () {
            for (int f = 0; f < 32 && (in64 () & 0x01) != 0; f++) {
                in60 ();
            }
            mmio_write32 (KernelLayout.MOUSE_HEAD, 0);
            mmio_write32 (KernelLayout.MOUSE_TAIL, 0);
            mouse_phase = 0;
            mouse_wheel = 0;
            mouse_has_wheel = false;
            ps2_wait_write ();
            out64 (0xA8); // Enable auxiliary PS/2 port
            ps2_wait_write ();
            out64 (0x20); // Read controller config
            ps2_wait_read ();
            int cfg = (in60 () | 0x02) & ~0x20;
            ps2_wait_write ();
            out64 (0x60);
            ps2_wait_write ();
            out60 (cfg);
            send_mouse (0xF6); // Defaults
            // IntelliMouse wheel probe sequence (sample rates 200, 100, 80).
            send_mouse_arg (0xF3, 200);
            send_mouse_arg (0xF3, 100);
            send_mouse_arg (0xF3, 80);
            int mid = query_mouse_id ();
            if (mid == 3 || mid == 4)
                mouse_has_wheel = true;
            send_mouse (0xF4); // Enable data reporting
            Hal.set_idt_gate_dpl (44, addr_isr_irq12 (), 0);
            pic_unmask_irq12 ();
            Klog.info (Klog.CAT_INPUT, mouse_has_wheel
                ? "ps/2 intellimouse wheel enabled (irq12)"
                : "ps/2 mouse enabled (irq12)");
        }

        private static int poll_byte () {
            int head = mmio_read32 (KernelLayout.MOUSE_HEAD);
            int tail = mmio_read32 (KernelLayout.MOUSE_TAIL);
            if (head == tail)
                return -1;
            int addr = KernelLayout.MOUSE_RING + (tail & 255);
            int v = (mmio_read32 (addr & ~3) >> ((addr & 3) * 8)) & 0xFF;
            mmio_write32 (KernelLayout.MOUSE_TAIL, (tail + 1) & 255);
            return v;
        }

        private static void commit_packet (int b2, int dz) {
            if ((mouse_b0 & 0xC0) == 0) {
                int dx = ((mouse_b0 & 0x10) != 0) ? (mouse_b1 - 256) : mouse_b1;
                int dy = ((mouse_b0 & 0x20) != 0) ? (b2 - 256) : b2;
                int max_x = (Fb.width () > 0) ? (Fb.width () - 1) : 799;
                int max_y = (Fb.height () > 0) ? (Fb.height () - 1) : 599;
                mouse_x = mouse_x + dx;
                mouse_y = mouse_y - dy;
                if (mouse_x < 0) mouse_x = 0;
                if (mouse_x > max_x) mouse_x = max_x;
                if (mouse_y < 0) mouse_y = 0;
                if (mouse_y > max_y) mouse_y = max_y;
            }
            mouse_btn = mouse_b0 & 0x07;
            mouse_wheel = mouse_wheel + dz;
            mouse_phase = 0;
            mouse_packets = mouse_packets + 1;
            if (Klog.enabled (Klog.CAT_INPUT))
                Klog.debug (Klog.CAT_INPUT, @"x=$(mouse_x) y=$(mouse_y) btn=$(mouse_btn) w=$(mouse_wheel)");
        }

        public static void poll_state (int out_buf) {
            while (true) {
                int b = poll_byte ();
                if (b < 0)
                    break;
                mouse_bytes = mouse_bytes + 1;
                if (mouse_phase == 0) {
                    if ((b & 0x08) == 0 || (b & 0xC0) != 0) {
                        mouse_resync = mouse_resync + 1;
                        continue;
                    }
                    mouse_b0 = b;
                    mouse_phase = 1;
                } else if (mouse_phase == 1) {
                    mouse_b1 = b;
                    mouse_phase = 2;
                } else if (mouse_phase == 2) {
                    if (mouse_has_wheel) {
                        mouse_b2 = b;
                        mouse_phase = 3;
                    } else {
                        commit_packet (b, 0);
                    }
                } else {
                    int dz = b & 0x0F;
                    if ((dz & 0x08) != 0)
                        dz = dz - 16;
                    commit_packet (mouse_b2, dz);
                }
            }
            if (out_buf != 0) {
                mmio_write64 (out_buf + 0, mouse_x);
                mmio_write64 (out_buf + 8, mouse_y);
                mmio_write64 (out_buf + 16, mouse_btn);
                mmio_write64 (out_buf + 24, mouse_packets);
                mmio_write64 (out_buf + 32, mouse_bytes);
                mmio_write64 (out_buf + 40, mouse_resync);
                mmio_write64 (out_buf + 48, mouse_wheel);
            }
        }
    }
}
