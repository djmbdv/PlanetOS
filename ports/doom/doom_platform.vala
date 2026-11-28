// PlanetOS backend for doomgeneric: the equivalent of doomgeneric_<platform>.c.
//
// Frames are presented by wrapping DG_ScreenBuffer with Cairo's ImageSurface
// (zero copy), and the zone allocator maps to planc arrays, which are already
// refcounted. Sound, music and wipes are stubbed: the port builds with
// -D PLANETOS_NOSOUND and runs without them.
using GLib;
using Planet;
using Gdk;

private Window? _doom_win = null;
private int _doom_src_addr = 0;
private uint32[]? _doom_pal = null;
private int _doom_pal_addr = 0;
private int _doom_t0 = 0;
private int _last_present_tick = -10;
private uint8 _held_key = 0;
private int _held_deadline_ms = 0;

public void DG_Init () {
    _doom_t0 = Sys.ticks () * 10;
    _doom_win = Display.open_window (640, 400);
    if (_doom_win == null) {
        print ("[doom] failed to open window\n");
        return;
    }
    var win = (!) _doom_win;
    if (!win.is_valid () || win.surface.buf_addr == 0) {
        print ("[doom] invalid window surface\n");
        _doom_win = null;
        return;
    }
    if (DG_ScreenBuffer == null || DG_ScreenBuffer.length < 640 * 400) {
        print ("[doom] invalid screen buffer\n");
        return;
    }
    // planc arrays keep their elements at +16.
    _doom_src_addr = (int) (uintptr.from_pointer ((void*) DG_ScreenBuffer) + (uintptr) 16);
    _doom_pal = new uint32[256];
    _doom_pal_addr = (int) (uintptr.from_pointer ((void*) _doom_pal) + (uintptr) 16);
}

public int _doom_frames = 0;

public void DG_DrawFrame () {
    _doom_frames++;
    if (_doom_frames % 25 == 0)
        print (@"[doom] frame $(_doom_frames) tic=$(gametic) free=$((int) (Sys.free_pages ()))\n");
    if (_doom_win == null || _doom_src_addr == 0)
        return;
    ((!) _doom_win).present_argb32 (_doom_src_addr, 640, 400);
}

public void DG_FinishUpdate () {
    int now_tick = Sys.ticks ();
    if (now_tick - _last_present_tick < 2 && _doom_frames > 0) {
        return;
    }
    _last_present_tick = now_tick;
    _doom_frames++;
    if (_doom_frames % 25 == 0)
        print (@"[doom] frame $(_doom_frames) tic=$(gametic) free=$((int) (Sys.free_pages ()))\n");
    if (_doom_win == null || _doom_pal == null || I_VideoBuffer == null || DG_ScreenBuffer == null)
        return;
    var pal = (!) _doom_pal;
    for (int i = 0; i < 256; i++) {
        var c = colors[i];
        pal[i] = ((uint32) 0xFF << 24) | (c.r << 16) | (c.g << 8) | c.b;
    }
    var src = I_VideoBuffer;
    var dst = DG_ScreenBuffer;
    for (int y = 0; y < 200; y++) {
        int sr = y * 320;
        int dr0 = y * 1280;
        int dr1 = dr0 + 640;
        for (int x = 0; x < 320; x++) {
            uint32 col = pal[src[sr + x]];
            int dx = x << 1;
            dst[dr0 + dx] = col;
            dst[dr0 + dx + 1] = col;
            dst[dr1 + dx] = col;
            dst[dr1 + dx + 1] = col;
        }
    }
    ((!) _doom_win).present_argb32 (_doom_src_addr, 640, 400);
}

public void DG_SleepMs (uint32 ms) {
    Sys.sleep_ms ((int) ms);
}

public uint32 DG_GetTicksMs () {
    return (uint32) (Sys.ticks () * 10 - _doom_t0);
}

private uint8 map_doom_key (uint kv) {
    if (kv == 0xFF53 || kv == 0x1B5B43 || kv == 0x84) return 0xae; // Right
    if (kv == 0xFF51 || kv == 0x1B5B44 || kv == 0x83) return 0xac; // Left
    if (kv == 0xFF52 || kv == 0x1B5B41 || kv == 0x81) return 0xad; // Up
    if (kv == 0xFF54 || kv == 0x1B5B42 || kv == 0x82) return 0xaf; // Down
    if (kv == 0xFF0D || kv == '\n' || kv == '\r') return 13; // Enter
    if (kv == 0xFF1B || kv == 27) return 27; // Esc
    if (kv == 0xFF09 || kv == '\t') return 9; // Tab
    if (kv == ' ') return 0xa2; // Use
    if (kv == 0xFFE3 || kv == 0xFFE4 || kv == 'f' || kv == 'F') return 0xa3; // Ctrl / F -> Fire
    if (kv == 0xFFE1 || kv == 0xFFE2) return 0xb6; // Shift -> Run
    return (uint8) (kv & 0xFF);
}

public int DG_GetKey (int[] pressed, uint8[] key) {
    if (_doom_win == null)
        return 0;
    var win = (!) _doom_win;
    while (true) {
        var ev = win.poll_event ();
        if (ev.type == EventType.NONE)
            break;
        if (ev.type == EventType.KEY_PRESS) {
            uint8 k = map_doom_key (ev.keyval);
            _held_key = k;
            _held_deadline_ms = (int) DG_GetTicksMs () + 120;
            pressed[0] = 1;
            key[0] = k;
            return 1;
        }
    }
    if (_held_key != 0 && (int) DG_GetTicksMs () >= _held_deadline_ms) {
        pressed[0] = 0;
        key[0] = _held_key;
        _held_key = 0;
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
    // A mistyped IWAD name used to end inside the WAD lookup, which faults the
    // machine; answer before the engine starts instead.
    string iwad = "/freedoom1.wad";
    for (int i = 1; i + 1 < myargv.length; i++) {
        if (myargv[i] == "-iwad")
            iwad = myargv[i + 1];
    }
    if (FileStream.open (iwad, "rb") == null) {
        print (@"[doom] cannot open IWAD '$iwad'\n");
        print ("[doom] usage: doom.elf -iwad /freedoom1.wad\n");
        return 1;
    }
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
