// A recycled block must come back zeroed: an array of references that starts
// with stale pointers would be unref'd (or dereferenced) as if it were live.
// 2000 slots is above the 4 KiB large-block threshold, so these blocks go
// through the large free list.
class Item {
    public int v = 1;
}

int main () {
    for (int round = 0; round < 64; round++) {
        var slots = new Item?[2000];
        for (int i = 0; i < 2000; i++) {
            if (slots[i] != null) {
                print (@"stale at $round:$i\n");
                return 1;
            }
            slots[i] = new Item ();
        }
        slots[7] = null;
    }
    var tail = new uint8[20000];
    for (int i = 0; i < 20000; i++) {
        if (tail[i] != 0) {
            print (@"stale byte at $i\n");
            return 2;
        }
    }
    print ("ok\n");
    return 0;
}
