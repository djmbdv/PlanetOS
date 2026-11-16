class Box {
    public int value;
}

class Counter {
    public int count;

    public signal void changed (int v);

    public virtual signal int compute (int x) {
        return x * 2;
    }

    public Counter (int c) {
        this.count = c;
    }

    public void bump (int delta) {
        this.count = this.count + delta;
        changed (this.count);
    }
}

class SubCounter : Counter {
    public SubCounter (int c) : base (c) {
    }
}

int main () {
    var box = new Box () { value = 10 };
    var c = new Counter (0);

    var id1 = c.changed.connect ((sender, v) => {
        print (@"h1:$v:$(box.value)\n");
    });
    var id2 = c.changed.connect ((sender, v) => {
        print (@"h2:$v\n");
    });

    c.bump (5);
    c.changed.disconnect (id1);
    c.bump (3);
    c.changed.disconnect (id2);
    c.bump (1);

    // Default handler + connected handler returning int
    var r1 = c.compute (4);
    print (@"def:$r1\n");
    c.compute.connect ((sender, x) => {
        return x + 100;
    });
    var r2 = c.compute (4);
    print (@"ov:$r2\n");

    // Inherited signal
    var sub = new SubCounter (10);
    sub.changed.connect ((sender, v) => {
        print (@"sub:$v\n");
    });
    sub.bump (7);

    return 0;
}
