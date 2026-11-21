struct Pack {
    public uint8 a;
    public uint16 b;
    public uint32 c;
    public uint64 d;
}

static uint32 wrap_u32 (uint32 x) {
    return x;
}

void main () {
    uint8 u8 = 250;
    u8 += 10;
    u8--;
    uint8 u8z = 0;
    u8z--;
    uint16 u16 = 65535;
    u16++;
    int8 s8 = (int8) 255;
    int16 s16 = (int16) 65535;
    int32 s32 = (int32) 0xFFFFFFFFu;
    uint u = 4000000000u;
    short sh = -30000;
    ushort ush = 65000;
    uchar uc = 255;
    unichar ch = 0x1F680u;
    uint32 u32ch = (uint32) ch;
    print (@"w=$u8,$u8z,$u16,$s8,$s16,$s32,$u,$sh,$ush,$((uint) uc),$u32ch\n");

    uint32 h = 216613626u;
    h = (h ^ 97u) * 16777619u;
    uint32 u32neg = 1u;
    u32neg = -u32neg;
    uint32 sh32 = 0x80000000u >> 31;
    uint32 d32 = 4000000000u / 3u;
    uint32 m32 = 4000000000u % 7u;
    uint32 w32 = wrap_u32 ((uint32) 0x100000005UL);
    print (@"u32=$h,$u32neg,$sh32,$d32,$m32,$w32\n");

    uint64 u64max = uint64.MAX;
    uint64 sh64 = u64max >> 60;
    uint64 a64 = 18446744073709551610UL;
    uint64 d64 = a64 / 3UL;
    uint64 m64 = a64 % 7UL;
    uint64 one64 = 1;
    uint64 n64 = -one64;
    uint64 div_big = 18446744073709551615UL;
    div_big /= 5UL;
    size_t sz = size_t.MAX;
    ssize_t ssz = ssize_t.MAX;
    print (@"u64=$(u64max.to_string ()),$(sh64.to_string ()),$(d64.to_string ()),$(m64.to_string ()),$(n64.to_string ()),$(div_big.to_string ()),$(sz.to_string ()),$(ssz.to_string ())\n");

    int64 neg_one = -1;
    bool c1 = ((uint64) neg_one > 100UL);
    bool c2 = (100UL < (uint64) neg_one);
    bool c3 = (neg_one < 100);
    bool c4 = (4000000000u > 1u);
    bool c5 = (0u <= 4000000000u);
    print (@"cmp=$c1,$c2,$c3,$c4,$c5\n");

    uint64 lit = 18446744073709551615UL - 5UL;
    uint64 fold_shr = 0xFFFFFFFFFFFFFFFFUL >> 56;
    uint32 fold_u32 = 1u - 2u;
    print (@"tpl=$lit,$fold_shr,$fold_u32\n");

    var p = Pack () { a = (uint8) 257, b = (uint16) 70000, c = 1u - 2u, d = uint64.MAX };
    print (@"pack=$(p.a),$(p.b),$(p.c),$(p.d.to_string ())\n");

    print (@"lim=$(int8.MIN),$(int8.MAX),$(short.MIN),$(short.MAX),$(ushort.MAX),$(uint.MAX),$(int32.MIN),$(int32.MAX),$(uint32.MAX),$(int64.MAX.to_string ()),$(uint64.MAX.to_string ())\n");
}
