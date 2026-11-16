class SharedSum {
    public int total;
    public Mutex mu;

    public SharedSum () {
        this.total = 0;
        this.mu = new Mutex ();
    }

    public void add (int x) {
        this.mu.lock ();
        this.total = this.total + x;
        this.mu.unlock ();
    }
}

async void consumer_int (Channel<int> ch) {
    var a = yield ch.recv ();
    var b = yield ch.recv ();
    var c = yield ch.recv ();
    print (@"int:$a,$b,$c\n");
}

async void producer_int (Channel<int> ch) {
    yield;
    ch.send (10);
    yield;
    ch.send (20);
    ch.send (30);
}

async void consumer_str (Channel<string> ch) {
    var s1 = yield ch.recv ();
    var s2 = yield ch.recv ();
    print (@"str:$s1,$s2\n");
}

async void producer_str (Channel<string> ch) {
    ch.send ("hola");
    yield;
    ch.send ("planetos");
    ch.close ();
}

async void worker_par (int id, SharedSum acc, Channel<int> done) {
    yield;
    acc.add (id * 10);
    done.send (1);
}

async void wait_all (Channel<int> done, int count) {
    for (int i = 0; i < count; i++) {
        yield done.recv ();
    }
}

int main () {
    var ch_i = new Channel<int> ();
    consumer_int.begin (ch_i);
    producer_int.begin (ch_i);
    Async.run ();

    var ch_s = new Channel<string> ();
    consumer_str.begin (ch_s);
    producer_str.begin (ch_s);
    Async.run ();

    var acc = new SharedSum ();
    var done = new Channel<int> ();
    worker_par.begin (1, acc, done);
    worker_par.begin (2, acc, done);
    worker_par.begin (3, acc, done);
    worker_par.begin (4, acc, done);
    wait_all.begin (done, 4);
    Async.run_parallel (2);
    print (@"par:$(acc.total)\n");

    return 0;
}
