// Exercises the kernel/userland integration surface added in this slice:
// errno from failed syscalls, GLib.Dir over SYS_READDIR, g_log into the kernel
// ring, futex-backed Mutex/Cond across a real thread, SYS_POLL readiness and
// SYS_SLEEP_MS. Exits with the number of failed checks.
using GLib;
using Planet;

private int shared_word = 0;
private RecMutex demo_mutex = new RecMutex ();
private Cond demo_cond = new Cond ();

private uint8[]? demo_worker () {
    demo_mutex.@lock ();
    shared_word = 42;
    demo_cond.signal ();
    demo_mutex.unlock ();
    return null;
}

int main (string[] args) {
    int fails = 0;

    // 1. errno survives a failed open (SYS_ERRNO)
    var f = FileStream.open ("/no_such_file", "r");
    int e = Sys.errno_code ();
    if (f == null && e == Sys.ENOENT)
        print ("errno=ok\n");
    else {
        print ("errno=FAIL\n");
        fails++;
    }

    // 2. GLib.Dir reads the root directory
    var d = Dir.open ("/");
    int n = 0;
    if (d != null) {
        string? name = d.read_name ();
        while (name != null) {
            n++;
            name = d.read_name ();
        }
    }
    if (n >= 5)
        print ("dir=ok\n");
    else {
        print ("dir=FAIL\n");
        fails++;
    }

    // 3. g_log reaches the kernel ring
    log_error ("sysdemo", "boom");
    var rec = new uint8[8 * 64];
    int got = Sys.klog_read (rec, 8);
    bool found = false;
    for (int i = 0; i < got; i++) {
        int len = (int) ((uint32) rec[i * 64 + 8] | ((uint32) rec[i * 64 + 9] << 8)
                         | ((uint32) rec[i * 64 + 10] << 16) | ((uint32) rec[i * 64 + 11] << 24));
        var sb = new StringBuilder ();
        for (int k = 0; k < len && k < 40; k++)
            sb.append_c ((char) rec[i * 64 + 24 + k]);
        if (sb.str.contains ("boom"))
            found = true;
    }
    if (found)
        print ("klog=ok\n");
    else {
        print ("klog=FAIL\n");
        fails++;
    }

    // 4. Mutex/Cond park and wake a real thread instead of polling
    var t = new Thread ("demo-worker", demo_worker);
    demo_mutex.@lock ();
    while (shared_word != 42)
        demo_cond.wait (demo_mutex);
    demo_mutex.unlock ();
    t.join ();
    if (shared_word == 42)
        print ("cond=ok\n");
    else {
        print ("cond=FAIL\n");
        fails++;
    }

    // 5. SYS_POLL reports a regular file as readable
    int fd = Sys.open ("/hello.txt");
    var fds = new int[1];
    fds[0] = fd;
    int mask = Sys.poll (fds, 0);
    if (fd >= 3 && (mask & 1) == 1)
        print ("poll=ok\n");
    else {
        print ("poll=FAIL\n");
        fails++;
    }
    if (fd >= 3)
        Sys.close (fd);

    // 6. SYS_SLEEP_MS actually waits for the timer
    int t0 = Sys.ticks ();
    Sys.sleep_ms (40);
    int t1 = Sys.ticks ();
    if (t1 > t0)
        print ("sleep=ok\n");
    else {
        print ("sleep=FAIL\n");
        fails++;
    }

    // 7. SYS_WAIT_ADDR parks the task and the timer wakes it on the deadline
    var word = new int[1];
    word[0] = 7;
    int t2 = Sys.ticks ();
    int wr = Sys.wait_addr (word, 7, 30);
    int t3 = Sys.ticks ();
    if (wr < 0 && Sys.errno_code () == Sys.ETIMEDOUT && t3 > t2)
        print ("wait=ok\n");
    else {
        print ("wait=FAIL\n");
        fails++;
    }

    return fails;
}
