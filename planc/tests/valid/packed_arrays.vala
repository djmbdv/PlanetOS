// Packed arrays: uint8/int8 at one byte per element and uint16/int16 at two.
// The element width must be the same in every backend and every access shape
// (index, compound assign, ++, `in`, foreach, literal, resize).
void main () {
    var u8 = new uint8[6];
    var i8 = new int8[6];
    var u16 = new uint16[6];
    var i16 = new int16[6];
    for (int i = 0; i < 6; i++) {
        u8[i] = (uint8) (200 + i);
        i8[i] = (int8) (0 - 100 - i);
        u16[i] = (uint16) (50000 + i);
        i16[i] = (int16) (0 - 30000 - i);
    }
    // Neighbours must not overlap: writing one element cannot disturb the next.
    u8[0] = 1;
    i8[0] = -1;
    u16[0] = 1;
    i16[0] = -1;
    int u8_5 = u8[5];
    int i8_5 = i8[5];
    int u16_5 = u16[5];
    int i16_5 = i16[5];
    int u8_1 = u8[1];
    print (@"u8=$u8_1,$u8_5 i8=$i8_5 u16=$u16_5 i16=$i16_5\n");

    // Compound assignment and increment keep the element width.
    u8[1] += 10;
    u8[1] += 10;
    i8[1] -= 3;
    u16[1] += 300;
    i16[1] -= 300;
    u8[2]++;
    i16[2]--;
    int u8_1b = u8[1];
    int i8_1b = i8[1];
    int u16_1b = u16[1];
    int i16_1b = i16[1];
    int u8_2 = u8[2];
    int i16_2 = i16[2];
    print (@"acc=$u8_1b,$i8_1b,$u16_1b,$i16_1b inc=$u8_2,$i16_2\n");

    // `in`, foreach and literals see the same elements.
    bool has_three = 221 in u8;
    bool has_big = 50005 in u16;
    int f8 = 0;
    foreach (var v in u8) {
        f8 += v;
    }
    int f16 = 0;
    foreach (var w in u16) {
        f16 += w;
    }
    var lit8 = new uint8[] { 1, 2, 3, 250 };
    var lit16 = new uint16[] { 1000, 2000, 60000 };
    int l8 = lit8[3];
    int l16 = lit16[2];
    print (@"in=$has_three,$has_big foreach=$f8,$f16 lit=$l8,$l16\n");

    // resized arrays keep the packed layout.
    u8.resize (10);
    u8[9] = 42;
    i16.resize (10);
    i16[9] = -4242;
    int r8 = u8[9];
    int r16 = i16[9];
    int n8 = u8.length;
    print (@"resize=$n8,$r8,$r16\n");
}
