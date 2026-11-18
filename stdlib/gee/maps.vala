// Pure-Vala Gee HashSet<G>, MapEntry<K, V>, and HashMap<K, V>.
namespace Gee {

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

}
