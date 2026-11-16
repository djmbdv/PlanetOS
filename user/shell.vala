// PlanetOS interactive userland shell (compiled with --target=planetos --image-base=0xA00000).

namespace UserShell {

    [AsmBody(@"
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        mov %rcx, %rdx
        int $0x80
        ret
    ")]
    public extern int sys (int num, int a0, int a1, int a2);

    [AsmBody(@"
        mov %sil, (%rdi)
        ret
    ")]
    public extern void poke8 (int addr, int val);

    [AsmBody(@"
        movzbl (%rdi), %eax
        ret
    ")]
    public extern int peek8 (int addr);

    private bool buf_eq (int buf, int len, string s) {
        if (len != s.length)
            return false;
        for (int i = 0; i < len; i++) {
            if (peek8 (buf + i) != (int) s[i])
                return false;
        }
        return true;
    }

    private void write_char (int scratch, int ch) {
        poke8 (scratch, ch);
        sys (1, scratch, 1, 0);
    }

    int main () {
        int page = sys (3, 0, 0, 0); // 4 KiB scratch page
        int line_buf = page;
        int io_buf = page + 512;
        int ch_buf = page + 500;

        // Show presentation banner on startup if banner.elf is present
        poke8 (ch_buf + 0, 'b'); poke8 (ch_buf + 1, 'a'); poke8 (ch_buf + 2, 'n');
        poke8 (ch_buf + 3, 'n'); poke8 (ch_buf + 4, 'e'); poke8 (ch_buf + 5, 'r');
        poke8 (ch_buf + 6, '.'); poke8 (ch_buf + 7, 'e'); poke8 (ch_buf + 8, 'l');
        poke8 (ch_buf + 9, 'f'); poke8 (ch_buf + 10, 0);
        sys (13, ch_buf, 10, 0);

        print ("PlanetOS Shell v0.1 (type 'help')\n");

        while (true) {
            print ("planet> ");
            int len = 0;
            while (true) {
                int ch = sys (5, 0, 0, 0);
                if (ch < 0) {
                    sys (10, 0, 0, 0);
                    continue;
                }
                if (ch == '\r' || ch == '\n') {
                    write_char (ch_buf, '\n');
                    break;
                }
                if (ch == 8 || ch == 127) {
                    if (len > 0) {
                        // Pop UTF-8 continuation bytes (0x80..0xBF) + leading byte
                        while (len > 0 && (peek8 (line_buf + len - 1) & 0xC0) == 0x80)
                            len = len - 1;
                        if (len > 0)
                            len = len - 1;
                        write_char (ch_buf, 8);
                        write_char (ch_buf, ' ');
                        write_char (ch_buf, 8);
                    }
                    continue;
                }
                if (len < 250) {
                    poke8 (line_buf + len, ch);
                    len = len + 1;
                    write_char (ch_buf, ch);
                }
            }

            // Trim leading/trailing spaces
            int start = 0;
            while (start < len && peek8 (line_buf + start) == ' ')
                start = start + 1;
            int end = len;
            while (end > start && peek8 (line_buf + end - 1) == ' ')
                end = end - 1;
            if (start == end)
                continue;

            // Split first word (cmd) and rest (arg)
            int sp = start;
            while (sp < end && peek8 (line_buf + sp) != ' ')
                sp = sp + 1;
            int cmd_ptr = line_buf + start;
            int cmd_len = sp - start;

            int arg_start = sp;
            while (arg_start < end && peek8 (line_buf + arg_start) == ' ')
                arg_start = arg_start + 1;
            int arg_ptr = line_buf + arg_start;
            int arg_len = end - arg_start;

            if (buf_eq (cmd_ptr, cmd_len, "help")) {
                print ("commands: help, banner, ls, cat <file>, write <file> <text>, exec <file>, ticks, mem, exit\n");
            } else if (buf_eq (cmd_ptr, cmd_len, "banner")) {
                poke8 (ch_buf + 0, 'b'); poke8 (ch_buf + 1, 'a'); poke8 (ch_buf + 2, 'n');
                poke8 (ch_buf + 3, 'n'); poke8 (ch_buf + 4, 'e'); poke8 (ch_buf + 5, 'r');
                poke8 (ch_buf + 6, '.'); poke8 (ch_buf + 7, 'e'); poke8 (ch_buf + 8, 'l');
                poke8 (ch_buf + 9, 'f'); poke8 (ch_buf + 10, 0);
                sys (13, ch_buf, 10, 0);
            } else if (buf_eq (cmd_ptr, cmd_len, "write")) {
                if (arg_len == 0) {
                    print ("usage: write <file> <text>\n");
                } else {
                    int sp2 = arg_start;
                    while (sp2 < end && peek8 (line_buf + sp2) != ' ')
                        sp2 = sp2 + 1;
                    int fn_len = sp2 - arg_start;
                    int txt_start = sp2;
                    while (txt_start < end && peek8 (line_buf + txt_start) == ' ')
                        txt_start = txt_start + 1;
                    int txt_len = end - txt_start;
                    int fd = sys (14, arg_ptr, fn_len, 0);
                    if (fd < 0) {
                        print ("write: failed\n");
                    } else {
                        if (txt_len > 0)
                            sys (15, fd, line_buf + txt_start, txt_len);
                        poke8 (ch_buf, '\n');
                        sys (15, fd, ch_buf, 1);
                        sys (8, fd, 0, 0);
                    }
                }
            } else if (buf_eq (cmd_ptr, cmd_len, "ls")) {
                int n = sys (12, io_buf, 3584, 0);
                if (n > 0)
                    sys (1, io_buf, n, 0);
            } else if (buf_eq (cmd_ptr, cmd_len, "cat")) {
                if (arg_len == 0) {
                    print ("usage: cat <file>\n");
                } else {
                    int fd = sys (6, arg_ptr, arg_len, 0);
                    if (fd < 0) {
                        print ("cat: not found\n");
                    } else {
                        while (true) {
                            int nr = sys (7, fd, io_buf, 3584);
                            if (nr <= 0)
                                break;
                            sys (1, io_buf, nr, 0);
                        }
                        sys (8, fd, 0, 0);
                    }
                }
            } else if (buf_eq (cmd_ptr, cmd_len, "exec")) {
                if (arg_len == 0) {
                    print ("usage: exec <file> [args...]\n");
                } else {
                    int sp2 = arg_start;
                    while (sp2 < end && peek8 (line_buf + sp2) != ' ')
                        sp2 = sp2 + 1;
                    int fn_len = sp2 - arg_start;
                    poke8 (line_buf + end, 0);
                    int code = sys (13, arg_ptr, fn_len, arg_ptr);
                    print (@"exec: exit=$code\n");
                }
            } else if (buf_eq (cmd_ptr, cmd_len, "ticks")) {
                int t = sys (2, 0, 0, 0);
                print (@"ticks: $t\n");
            } else if (buf_eq (cmd_ptr, cmd_len, "mem")) {
                int p = sys (3, 0, 0, 0);
                sys (4, p, 0, 0);
                print (@"mem: page=$p\n");
            } else if (buf_eq (cmd_ptr, cmd_len, "exit")) {
                break;
            } else {
                print ("unknown command\n");
            }
        }

        sys (4, page, 0, 0);
        return 0;
    }
}
