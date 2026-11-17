// MC146818 CMOS Real-Time Clock driver for PlanetOS.

namespace Planet.Kernel {

    [AsmBody(@"
        # __rtc_read_reg(reg in rdi) -> al
        mov %dil, %al
        outb %al, $0x70
        inb $0x71, %al
        movzbl %al, %eax
        ret
    ")]
    private extern int __rtc_read_reg (int reg);

    public class Rtc : Object {

        private static int bcd_to_bin (int v) {
            return ((v >> 4) & 0x0f) * 10 + (v & 0x0f);
        }

        // Returns packed UTC timestamp:
        // ((year - 2000) << 26) | (month << 22) | (day << 17) | (hour << 12) | (min << 6) | sec
        public static int read_packed () {
            for (int spin = 0; spin < 10000; spin++) {
                if ((__rtc_read_reg (0x0A) & 0x80) == 0)
                    break;
            }
            int sec = __rtc_read_reg (0x00);
            int min = __rtc_read_reg (0x02);
            int hr  = __rtc_read_reg (0x04);
            int day = __rtc_read_reg (0x07);
            int mon = __rtc_read_reg (0x08);
            int yr  = __rtc_read_reg (0x09);
            int stB = __rtc_read_reg (0x0B);

            if ((stB & 0x04) == 0) {
                sec = bcd_to_bin (sec);
                min = bcd_to_bin (min);
                hr  = bcd_to_bin (hr & 0x7f) | (hr & 0x80);
                day = bcd_to_bin (day);
                mon = bcd_to_bin (mon);
                yr  = bcd_to_bin (yr);
            }
            if ((stB & 0x02) == 0 && (hr & 0x80) != 0) {
                hr = ((hr & 0x7f) + 12) % 24;
            }
            return ((yr & 0x3f) << 26)
                 | ((mon & 0x0f) << 22)
                 | ((day & 0x1f) << 17)
                 | ((hr & 0x1f) << 12)
                 | ((min & 0x3f) << 6)
                 | (sec & 0x3f);
        }
    }
}
