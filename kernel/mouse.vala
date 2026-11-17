// PS/2 Mouse driver (IRQ12 / vector 44, 3-byte packet decoder).

namespace Planet.Kernel {

    [AsmBody(@"
        # Espera (con limite) a que el controlador PS/2 8042 pueda recibir comandos (bit 1 de 0x64 = 0)
        mov $10000, %rcx
    _ps2_w_wait:
        in $0x64, %al
        test $0x02, %al
        jz _ps2_w_done
        dec %rcx
        jnz _ps2_w_wait
    _ps2_w_done:
        ret
    ")]
    public extern void ps2_wait_write ();

    [AsmBody(@"
        # Espera (con limite) a que haya un byte disponible en el buffer de salida PS/2 (bit 0 de 0x64 = 1)
        mov $10000, %rcx
    _ps2_r_wait:
        in $0x64, %al
        test $0x01, %al
        jnz _ps2_r_done
        dec %rcx
        jnz _ps2_r_wait
    _ps2_r_done:
        ret
    ")]
    public extern void ps2_wait_read ();

    [AsmBody(@"
        # Envia byte de comando al puerto de control 0x64 del 8042 (cmd en rdi)
        mov %dil, %al
        out %al, $0x64
        ret
    ")]
    public extern void out64 (int cmd);

    [AsmBody(@"
        # Envia byte de datos al puerto 0x60 del 8042 (data en rdi)
        mov %dil, %al
        out %al, $0x60
        ret
    ")]
    public extern void out60 (int data);

    [AsmBody(@"
        # Lee un byte del puerto de datos 0x60 del 8042
        xor %eax, %eax
        in $0x60, %al
        ret
    ")]
    public extern int in60 ();

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
        # lo inserta en el ring buffer circular de 64 bytes en 0x106300 (head en 0x106340)
        # y envia EOI (0x20) al PIC esclavo (0xA0) y al maestro (0x20)
        push %rax
        push %rcx
        push %rdx
        mov $0x60, %dx
        in %dx, %al
        movzbl %al, %eax
        mov $0x106340, %rcx
        mov (%rcx), %edx
        and $63, %edx
        mov %al, 0x106300(%rdx)
        inc %edx
        and $63, %edx
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
    private int mouse_phase = 0;
    private int mouse_b0 = 0;
    private int mouse_b1 = 0;

    public class Mouse : Object {
        private const int M_BUF = 0x106300;
        private const int M_HEAD = 0x106340;
        private const int M_TAIL = 0x106348;

        private static void send_mouse (int val) {
            ps2_wait_write ();
            out64 (0xD4);
            ps2_wait_write ();
            out60 (val);
            ps2_wait_read ();
            in60 (); // ACK
        }

        public static void init () {
            mmio_write32 (M_HEAD, 0);
            mmio_write32 (M_TAIL, 0);
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
            send_mouse (0xF4); // Enable data reporting
            Hal.set_idt_gate_dpl (44, addr_isr_irq12 (), 0);
            pic_unmask_irq12 ();
        }

        private static int poll_byte () {
            int head = mmio_read32 (M_HEAD);
            int tail = mmio_read32 (M_TAIL);
            if (head == tail)
                return -1;
            int addr = M_BUF + (tail & 63);
            int v = (mmio_read32 (addr & ~3) >> ((addr & 3) * 8)) & 0xFF;
            mmio_write32 (M_TAIL, (tail + 1) & 63);
            return v;
        }

        public static void poll_state (int out_buf) {
            while (true) {
                int b = poll_byte ();
                if (b < 0)
                    break;
                if (mouse_phase == 0) {
                    if ((b & 0x08) == 0)
                        continue;
                    mouse_b0 = b;
                    mouse_phase = 1;
                } else if (mouse_phase == 1) {
                    mouse_b1 = b;
                    mouse_phase = 2;
                } else {
                    if ((mouse_b0 & 0xC0) == 0) {
                        int dx = ((mouse_b0 & 0x10) != 0) ? (mouse_b1 - 256) : mouse_b1;
                        int dy = ((mouse_b0 & 0x20) != 0) ? (b - 256) : b;
                        mouse_x = mouse_x + dx;
                        mouse_y = mouse_y - dy;
                        if (mouse_x < 0) mouse_x = 0;
                        if (mouse_x > 799) mouse_x = 799;
                        if (mouse_y < 0) mouse_y = 0;
                        if (mouse_y > 599) mouse_y = 599;
                    }
                    mouse_btn = mouse_b0 & 0x07;
                    mouse_phase = 0;
                }
            }
            if (out_buf != 0) {
                mmio_write64 (out_buf + 0, mouse_x);
                mmio_write64 (out_buf + 8, mouse_y);
                mmio_write64 (out_buf + 16, mouse_btn);
            }
        }
    }
}
