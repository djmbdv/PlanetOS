enum @owned {
    @ref,
    @lock,
    @value
}

struct @sealed {
    public int @in;
    public int @out;
}

delegate int @delegate (int @in, int @out);

class @override {
    public int @base;

    public @override (int @new) {
        this.@base = @new;
    }

    public int @as (int @is) {
        return this.@base + @is;
    }
}

void main () {
    int @in = 10;
    int @out = 20;
    int @lock = 3;
    @lock += @in;
    @out = @lock;

    var st = @sealed () { @in = 7, @out = 8 };
    var c = new @override (5);
    var e = @owned.@value;
    @delegate fn = (@ref, @value) => @ref * @value + @in;
    var s = @"in=$(@in) out=$(@out) st=$(st.@in),$(st.@out) cls=$(c.@as (4)) e=$((int) e) fn=$(fn (3, 4))";
    print (@"$s\n");
}
