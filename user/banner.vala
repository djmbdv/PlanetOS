// PlanetOS neofetch-style presentation banner (compiled with --target=planetos).

namespace UserBanner {

    [AsmBody(@"
        mov %rdi, %rax
        mov %rsi, %rdi
        mov %rdx, %rsi
        mov %rcx, %rdx
        int $0x80
        ret
    ")]
    public extern int sys (int num, int a0, int a1, int a2);

    int main () {
        int ticks = sys (2, 0, 0, 0);
        string c = "\x1b[96m";
        string y = "\x1b[93m";
        string w = "\x1b[97m";
        string d = "\x1b[90m";
        string r = "\x1b[0m";

        print ("\n");
        print (@"$(c)       .---.   $(y)/        $(w)PlanetOS$(r) $(c)v0.1$(r) $(d)(x86-64 Long Mode)$(r)\n");
        print (@"$(c)    .-'     '-.$(y)/         $(d)----------------------------------------$(r)\n");
        print (@"$(c)   /   $(w).---.$(c)   \\         $(w)Compiler$(r) : $(c)planc$(r) (self-hosted Vala)$(r)\n");
        print (@"$(c)  |   $(w)/  $(y)o$(w)  \\$(c)   |$(y)_       $(w)Runtime$(r)  : $(c)planetrt$(r) + int 0x80 ABI$(r)\n");
        print (@"$(c)  |  $(w)|  $(y)(O)$(w)  |$(c)  |$(y))      $(w)Storage$(r)  : XFS (ATA PIO) + RAMFS$(r)\n");
        print (@"$(c)   \\  $(w)\\  $(y)o$(w)  /$(c)  /$(y)'       $(w)Console$(r)  : VGA 80x25 + COM1 (UTF-8)$(r)\n");
        print (@"$(c)    '-.$(w)'---'$(c).-'         $(w)Memory$(r)   : 4 KiB PMM  $(d)|$(r)  ticks: $(y)$ticks$(r)\n");
        print (@"$(y)   /   $(c)'---'             $(d)planc • planetrt • XFS • QEMU$(r)\n");
        print ("\n");
        return 0;
    }
}
