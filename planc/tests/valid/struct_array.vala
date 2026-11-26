struct P {
    public int x;
    public int y;
}

struct Outer {
    public P p;
    public int z;
}

void bump (ref P p) {
    p.x += 1;
}

int main () {
    var arr = new P[4];
    for (int i = 0; i < 4; i++) {
        arr[i].x = i;
        arr[i].y = i * 2;
    }
    print (@"len=$(arr.length) e3=$(arr[3].x),$(arr[3].y)\n");

    // Reading an element copies its slots: the local cannot alias the slab.
    P c = arr[1];
    c.x = 100;
    print (@"copy=$(c.x),$(c.y) src=$(arr[1].x),$(arr[1].y)\n");

    // The loop variable of a struct array is a copy too.
    int sum = 0;
    foreach (var p in arr) {
        sum += p.x + p.y;
        p.x = -1;
    }
    print (@"sum=$sum untouched=$(arr[2].x)\n");

    // An element is a real lvalue: `ref` reaches the slab.
    bump (ref arr[0]);
    print (@"ref=$(arr[0].x),$(arr[0].y)\n");

    // Whole-element assignment copies both slots.
    P t = P () { x = 7, y = 8 };
    arr[3] = t;
    t.x = 0;
    print (@"assigned=$(arr[3].x),$(arr[3].y) src=$(t.x)\n");

    // A struct whose own stride is not a power of two (3 slots = 24 bytes).
    var os = new Outer[3];
    os[1].p.x = 5;
    os[1].p.y = 6;
    os[1].z = 7;
    os[2].p.x = 9;
    print (@"nested=$(os[1].p.x),$(os[1].p.y),$(os[1].z),$(os[2].p.x),$(os[2].z)\n");
    return 0;
}
