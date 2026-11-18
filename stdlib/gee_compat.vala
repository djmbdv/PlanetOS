// Pure-Vala libgee (GNOME/libgee) compatibility layer for PlanetOS.
// Provides ArrayList<G>, LinkedList<G>, HashSet<G>, HashMap<K, V>,
// MapEntry<K, V>, ArrayQueue<G>, and PriorityQueue<G> with zero C / zero .vapi.
//
// Optimized implementations:
// - ArrayList<G>: in-place remove_index + hybrid Quicksort (median-of-3 + insertion sort)
// - LinkedList<G>: true doubly-linked list (O(1) head/tail ops, unowned prev for ARC)
// - HashSet<G> / HashMap<K, V>: O(1) open-addressing hash tables using __planc_hash
// - ArrayQueue<G>: O(1) power-of-2 circular ring buffer
// - PriorityQueue<G>: O(log n) in-place binary heap with zero-alloc poll()

namespace Gee {

    public class Comparator<G> : Object {
        public virtual int compare (G a, G b) {
            return 0;
        }
    }

    public class IntComparator : Comparator<int> {
        public override int compare (int a, int b) {
            if (a < b) return -1;
            if (a > b) return 1;
            return 0;
        }
    }

    public class StrComparator : Comparator<string> {
        public override int compare (string a, string b) {
            return str_cmp (a, b);
        }
    }

    public class Hasher<G> : Object {
        public virtual int hash (G v) {
            return __planc_hash (v);
        }

        public virtual bool equal (G a, G b) {
            return a == b;
        }
    }

    public int str_hash (string s) {
        return __planc_hash (s);
    }

    public int int_hash (int v) {
        return __planc_hash (v);
    }

    public int str_cmp (string a, string b) {
        int la = a.length;
        int lb = b.length;
        int n = (la < lb) ? la : lb;
        for (int i = 0; i < n; i++) {
            int ca = (int) a[i];
            int cb = (int) b[i];
            if (ca != cb)
                return ca - cb;
        }
        return la - lb;
    }

    public int int_cmp (int a, int b) {
        if (a < b) return -1;
        if (a > b) return 1;
        return 0;
    }

    public class ArrayList<G> : Object {
        private GenericArray<G> inner;

        public int size {
            get { return inner.length; }
        }

        public bool is_empty {
            get { return inner.length == 0; }
        }

        public ArrayList () {
            inner = new GenericArray<G> ();
        }

        public bool add (G item) {
            inner.add (item);
            return true;
        }

        public G get (int index) {
            return inner[index];
        }

        public void set (int index, G item) {
            inner[index] = item;
        }

        public bool contains (G item) {
            int n = inner.length;
            for (int i = 0; i < n; i++) {
                if (inner[i] == item)
                    return true;
            }
            return false;
        }

        public int index_of (G item) {
            int n = inner.length;
            for (int i = 0; i < n; i++) {
                if (inner[i] == item)
                    return i;
            }
            return -1;
        }

        public void insert (int index, G item) {
            int n = inner.length;
            if (index < 0) index = 0;
            if (index >= n) {
                inner.add (item);
                return;
            }
            inner.add (inner[n - 1]);
            for (int i = n - 1; i > index; i--) {
                inner[i] = inner[i - 1];
            }
            inner[index] = item;
        }

        public G remove_at (int index) {
            G val = inner[index];
            inner.remove_index (index);
            return val;
        }

        public bool remove (G item) {
            int idx = index_of (item);
            if (idx < 0)
                return false;
            inner.remove_index (idx);
            return true;
        }

        public G first () {
            return inner[0];
        }

        public G last () {
            return inner[inner.length - 1];
        }

        public void clear () {
            if (inner.length > 0)
                inner = new GenericArray<G> ();
        }

        public void add_all (ArrayList<G> other) {
            int n = other.size;
            for (int i = 0; i < n; i++)
                inner.add (other.get (i));
        }

        public ArrayList<G> slice (int start, int stop) {
            var res = new ArrayList<G> ();
            int s = (start < 0) ? 0 : start;
            int e = (stop > inner.length) ? inner.length : stop;
            for (int i = s; i < e; i++)
                res.add (inner[i]);
            return res;
        }

        private void insertion_sort (int lo, int hi, Comparator<G> cmp) {
            for (int i = lo + 1; i <= hi; i++) {
                G key = inner[i];
                int j = i - 1;
                while (j >= lo && cmp.compare (inner[j], key) > 0) {
                    inner[j + 1] = inner[j];
                    j--;
                }
                inner[j + 1] = key;
            }
        }

        private void swap_idx (int a, int b) {
            G tmp = inner[a];
            inner[a] = inner[b];
            inner[b] = tmp;
        }

        private void qsort_range (int lo, int hi, Comparator<G> cmp) {
            while (hi - lo > 16) {
                int mid = lo + ((hi - lo) >> 1);
                if (cmp.compare (inner[mid], inner[lo]) < 0)
                    swap_idx (lo, mid);
                if (cmp.compare (inner[hi], inner[lo]) < 0)
                    swap_idx (lo, hi);
                if (cmp.compare (inner[hi], inner[mid]) < 0)
                    swap_idx (mid, hi);
                G pivot = inner[mid];
                int i = lo;
                int j = hi;
                while (i <= j) {
                    while (cmp.compare (inner[i], pivot) < 0) i++;
                    while (cmp.compare (inner[j], pivot) > 0) j--;
                    if (i <= j) {
                        swap_idx (i, j);
                        i++;
                        j--;
                    }
                }
                if (j - lo < hi - i) {
                    if (lo < j)
                        qsort_range (lo, j, cmp);
                    lo = i;
                } else {
                    if (i < hi)
                        qsort_range (i, hi, cmp);
                    hi = j;
                }
            }
            if (lo < hi)
                insertion_sort (lo, hi, cmp);
        }

        public void sort (Comparator<G> cmp) {
            int n = inner.length;
            if (n > 1)
                qsort_range (0, n - 1, cmp);
        }
    }

    internal class LinkNode<G> : Object {
        public G val;
        public LinkNode<G>? next;
        public LinkNode<G>? prev;

        public LinkNode (G v) {
            val = v;
            next = null;
            prev = null;
        }
    }

    public class LinkedList<G> : Object {
        private LinkNode<G>? head;
        private LinkNode<G>? tail;
        private int _size;

        public int size {
            get { return _size; }
        }

        public bool is_empty {
            get { return _size == 0; }
        }

        public LinkedList () {
            head = null;
            tail = null;
            _size = 0;
        }

        ~LinkedList () {
            clear ();
        }

        private unowned LinkNode<G>? node_at (int index) {
            if (index < 0 || index >= _size)
                return null;
            if (index < (_size >> 1)) {
                unowned LinkNode<G>? cur = head;
                for (int i = 0; i < index; i++) {
                    if (cur != null)
                        cur = cur.next;
                }
                return cur;
            } else {
                unowned LinkNode<G>? cur = tail;
                for (int i = _size - 1; i > index; i--) {
                    if (cur != null)
                        cur = cur.prev;
                }
                return cur;
            }
        }

        public bool add (G item) {
            return offer_tail (item);
        }

        public G get (int index) {
            unowned LinkNode<G>? n = node_at (index);
            return n.val;
        }

        public void set (int index, G item) {
            unowned LinkNode<G>? n = node_at (index);
            if (n != null)
                n.val = item;
        }

        public void insert (int index, G item) {
            if (index <= 0) {
                offer_head (item);
                return;
            }
            if (index >= _size) {
                offer_tail (item);
                return;
            }
            unowned LinkNode<G>? nxt = node_at (index);
            if (nxt == null)
                return;
            unowned LinkNode<G>? prv = nxt.prev;
            if (prv == null)
                return;
            var node = new LinkNode<G> (item);
            node.prev = prv;
            node.next = prv.next;
            nxt.prev = node;
            prv.next = node;
            _size++;
        }

        public G remove_at (int index) {
            if (index == 0)
                return poll_head ();
            if (index == _size - 1)
                return poll_tail ();
            LinkNode<G>? target = node_at (index);
            G val = target.val;
            LinkNode<G>? prv = target.prev;
            LinkNode<G>? nxt = target.next;
            if (nxt != null)
                nxt.prev = prv;
            if (prv != null)
                prv.next = nxt;
            target.prev = null;
            target.next = null;
            _size--;
            return val;
        }

        public bool remove (G item) {
            LinkNode<G>? cur = head;
            while (cur != null) {
                if (cur.val == item) {
                    LinkNode<G>? prv = cur.prev;
                    LinkNode<G>? nxt = cur.next;
                    if (prv != null)
                        prv.next = nxt;
                    else
                        head = nxt;
                    if (nxt != null)
                        nxt.prev = prv;
                    else
                        tail = prv;
                    cur.prev = null;
                    cur.next = null;
                    _size--;
                    return true;
                }
                cur = cur.next;
            }
            return false;
        }

        public bool contains (G item) {
            return index_of (item) >= 0;
        }

        public int index_of (G item) {
            unowned LinkNode<G>? cur = head;
            int idx = 0;
            while (cur != null) {
                if (cur.val == item)
                    return idx;
                cur = cur.next;
                idx++;
            }
            return -1;
        }

        public G first () {
            return head.val;
        }

        public G last () {
            return tail.val;
        }

        public void clear () {
            LinkNode<G>? cur = head;
            head = null;
            tail = null;
            _size = 0;
            while (cur != null) {
                LinkNode<G>? nxt = cur.next;
                cur.prev = null;
                cur.next = null;
                cur = nxt;
            }
        }

        public bool offer_head (G item) {
            var node = new LinkNode<G> (item);
            if (head == null) {
                head = node;
                tail = node;
            } else {
                head.prev = node;
                node.next = head;
                head = node;
            }
            _size++;
            return true;
        }

        public G poll_head () {
            LinkNode<G>? h = head;
            G val = h.val;
            head = h.next;
            h.next = null;
            h.prev = null;
            if (head != null)
                head.prev = null;
            else
                tail = null;
            _size--;
            return val;
        }

        public bool offer_tail (G item) {
            var node = new LinkNode<G> (item);
            if (tail == null) {
                head = node;
                tail = node;
            } else {
                node.prev = tail;
                tail.next = node;
                tail = node;
            }
            _size++;
            return true;
        }

        public G poll_tail () {
            LinkNode<G>? t = tail;
            G val = t.val;
            tail = t.prev;
            t.prev = null;
            t.next = null;
            if (tail != null)
                tail.next = null;
            else
                head = null;
            _size--;
            return val;
        }
    }

    public class HashSet<G> : Object {
        private G[] slots;
        private int[] states; // 0 = empty, 1 = occupied, 2 = tombstone
        private int _size;
        private int _used;
        private int _cap;
        private Hasher<G>? _hasher;

        public int size {
            get { return _size; }
        }

        public bool is_empty {
            get { return _size == 0; }
        }

        public HashSet (Hasher<G>? hasher = null) {
            _hasher = hasher;
            init_table (16);
        }

        private void init_table (int cap) {
            _cap = cap;
            slots = new G[cap];
            states = new int[cap];
            _size = 0;
            _used = 0;
        }

        private int hash_item (G item) {
            if (_hasher != null)
                return _hasher.hash (item) & 0x7FFFFFFF;
            return __planc_hash (item);
        }

        private bool eq_item (G a, G b) {
            if (_hasher != null)
                return _hasher.equal (a, b);
            return a == b;
        }

        private void rehash (int new_cap) {
            G[] old_slots = slots;
            int[] old_states = states;
            int old_cap = _cap;
            init_table (new_cap);
            int mask = new_cap - 1;
            for (int i = 0; i < old_cap; i++) {
                if (old_states[i] == 1) {
                    G item = old_slots[i];
                    int idx = hash_item (item) & mask;
                    while (states[idx] == 1)
                        idx = (idx + 1) & mask;
                    slots[idx] = item;
                    states[idx] = 1;
                    _size++;
                    _used++;
                }
            }
        }

        public bool contains (G item) {
            int mask = _cap - 1;
            int idx = hash_item (item) & mask;
            while (states[idx] != 0) {
                if (states[idx] == 1 && eq_item (slots[idx], item))
                    return true;
                idx = (idx + 1) & mask;
            }
            return false;
        }

        public bool add (G item) {
            if ((_used + 1) * 10 >= _cap * 7) {
                int new_cap = (_size * 2 >= _cap) ? (_cap << 1) : _cap;
                rehash (new_cap);
            }
            int mask = _cap - 1;
            int idx = hash_item (item) & mask;
            int first_tomb = -1;
            while (states[idx] != 0) {
                if (states[idx] == 1) {
                    if (eq_item (slots[idx], item))
                        return false;
                } else if (first_tomb < 0) {
                    first_tomb = idx;
                }
                idx = (idx + 1) & mask;
            }
            int dst = (first_tomb >= 0) ? first_tomb : idx;
            if (states[dst] == 0)
                _used++;
            slots[dst] = item;
            states[dst] = 1;
            _size++;
            return true;
        }

        public bool remove (G item) {
            int mask = _cap - 1;
            int idx = hash_item (item) & mask;
            while (states[idx] != 0) {
                if (states[idx] == 1 && eq_item (slots[idx], item)) {
                    states[idx] = 2;
                    _size--;
                    if (_size == 0)
                        clear ();
                    return true;
                }
                idx = (idx + 1) & mask;
            }
            return false;
        }

        public void clear () {
            if (_size > 0 || _used > 0)
                init_table (16);
        }

        public ArrayList<G> to_list () {
            var res = new ArrayList<G> ();
            for (int i = 0; i < _cap; i++) {
                if (states[i] == 1)
                    res.add (slots[i]);
            }
            return res;
        }

        public void add_all (HashSet<G> other) {
            var ol = other.to_list ();
            int n = ol.size;
            for (int i = 0; i < n; i++)
                add (ol.get (i));
        }
    }

    public class MapEntry<K, V> : Object {
        public K key;
        public V value;

        public MapEntry (K k, V v) {
            key = k;
            value = v;
        }
    }

    public class HashMap<K, V> : Object {
        private K[] karr;
        private V[] varr;
        private int[] states; // 0 = empty, 1 = occupied, 2 = tombstone
        private int _size;
        private int _used;
        private int _cap;
        private Hasher<K>? _hasher;

        public int size {
            get { return _size; }
        }

        public bool is_empty {
            get { return _size == 0; }
        }

        public HashMap (Hasher<K>? hasher = null) {
            _hasher = hasher;
            init_table (16);
        }

        private void init_table (int cap) {
            _cap = cap;
            karr = new K[cap];
            varr = new V[cap];
            states = new int[cap];
            _size = 0;
            _used = 0;
        }

        private int hash_key (K key) {
            if (_hasher != null)
                return _hasher.hash (key) & 0x7FFFFFFF;
            return __planc_hash (key);
        }

        private bool eq_key (K a, K b) {
            if (_hasher != null)
                return _hasher.equal (a, b);
            return a == b;
        }

        private void rehash (int new_cap) {
            K[] old_k = karr;
            V[] old_v = varr;
            int[] old_s = states;
            int old_cap = _cap;
            init_table (new_cap);
            int mask = new_cap - 1;
            for (int i = 0; i < old_cap; i++) {
                if (old_s[i] == 1) {
                    K k = old_k[i];
                    int idx = hash_key (k) & mask;
                    while (states[idx] == 1)
                        idx = (idx + 1) & mask;
                    karr[idx] = k;
                    varr[idx] = old_v[i];
                    states[idx] = 1;
                    _size++;
                    _used++;
                }
            }
        }

        private int find_slot (K key) {
            int mask = _cap - 1;
            int idx = hash_key (key) & mask;
            while (states[idx] != 0) {
                if (states[idx] == 1 && eq_key (karr[idx], key))
                    return idx;
                idx = (idx + 1) & mask;
            }
            return -1;
        }

        public bool has_key (K key) {
            return find_slot (key) >= 0;
        }

        public void set (K key, V val) {
            if ((_used + 1) * 10 >= _cap * 7) {
                int new_cap = (_size * 2 >= _cap) ? (_cap << 1) : _cap;
                rehash (new_cap);
            }
            int mask = _cap - 1;
            int idx = hash_key (key) & mask;
            int first_tomb = -1;
            while (states[idx] != 0) {
                if (states[idx] == 1) {
                    if (eq_key (karr[idx], key)) {
                        varr[idx] = val;
                        return;
                    }
                } else if (first_tomb < 0) {
                    first_tomb = idx;
                }
                idx = (idx + 1) & mask;
            }
            int dst = (first_tomb >= 0) ? first_tomb : idx;
            if (states[dst] == 0)
                _used++;
            karr[dst] = key;
            varr[dst] = val;
            states[dst] = 1;
            _size++;
        }

        public V get (K key) {
            int idx = find_slot (key);
            return varr[idx];
        }

        public bool unset (K key) {
            int idx = find_slot (key);
            if (idx < 0)
                return false;
            states[idx] = 2;
            _size--;
            if (_size == 0)
                clear ();
            return true;
        }

        public void clear () {
            if (_size > 0 || _used > 0)
                init_table (16);
        }

        public ArrayList<K> keys () {
            var res = new ArrayList<K> ();
            for (int i = 0; i < _cap; i++) {
                if (states[i] == 1)
                    res.add (karr[i]);
            }
            return res;
        }

        public ArrayList<V> values () {
            var res = new ArrayList<V> ();
            for (int i = 0; i < _cap; i++) {
                if (states[i] == 1)
                    res.add (varr[i]);
            }
            return res;
        }

        public ArrayList<MapEntry<K, V>> entries () {
            var res = new ArrayList<MapEntry<K, V>> ();
            for (int i = 0; i < _cap; i++) {
                if (states[i] == 1)
                    res.add (new MapEntry<K, V> (karr[i], varr[i]));
            }
            return res;
        }
    }

    public class ArrayQueue<G> : Object {
        private G[] buf;
        private int head;
        private int tail;
        private int _size;
        private int _cap;

        public int size {
            get { return _size; }
        }

        public bool is_empty {
            get { return _size == 0; }
        }

        public ArrayQueue () {
            _cap = 8;
            buf = new G[_cap];
            head = 0;
            tail = 0;
            _size = 0;
        }

        private void grow () {
            int new_cap = _cap << 1;
            G[] next = new G[new_cap];
            int mask = _cap - 1;
            for (int i = 0; i < _size; i++)
                next[i] = buf[(head + i) & mask];
            buf = next;
            head = 0;
            tail = _size;
            _cap = new_cap;
        }

        public bool offer (G item) {
            if (_size == _cap)
                grow ();
            buf[tail] = item;
            tail = (tail + 1) & (_cap - 1);
            _size++;
            return true;
        }

        public G peek () {
            return buf[head];
        }

        public G poll () {
            if (_size <= 0)
                return buf[0];
            G val = buf[head];
            head = (head + 1) & (_cap - 1);
            _size--;
            return val;
        }

        public void clear () {
            if (_size > 0) {
                _cap = 8;
                buf = new G[_cap];
                head = 0;
                tail = 0;
                _size = 0;
            }
        }
    }

    public class PriorityQueue<G> : Object {
        private GenericArray<G> heap;
        private Comparator<G> cmp;

        public int size {
            get { return heap.length; }
        }

        public bool is_empty {
            get { return heap.length == 0; }
        }

        public PriorityQueue (Comparator<G> compare_obj) {
            cmp = compare_obj;
            heap = new GenericArray<G> ();
        }

        public bool offer (G item) {
            int i = heap.length;
            heap.add (item);
            while (i > 0) {
                int p = (i - 1) >> 1;
                if (cmp.compare (heap[i], heap[p]) < 0) {
                    G tmp = heap[p];
                    heap[p] = heap[i];
                    heap[i] = tmp;
                    i = p;
                } else {
                    break;
                }
            }
            return true;
        }

        public G peek () {
            return heap[0];
        }

        public G poll () {
            if (heap.length == 0)
                return heap[0];
            G top = heap[0];
            int last = heap.length - 1;
            if (last > 0)
                heap[0] = heap[last];
            heap.remove_index (last);
            int n = heap.length;
            int idx = 0;
            while (true) {
                int l = (idx << 1) + 1;
                int r = l + 1;
                int sm = idx;
                if (l < n && cmp.compare (heap[l], heap[sm]) < 0) sm = l;
                if (r < n && cmp.compare (heap[r], heap[sm]) < 0) sm = r;
                if (sm == idx)
                    break;
                G tmp = heap[idx];
                heap[idx] = heap[sm];
                heap[sm] = tmp;
                idx = sm;
            }
            return top;
        }

        public void clear () {
            if (heap.length > 0)
                heap = new GenericArray<G> ();
        }
    }
}
