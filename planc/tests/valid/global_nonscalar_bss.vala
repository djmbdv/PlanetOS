struct Pair {
    public int x;
    public int y;
}

class Box : Object {
    public int v;
    public Box (int v) { this.v = v; }
}

uint8[] bss_buf = new uint8[256];
int[] g_arr = { 10, 20, 30 };
Box g_box = new Box (77);
Pair g_pair = Pair () { x = 3, y = 4 };

int main () {
    bss_buf[0] = 5;
    bss_buf[255] = 9;
    int sum = (int) bss_buf[0] + (int) bss_buf[255] + g_arr[0] + g_arr[2] + g_box.v + g_pair.x + g_pair.y;
    print (@"$(bss_buf.length) $sum\n");
    return 0;
}
