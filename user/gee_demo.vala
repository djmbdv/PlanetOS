// Pure-Vala libgee compatibility demo & self-test for PlanetOS.
// Usage: exec gee_demo.elf

using Gee;

int main () {
    int fails = 0;

    // 1. ArrayList<string>
    var list = new ArrayList<string> ();
    list.add ("delta");
    list.add ("alpha");
    list.add ("charlie");
    list.insert (1, "bravo");
    if (list.size != 4 || list.get (1) != "bravo" || !list.contains ("charlie"))
        fails++;
    list.sort (new StrComparator ());
    if (list.first () != "alpha" || list.last () != "delta")
        fails++;

    // 2. LinkedList<int>
    var ll = new LinkedList<int> ();
    ll.offer_tail (20);
    ll.offer_head (10);
    ll.offer_tail (30);
    if (ll.size != 3 || ll.poll_head () != 10 || ll.poll_tail () != 30 || ll.first () != 20)
        fails++;

    // 3. HashSet<string>
    var set = new HashSet<string> ();
    set.add ("xfs");
    set.add ("virtio");
    set.add ("xfs");
    if (set.size != 2 || !set.contains ("virtio"))
        fails++;
    set.remove ("xfs");
    if (set.size != 1 || set.contains ("xfs"))
        fails++;

    // 4. HashMap<string, int>
    var map = new HashMap<string, int> ();
    map.set ("one", 1);
    map.set ("two", 2);
    map.set ("three", 3);
    map.set ("two", 22);
    if (map.size != 3 || !map.has_key ("two") || map.get ("two") != 22)
        fails++;
    map.unset ("one");
    if (map.size != 2 || map.has_key ("one"))
        fails++;

    // 5. ArrayQueue<string>
    var q = new ArrayQueue<string> ();
    q.offer ("first");
    q.offer ("second");
    if (q.peek () != "first" || q.poll () != "first" || q.poll () != "second" || !q.is_empty)
        fails++;

    // 6. PriorityQueue<int>
    var pq = new PriorityQueue<int> (new IntComparator ());
    pq.offer (40);
    pq.offer (10);
    pq.offer (30);
    pq.offer (20);
    if (pq.poll () != 10 || pq.poll () != 20 || pq.poll () != 30 || pq.poll () != 40)
        fails++;

    // 7. Quicksort (> 16 elements) + remove_at
    var nums = new ArrayList<int> ();
    for (int i = 24; i >= 0; i--)
        nums.add (i * 3 % 25);
    nums.sort (new IntComparator ());
    for (int i = 0; i < 25; i++) {
        if (nums.get (i) != i)
            fails++;
    }
    if (nums.remove_at (5) != 5 || nums.size != 24)
        fails++;

    // 8. HashMap<int, int> & HashSet<int> rehash + tombstones
    var imap = new HashMap<int, int> ();
    var iset = new HashSet<int> ();
    for (int i = 0; i < 32; i++) {
        imap.set (i, i * 10);
        iset.add (i);
    }
    for (int i = 0; i < 16; i++) {
        imap.unset (i);
        iset.remove (i);
    }
    for (int i = 0; i < 8; i++) {
        imap.set (i, i * 100);
        iset.add (i);
    }
    if (imap.size != 24 || iset.size != 24 || imap.get (5) != 500 || imap.get (20) != 200 || imap.has_key (10))
        fails++;

    // 9. ArrayQueue<int> circular wraparound + grow
    var iq = new ArrayQueue<int> ();
    for (int i = 0; i < 6; i++)
        iq.offer (i);
    for (int i = 0; i < 4; i++) {
        if (iq.poll () != i)
            fails++;
    }
    for (int i = 6; i < 18; i++)
        iq.offer (i);
    for (int i = 4; i < 18; i++) {
        if (iq.poll () != i)
            fails++;
    }
    if (!iq.is_empty)
        fails++;

    // 10. LinkedList<int> middle insert & remove_at
    var ll2 = new LinkedList<int> ();
    ll2.add (1);
    ll2.add (3);
    ll2.insert (1, 2);
    ll2.add (4);
    if (ll2.get (1) != 2 || ll2.get (2) != 3 || ll2.remove_at (1) != 2 || ll2.size != 3)
        fails++;

    // 11. EytzingerBTree<int, int> (splits + updates + lookups)
    var btree = new EytzingerBTree<int, int> (new IntComparator ());
    for (int i = 0; i < 60; i++)
        btree.set ((i * 17) % 60, i * 10);
    btree.set (7, 7777);
    if (btree.size != 60 || !btree.has_key (42) || btree.has_key (99) || btree.get (7) != 7777)
        fails++;

    // 12. AdaptiveRadixTree<int> (path compression, node growth, prefix search, remove)
    var art = new AdaptiveRadixTree<int> ();
    art.set ("kernel", 1);
    art.set ("klog", 2);
    art.set ("keyboard", 3);
    art.set ("key", 4);
    for (int i = 0; i < 20; i++)
        art.set (@"k_$(i)", 100 + i);
    var kpref = art.keys_with_prefix ("key");
    if (art.size != 24 || art.get ("key") != 4 || art.get ("k_19") != 119 || kpref.size != 2)
        fails++;
    if (!art.remove ("keyboard") || art.has_key ("keyboard") || art.size != 23)
        fails++;

    // 13. CuckooFilter (insert, contains, remove)
    var cf = new CuckooFilter (64);
    for (int i = 0; i < 40; i++)
        cf.add (@"item_$i");
    if (cf.size != 40 || !cf.contains ("item_0") || !cf.contains ("item_39"))
        fails++;
    if (!cf.remove ("item_12") || cf.size != 39)
        fails++;

    print (@"gee_demo: list=$(list.size) map=$(map.size) fails=$fails\n");
    return (fails == 0) ? 0 : 1;
}
