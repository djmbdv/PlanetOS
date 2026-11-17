// PlanetOS neofetch-style presentation banner (compiled with --target=planetos).

using Planet;

namespace UserBanner {

    int main () {
        int ticks = Sys.ticks ();
        int gcaps = Sys.gpu_info ();
        string gpu_str = "VGA 80x25 + COM1 (UTF-8)";
        if ((gcaps & 16) != 0)
            gpu_str = "VirtIO-GPU Venus (1280x720)";
        else if ((gcaps & 2) != 0)
            gpu_str = "VirtIO-GPU 3D/VirGL (1280x720)";
        else if ((gcaps & 1) != 0)
            gpu_str = "VirtIO-GPU 2D (1280x720)";

        string c = "\x1b[96m";
        string b = "\x1b[94m";
        string g = "\x1b[92m";
        string w = "\x1b[97m";
        string d = "\x1b[90m";
        string r = "\x1b[0m";

        print ("\n");
        print (@"$(b)          .-----.           $(w)PlanetOS$(r) $(c)v0.1$(r) $(d)(x86-64 Long Mode)$(r)\n");
        print (@"$(b)       .-'       '-.   $(c)/    $(d)--------------------------------------$(r)\n");
        print (@"$(b)      /   $(w).-----.$(b)   \\ $(c)/     $(w)Compiler$(r) : $(c)planc$(r) (self-hosted Vala)\n");
        print (@"$(b)     |   $(w)/  $(c).-.$(w)  \\$(b)   |      $(w)Runtime$(r)  : $(c)planetrt$(r) + Ring 3 CR3\n");
        print (@"$(b)     |  $(w)|   $(c)(O)$(w)   |$(b)  |      $(w)Graphics$(r) : $(g)*$(r) $gpu_str\n");
        print (@"$(b)      \\  $(w)\\  $(c)'-'$(w)  /$(b)  /       $(w)Storage$(r)  : XFS (ATA LBA48) + RAMFS\n");
        print (@"$(b)    $(c)/  $(b)'-.$(w)'-----'$(b).-'        $(w)Memory$(r)   : 4 KiB PMM $(d)|$(r) ticks: $(c)$ticks$(r)\n");
        print (@"$(c)   /      $(b)'-----'           $(d)planc • planetrt • XFS • VirtIO-GPU$(r)\n");
        print ("\n");
        return 0;
    }
}
