int main() {
    uint8[] buf = new uint8[4];
    buf[0] = 200;
    buf[1] = 250;
    buf[2] = 10;
    buf[3] = 255;
    buf[3]++;
    int pre = ++buf[2];
    int post = buf[0]--;
    print(@"u8=$(buf[0]):$(buf[1]):$(buf[2]):$(buf[3]) pre=$pre post=$post\n");

    uint8[] lit = new uint8[] { 0x7f, (uint8) 'E', (uint8) 'L', (uint8) 'F' };
    int sum = 0;
    foreach (uint8 b in lit) {
        sum += b;
    }
    print(@"lit.len=$(lit.length) sum=$sum\n");

    int8[] sig = new int8[] { -5, 120, -128 };
    int ssum = 0;
    foreach (int y in sig) {
        ssum += y;
    }
    print(@"sig=$(sig[0]):$(sig[1]):$(sig[2]) ssum=$ssum\n");

    int x = 3;
    x *= 4;
    x /= 2;
    x %= 4;
    x |= 8;
    x &= 10;
    x ^= 1;
    x <<= 2;
    x >>= 1;
    print(@"ops=$x\n");

    int lo = int32.MIN;
    int hi = int32.MAX;
    int parsed = (int) int64.parse("-12345");
    string num_str = parsed.to_string();
    print(@"bounds=$lo:$hi parsed=$num_str\n");

    string msg = "hello-planetos";
    bool hp = msg.has_prefix("hello");
    bool hs = msg.has_suffix("os");
    string sub1 = msg.substring(6);
    string sub2 = msg.substring(0, 5);
    print(@"str=$hp:$hs:$sub2:$sub1\n");
    return 0;
}
