// Test suite for GLib.Once, Mutex, RWLock, Bytes, DateTime, Checksum, and Base64.
using GLib;

[AsmBody(@"
    add $16, %rdi
    mov %rdi, %rax
    ret
")]
private extern int __ex_arr_addr (uint8[] a);

int main (string[] args) {
    int fails = 0;
    int checks = 0;

    // 1. GLib.Once
    var once_cell = new uint8[8];
    int oa = __ex_arr_addr (once_cell);
    checks++;
    if (!Once.init_enter (oa)) {
        print ("glib_extra: FAIL Once.init_enter first\n");
        fails++;
    }
    Once.init_leave (oa, 42);
    checks++;
    if (Once.init_enter (oa) || AtomicPointer.get (oa) != 42) {
        print ("glib_extra: FAIL Once.init_enter second\n");
        fails++;
    }

    // 2. GLib.Mutex & GLib.RWLock
    var mtx = new Mutex ();
    checks++;
    if (!mtx.trylock ()) {
        print ("glib_extra: FAIL Mutex.trylock\n");
        fails++;
    }
    mtx.unlock ();
    var rwl = new RWLock ();
    checks++;
    if (!rwl.reader_trylock () || !rwl.reader_trylock () || rwl.writer_trylock ()) {
        print ("glib_extra: FAIL RWLock readers\n");
        fails++;
    }
    rwl.reader_unlock ();
    rwl.reader_unlock ();
    checks++;
    if (!rwl.writer_trylock ()) {
        print ("glib_extra: FAIL RWLock writer\n");
        fails++;
    }
    rwl.writer_unlock ();

    // 3. GLib.Bytes & GLib.ByteArray
    uint8[] raw = { 'P', 'l', 'a', 'n', 'e', 't', 'O', 'S' };
    var b1 = new Bytes (raw);
    var b2 = b1.new_from_bytes (6, 2);
    checks++;
    if (b1.get_size () != 8 || b2.get_size () != 2 || b2.get_byte (0) != 'O' || b2.get_byte (1) != 'S') {
        print ("glib_extra: FAIL Bytes slice\n");
        fails++;
    }

    var ba = new ByteArray ();
    ba.append (raw);
    ba.append_byte ((uint8) '!');
    var dst = new uint8[3];
    int copied = ba.copy_to (6, dst, 0, 3);
    checks++;
    if (ba.len != 9 || ba.get_byte (8) != (uint8) '!' || copied != 3 || dst[0] != 'O' || dst[1] != 'S' || dst[2] != '!') {
        print ("glib_extra: FAIL ByteArray append_byte/copy_to\n");
        fails++;
    }
    uint8[] patch = { (uint8) '2', (uint8) '6' };
    ba.write_at (6, patch);
    checks++;
    if (ba.to_string () != "Planet26!") {
        print ("glib_extra: FAIL ByteArray write_at/to_string\n");
        fails++;
    }
    var stolen = ba.steal ();
    checks++;
    if (ba.len != 0 || stolen.length != 9 || stolen[8] != (uint8) '!') {
        print ("glib_extra: FAIL ByteArray steal\n");
        fails++;
    }

    // 4. GLib.DateTime
    var dt = DateTime.from_unix_utc (1700000000L);
    var dt2 = dt.add (TIME_SPAN_HOUR);
    checks++;
    if (dt.format_iso8601 () != "2023-11-14T22:13:20Z" || dt2.difference (dt) != TIME_SPAN_HOUR) {
        print ("glib_extra: FAIL DateTime\n");
        fails++;
    }

    // 5. GLib.Checksum (CRC32 + SHA256) & Base64
    string crc = Checksum.compute_for_string (ChecksumType.CRC32, "123456789");
    checks++;
    if (crc != "cbf43926") {
        print (@"glib_extra: FAIL CRC32 got $crc\n");
        fails++;
    }
    string sha = Checksum.compute_for_string (ChecksumType.SHA256, "abc");
    checks++;
    if (sha != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") {
        print (@"glib_extra: FAIL SHA256 got $sha\n");
        fails++;
    }
    uint8[] b64_in = { 'M', 'a', 'n' };
    string enc = Base64.encode (b64_in);
    var dec = Base64.decode (enc);
    checks++;
    if (enc != "TWFu" || dec.length != 3 || dec[0] != 'M' || dec[1] != 'a' || dec[2] != 'n') {
        print (@"glib_extra: FAIL Base64 got $enc\n");
        fails++;
    }

    print (@"glib_extra:summary checks=$checks failures=$fails\n");
    return (fails == 0) ? 0 : 1;
}
