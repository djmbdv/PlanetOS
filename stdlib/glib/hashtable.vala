// Pure-Vala GLib.HashTable<K, V> (Robin Hood open addressing) for PlanetOS.

namespace GLib {

    public delegate uint HashFunc<K> (K key);
    public delegate bool EqualFunc<K> (K a, K b);
    public delegate void HFunc<K, V> (K key, V value);

    public uint str_hash (string s) {
        uint32 h = 2166136261u;
        for (int i = 0; i < s.length; i++) {
            h ^= (uint32) s[i];
            h *= 16777619u;
        }
        return (uint) h;
    }

    public bool str_equal (string a, string b) {
        if (a.length != b.length)
            return false;
        for (int i = 0; i < a.length; i++) {
            if (a[i] != b[i])
                return false;
        }
        return true;
    }

    public uint int_hash (int v) {
        return (uint) v;
    }

    public bool int_equal (int a, int b) {
        return a == b;
    }

    /**
     * Generic hash table with O(1) average lookup/insert/remove (GLib.HashTable).
     */
    public class HashTable<K, V> : Object {
        private K[] keys;
        private V[] vals;
        private int[] hashes; // -1 = empty
        private int _size = 0;
        private int _cap = 16;
        private HashFunc<K> _hash_fn;
        private EqualFunc<K> _eq_fn;
        private bool has_hash = false;
        private bool has_eq = false;
        private K zero_k;
        private V zero_v;

        // Standard GLib signature: new HashTable<K, V> (str_hash, str_equal).
        public HashTable (HashFunc<K> hash_func, EqualFunc<K> equal_func) {
            _hash_fn = hash_func;
            _eq_fn = equal_func;
            has_hash = true;
            has_eq = true;
            init_table (16);
        }

        // Keys compared with == and hashed by the runtime (ints, object identity).
        public HashTable.direct () {
            init_table (16);
        }

        private void init_table (int cap) {
            _cap = cap;
            keys = new K[cap];
            vals = new V[cap];
            hashes = new int[cap];
            for (int i = 0; i < cap; i++)
                hashes[i] = -1;
            _size = 0;
        }

        private int hash_key (K key) {
            uint32 x = has_hash ? (uint32) _hash_fn (key) : (uint32) __planc_hash (key);
            x ^= x >> 16;
            x *= 0x85EBCA6Bu;
            x ^= x >> 13;
            x *= 0xC2B2AE35u;
            x ^= x >> 16;
            return (int) (x & 0x7FFFFFFFu);
        }

        private bool eq_key (K a, K b) {
            if (has_eq)
                return _eq_fn (a, b);
            return a == b;
        }

        private void rehash (int new_cap) {
            K[] ok = keys;
            V[] ov = vals;
            int[] oh = hashes;
            int old_cap = _cap;
            init_table (new_cap);
            int mask = new_cap - 1;
            for (int i = 0; i < old_cap; i++) {
                if (oh[i] >= 0)
                    insert_new (ok[i], ov[i], oh[i], mask);
            }
        }

        private void insert_new (K key, V val, int h, int mask) {
            int idx = h & mask;
            int dist = 0;
            K ck = key;
            V cv = val;
            int ch = h;
            while (true) {
                int sh = hashes[idx];
                if (sh < 0) {
                    hashes[idx] = ch;
                    keys[idx] = ck;
                    vals[idx] = cv;
                    _size++;
                    return;
                }
                int sdist = (idx - (sh & mask)) & mask;
                if (dist > sdist) {
                    hashes[idx] = ch;
                    K tk = keys[idx]; keys[idx] = ck; ck = tk;
                    V tv = vals[idx]; vals[idx] = cv; cv = tv;
                    ch = sh;
                    dist = sdist;
                }
                idx = (idx + 1) & mask;
                dist++;
            }
        }

        private int find_slot (K key, int h) {
            int mask = _cap - 1;
            int idx = h & mask;
            int dist = 0;
            while (true) {
                int sh = hashes[idx];
                if (sh < 0)
                    return -1;
                int sdist = (idx - (sh & mask)) & mask;
                if (dist > sdist)
                    return -1;
                if (sh == h && eq_key (keys[idx], key))
                    return idx;
                idx = (idx + 1) & mask;
                dist++;
            }
        }

        public bool insert (K key, V val) {
            if ((_size + 1) * 4 >= _cap * 3) {
                // Cap growth at 2^29 slots so (_size + 1) * 4 and _cap << 1 never overflow int.
                if (_cap >= 0x20000000)
                    return false;
                rehash (_cap << 1);
            }
            int h = hash_key (key);
            int slot = find_slot (key, h);
            if (slot >= 0) {
                keys[slot] = key;
                vals[slot] = val;
                return false;
            }
            insert_new (key, val, h, _cap - 1);
            return true;
        }

        public bool replace (K key, V val) {
            return insert (key, val);
        }

        public V? lookup (K key) {
            int h = hash_key (key);
            int slot = find_slot (key, h);
            if (slot < 0)
                return zero_v;
            return vals[slot];
        }

        public bool contains (K key) {
            return find_slot (key, hash_key (key)) >= 0;
        }

        public bool remove (K key) {
            int h = hash_key (key);
            int slot = find_slot (key, h);
            if (slot < 0)
                return false;
            int mask = _cap - 1;
            int idx = slot;
            while (true) {
                int nxt = (idx + 1) & mask;
                int nh = hashes[nxt];
                if (nh < 0 || ((nxt - (nh & mask)) & mask) == 0)
                    break;
                hashes[idx] = nh;
                keys[idx] = keys[nxt];
                vals[idx] = vals[nxt];
                idx = nxt;
            }
            hashes[idx] = -1;
            keys[idx] = zero_k;
            vals[idx] = zero_v;
            _size--;
            return true;
        }

        public void remove_all () {
            init_table (16);
        }

        public uint size () {
            return (uint) _size;
        }

        public K[] get_keys_as_array () {
            var res = new K[_size];
            int j = 0;
            for (int i = 0; i < _cap && j < _size; i++) {
                if (hashes[i] >= 0)
                    res[j++] = keys[i];
            }
            return res;
        }

        public V[] get_values_as_array () {
            var res = new V[_size];
            int j = 0;
            for (int i = 0; i < _cap && j < _size; i++) {
                if (hashes[i] >= 0)
                    res[j++] = vals[i];
            }
            return res;
        }

        public void @foreach (HFunc<K, V> func) {
            for (int i = 0; i < _cap; i++) {
                if (hashes[i] >= 0)
                    func (keys[i], vals[i]);
            }
        }
    }
}
