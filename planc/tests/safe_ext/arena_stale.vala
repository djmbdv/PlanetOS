int main () {
    GLib.Arena ar = new GLib.Arena (16);
    GLib.ArenaHandle h = ar.alloc (4);
    ar.set (h, 0, 9);
    ar.reset ();
    ar.set (h, 0, 1);
    print (@"stale=$(ar.valid (h) ? 1 : 0) rejected=$(ar.rejected)\n");
    return 0;
}