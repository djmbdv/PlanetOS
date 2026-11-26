// `(fmt).printf (args)`: literal formats are parsed at compile time, so the
// conversions, the flags and the argument types are all checked.
void main () {
    print (("plain").printf () + "\n");
    print (("d=%d i=%i").printf (-42, 7) + "\n");
    print (("u=%u x=%x X=%X p=%p").printf (42, 255, 255, 4096) + "\n");
    print (("s=%s c=%c pct=%%").printf ("hi", 65) + "\n");
    print (("f=%f g=%g").printf (3.5, 2.5) + "\n");
    print (("[%.3d][%05d][%06d][%-6d][%8s][%-3s]").printf (33, 42, -42, 7, "ab", "cd") + "\n");
    print (("[%08x][%4x][%.2x]").printf (48879, 255, 5) + "\n");
    print (("len=%lld short=%hd big=%zu").printf (1234567890123, 9, 42) + "\n");
    print (("empty=[%s]").printf ("") + "\n");

    // The result is a normal string: assignable, concatenable, reusable.
    int v = -7;
    string s = ("v=%d").printf (v);
    print (s + "!\n");
    print (("%s/%s").printf (s, "x") + "\n");

    // enum arguments use their numeric value
    print (("dir=%d").printf (Direction.EAST) + "\n");
}

enum Direction {
    NORTH,
    EAST
}
