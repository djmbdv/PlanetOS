enum Bits {
    A = 1,
    B = 4
}

class Layout : Object {
    public const int BASE = 0x100000;
    public const int SIZE = 0x1000 * 2 + 0x500;
    public const int END = BASE + SIZE;
    public const int MASK = (Bits.A | Bits.B) << 2;
    public const int INV = ~0 & 0xFF;
}

const int GLOBAL_VAL = Layout.END + 16 / 4 - 2;

int main () {
    print (@"$(Layout.END) $(Layout.MASK) $(Layout.INV) $(GLOBAL_VAL)\n");
    return 0;
}
