// A field of the enclosing class shadows a same-named global, inside methods
// and constructors alike: reads, plain writes and indexed writes.
class Box {
    public int[] items;
    public int size;

    public Box() {
        items = new int[3];
        items[2] = 4;
        size = 7;
    }

    public void grow() {
        items = new int[5];
        items[4] = 9;
        size = size + 1;
    }

    public string show() {
        return @"size=$(size) len=$(items.length) last=$(items[items.length - 1])";
    }
}

int[] items = new int[0];
int size = 100;

int main() {
    var b = new Box();
    print(@"$(b.show())\n");
    b.grow();
    print(@"$(b.show()) global size=$(size)\n");
    return 0;
}
