int add_bytes(uint8 a, unowned string tag) {
    return a + tag.length;
}

int main() {
    owned string base_s = "Hello" + "_Planet";
    string prefix = base_s[0:5];
    string middle = base_s[6:12];
    string empty_slice = base_s[2:2];
    string full = base_s[0:base_s.length];

    uint64 hex_v = 0x10_20;
    uint32 bin_v = 0b1010_0101u;
    int32 mask = 0xFFL;
    char ch_a = 'A';
    char ch_nl = '\n';
    char ch_q = '\'';
    char ch_bs = '\\';
    uint16 small = 7;
    size_t sz = ch_a + add_bytes(3, prefix);

    int sum = small + bin_v + (mask & hex_v) + ch_nl + ch_q + ch_bs;
    print(@"$(prefix)|$(middle)|$(empty_slice)|$(full)|$(empty_slice.length)|$(sz)|$(sum)\n");
    return (ch_a - 'A') + prefix.length + middle.length;
}
