// PlanetOS backend for doomgeneric: the equivalent of doomgeneric_<platform>.c.
//
// Frames are presented by wrapping DG_ScreenBuffer with Cairo's ImageSurface
// (zero copy), and the zone allocator maps to planc arrays, which are already
// refcounted. Sound, music and wipes are stubbed: the port builds with
// -D PLANETOS_NOSOUND and runs without them.
using GLib;
using Cairo;
using Gdk;

private Window? _doom_win = null;
private Context? _doom_cr = null;
private ImageSurface? _doom_surf = null;
private int _doom_t0 = 0;

public void DG_Init () {
    _doom_t0 = Sys.ticks () * 10;
    _doom_win = Display.open_window (640, 400);
    if (_doom_win != null) {
        _doom_cr = ((!) _doom_win).create_cairo_context ();
        // Wrap the frame buffer the game already owns: presenting then needs no
        // 1 MB copy per frame. planc arrays keep their elements at +16.
        int addr = (int) (uintptr.from_pointer ((void*) DG_ScreenBuffer) + (uintptr) 16);
        _doom_surf = new ImageSurface.wrap (addr, 640, 400);
    }
}

public int _doom_frames = 0;

public void DG_DrawFrame () {
    _doom_frames++;
    if (_doom_frames % 25 == 0)
        print (@"[doom] frame $(_doom_frames) tic=$(gametic) free=$((int) (Sys.free_pages ()))\n");
    if (_doom_win == null || _doom_cr == null || _doom_surf == null)
        return;
    var surf = (!) _doom_surf;
    var cr = (!) _doom_cr;
    var win = (!) _doom_win;
    cr.blit_surface (surf, 0, 0, 640, 400);
    win.present ();
}

public void DG_SleepMs (uint32 ms) {
    Sys.sleep_ms ((int) ms);
}

public uint32 DG_GetTicksMs () {
    return (uint32) (Sys.ticks () * 10 - _doom_t0);
}

private uint8 map_doom_key (uint kv) {
    if (kv == 0xFF53 || kv == 0x1B5B43) return 0xae; // Right
    if (kv == 0xFF51 || kv == 0x1B5B44) return 0xac; // Left
    if (kv == 0xFF52 || kv == 0x1B5B41) return 0xad; // Up
    if (kv == 0xFF54 || kv == 0x1B5B42) return 0xaf; // Down
    if (kv == 0xFF0D || kv == '\n' || kv == '\r') return 13; // Enter
    if (kv == 0xFF1B || kv == 27) return 27; // Esc
    if (kv == 0xFF09 || kv == '\t') return 9; // Tab
    if (kv == ' ') return 0xa2; // Use
    if (kv == 0xFFE3 || kv == 0xFFE4) return 0xa3; // Ctrl -> Fire
    if (kv == 0xFFE1 || kv == 0xFFE2) return 0xb6; // Shift -> Run
    return (uint8) (kv & 0xFF);
}

public int DG_GetKey (int[] pressed, uint8[] key) {
    if (_doom_win == null)
        return 0;
    var ev = ((!) _doom_win).poll_event ();
    if (ev.type == EventType.KEY_PRESS) {
        pressed[0] = 1;
        key[0] = map_doom_key (ev.keyval);
        return 1;
    }
    return 0;
}

public void DG_SetWindowTitle (uint8[]? title) {
}

public void I_InitJoystick () {}
public void I_InitSound (uint32 use_sfx) {}
public void I_InitMusic () {}

// Lump names are eight bytes, NUL padded and case-insensitive. GLib's
// ascii_strncasecmp takes (string) casts that lose the byte view.
public int c_lump_eq (uint8[] a, uint8[] b) {
    for (int i = 0; i < 8; i++) {
        uint8 ca = (i < a.length) ? a[i] : 0;
        uint8 cb = (i < b.length) ? b[i] : 0;
        if (ca >= 'a' && ca <= 'z') ca -= 32;
        if (cb >= 'a' && cb <= 'z') cb -= 32;
        if (ca != cb) return 0;
        if (ca == 0) return 1;
    }
    return 1;
}

// The zone allocator becomes plain planc arrays: Z_Free is a no-op because the
// runtime frees by refcount, and W_CacheLumpNum keeps its own cache.
public int mem_free () { return Sys.free_pages (); }
public void Z_Init () {}
public void Z_Free (uint8[]? ptr) {}
public int z_total = 0;
public int z_mb = 0;
public uint8[] Z_Malloc (int size, int tag, uint8[]? user) {
    int n = size > 0 ? size : 1;
    z_total += n;
    if (z_total / 1048576 != z_mb) {
        z_mb = z_total / 1048576;
        print (@"[doom] zone $z_mb MB\n");
    }
    return new uint8[n];
}
public void Z_FreeTags (int lowtag, int hightag) {}
public void Z_DumpHeap (int lowtag, int hightag) {}
public void Z_FileDumpHeap (FileStream? f) {}
public void Z_CheckHeap () {}
public void Z_ChangeTag2 (uint8[]? ptr, int tag, uint8[]? file, int line) {}
public void Z_ChangeUser (uint8[]? ptr, _c2v_abox_uint8? user) {}
public int Z_FreeMemory () { return 64 * 1024 * 1024; }
public int wipe_StartScreen (int x, int y, int w, int h) { return 0; }
public int wipe_EndScreen (int x, int y, int w, int h) { return 0; }
public int wipe_ScreenWipe (int wipeno, int x, int y, int w, int h, int ticks) { return 1; }

public void c_memcpy_i32 (int[] dst, int[] src, size_t n) {
    int cnt = (int) n / 4;
    for (int i = 0; i < cnt && i < dst.length && i < src.length; i++) dst[i] = src[i];
}
public void c_memcpy_u32 (uint32[] dst, uint32[] src, size_t n) {
    int cnt = (int) n / 4;
    for (int i = 0; i < cnt && i < dst.length && i < src.length; i++) dst[i] = src[i];
}

public int main (string[] args) {
    c2vala_init_globals ();
    if (args.length <= 1) {
        myargv = new string[] { "doom", "-iwad", "/freedoom1.wad" };
    } else {
        myargv = args;
    }
    myargc = myargv.length;
    print ("[doom] init\n");
    M_FindResponseFile ();
    DG_ScreenBuffer = new uint32[640 * 400];
    DG_Init ();
    D_DoomMain ();
    print ("[doom] loop\n");
    while (true) {
        doomgeneric_Tick ();
    }
    return 0;
}
