errordomain MathError {
    DIV_ZERO,
    OVERFLOW
}

errordomain IoError {
    NOT_FOUND,
    DENIED
}

int safe_div(int a, int b) throws MathError {
    if (b == 0) {
        throw new MathError.DIV_ZERO("div by zero");
    }
    if (a > 100) {
        throw new MathError.OVERFLOW(@"too big: $a");
    }
    return a / b;
}

string compute(int a, int b) throws MathError, IoError {
    string prefix = @"res:$a/$b";
    int q = safe_div(a, b);
    if (q == 42) {
        throw new IoError.NOT_FOUND(@"forbidden $q");
    }
    return @"$prefix=$q";
}

int try_return_finally(int a, int b) throws MathError {
    try {
        int q = safe_div(a, b);
        return q + 10;
    } finally {
        print("ret_fin\n");
    }
}

int main() {
    try {
        string s1 = compute(20, 4);
        print(@"$s1\n");
    } catch (MathError e) {
        print(@"m1:$(e.message)\n");
    } catch (IoError e) {
        print(@"i1:$(e.message)\n");
    }

    try {
        string joined = (@"hdr-" + "ok:") + compute(10, 0);
        print(@"$joined\n");
    } catch (MathError e) {
        print(@"m2:$(e.code):$(e.message)\n");
    } catch (IoError e) {
        print(@"i2:$(e.message)\n");
    }

    try {
        compute(84, 2);
    } catch (Error e) {
        if (e is IoError) {
            print(@"generic_io:$(e.message)\n");
        }
    }

    try {
        int r = try_return_finally(15, 3);
        print(@"r=$r\n");
        try_return_finally(15, 0);
    } catch (MathError e) {
        print(@"after_fin:$(e.message)\n");
    } finally {
        print("outer_fin\n");
    }

    try {
        try {
            safe_div(200, 2);
        } catch (MathError e) {
            print(@"inner:$(e.message)\n");
            throw new MathError.OVERFLOW("rethrow");
        } finally {
            print("inner_fin\n");
        }
    } catch (MathError e) {
        print(@"caught_rethrow:$(e.message)\n");
    }

    return 0;
}
