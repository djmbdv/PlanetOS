int main () {
    GLib.Arena ar = new GLib.Arena (64);
    GLib.ArenaHandle h = ar.alloc (8);
    ar.set (h, 0, 42);
    ar.set_int (h, 1, 7);
    print (@"byte=$(ar.get (h, 0)) int=$(ar.get_int (h, 1)) used=$(ar.used)\n");

    GLib.ArenaHandle big = ar.alloc (4096);
    print (@"rejected=$(ar.rejected) valid_big=$(ar.valid (big) ? 1 : 0)\n");

    ar.reset ();
    print (@"stale=$(ar.valid (h) ? 1 : 0) gen=$(ar.generation)\n");
    return 0;
}