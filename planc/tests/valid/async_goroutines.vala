errordomain AsyncErr {
    BOOM
}

class Worker {
    public int base_val;

    public Worker (int b) {
        this.base_val = b;
    }

    public async int compute (int x) {
        yield;
        return this.base_val + x;
    }
}

async void ping (string tag) {
    print (tag + ":1\n");
    yield;
    print (tag + ":2\n");
}

async int add_async (int a, int b) {
    yield;
    return a + b;
}

async double half_async (double x) {
    yield;
    return x / 2.0;
}

async int loop_yield_sum (int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        if (i == 2) {
            yield;
            continue;
        }
        sum = sum + i;
        yield;
    }
    return sum;
}

async int may_fail (bool fail) throws AsyncErr {
    yield;
    if (fail)
        throw new AsyncErr.BOOM ("boom");
    return 77;
}

async void driver () {
    var a = add_async (10, 20);
    var b = add_async (3, 4);
    var ra = yield a;
    var rb = yield b;
    print (@"$(ra + rb)\n");

    var d = yield half_async (9.0);
    print (@"$d\n");

    var ls = yield loop_yield_sum (5);
    print (@"$ls\n");

    var w = new Worker (100);
    var wr = yield w.compute.begin (23);
    print (@"$wr\n");

    try {
        var bad = yield may_fail (true);
        print (@"$bad\n");
    } catch (AsyncErr e) {
        print ("caught:" + e.message + "\n");
    }
    try {
        var ok = yield may_fail (false);
        print (@"$ok\n");
    } catch (AsyncErr e) {
        print ("unexpected\n");
    }
}

async int par_work (int x) {
    yield;
    return x * x;
}

async void par_check (int x, int expected) {
    var r = yield par_work (x);
    if (r != expected)
        print ("MISMATCH");
}

int main () {
    ping.begin ("A");
    ping.begin ("B");
    Async.run ();

    driver.begin ();
    Async.run ();

    par_check.begin (3, 9);
    par_check.begin (4, 16);
    par_check.begin (5, 25);
    par_check.begin (6, 36);
    Async.run_parallel (2);
    print ("parallel:ok\n");
    return 0;
}
