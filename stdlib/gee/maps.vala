// Pure-Vala Gee HashSet<G>, MapEntry<K, V>, and HashMap<K, V>.
namespace Gee {

    internal class HashSetIterator<G> : Object, Iterator<G> {
        private G[] slots_ref;
        private int[] hashes_ref;
        private int cap_ref;
        private int pos;
        private G zero_val;

        public HashSetIterator (G[] s, int[] h, int c) {
            slots_ref = s;
            hashes_ref = h;
            cap_ref = c;
            pos = -1;
        }

        public bool has_next () {
            for (int i = pos + 1; i < cap_ref; i++) {
                if (hashes_ref[i] >= 0)
                    return true;
            }
            return false;
        }

        public bool next () {
            for (int i = pos + 1; i < cap_ref; i++) {
                if (hashes_ref[i] >= 0) {
                    pos = i;
                    return true;
                }
            }
            pos = cap_ref;
            return false;
        }

        public G get () {
            if (pos < 0 || pos >= cap_ref || hashes_ref[pos] < 0)
                return zero_val;
            return slots_ref[pos];
        }
    }

    public class HashSet<G> : Object, Set<G> {
        private G[] slots;
        private int[] hashes; // -1 = empty, >= 0 = occupied mixed hash
        private int _size;
        private int _cap;
        private int _seed;
        private Hasher<G>? _hasher;
        private HashDataFunc<G> _hash_fn;
        private EqualDataFunc<G> _eq_fn;
        private bool _has_hash_fn = false;
        private bool _has_eq_fn = false;
        private G zero_val;

        public int size {
            get { return _size; }
        }

        public bool is_empty {
            get { return _size == 0; }
        }

        public HashSet (Hasher<G>? hasher = null) {
            _hasher = hasher;
            _gee_next_seed = hash_mix (_gee_next_seed, 0x9E3779B9);
            _seed = _gee_next_seed;
            init_table (16);
        }

        public HashSet.with_funcs (HashDataFunc<G> hash_func, EqualDataFunc<G> equal_func) {
            _hasher = null;
            _hash_fn = hash_func;
            _eq_fn = equal_func;
            _has_hash_fn = true;
            _has_eq_fn = true;
            _gee_next_seed = hash_mix (_gee_next_seed, 0x9E3779B9);
            _seed = _gee_next_seed;
            init_table (16);
        }

        private void init_table (int cap) {
            _cap = cap;
            slots = new G[cap];
            hashes = new int[cap];
            for (int i = 0; i < cap; i++)
                hashes[i] = -1;
            _size = 0;
        }

        private int hash_item (G item) {
            int raw;
            if (_has_hash_fn)
                raw = _hash_fn (item);
            else if (_hasher != null)
                raw = _hasher.hash (item);
            else
                raw = __planc_hash (item);
            return hash_mix (raw, _seed);
        }

        private bool eq_item (G a, G b) {
            if (_has_eq_fn)
                return _eq_fn (a, b);
            if (_hasher != null)
                return _hasher.equal (a, b);
            return a == b;
        }

        private void rehash (int new_cap) {
            G[] old_slots = slots;
            int[] old_hashes = hashes;
            int old_cap = _cap;
            init_table (new_cap);
            int mask = new_cap - 1;
            for (int i = 0; i < old_cap; i++) {
                int oh = old_hashes[i];
                if (oh >= 0) {
                    insert_new (old_slots[i], oh, mask);
                }
            }
        }

        private void insert_new (G item, int h, int mask) {
            int idx = h & mask;
            int dist = 0;
            G cur_item = item;
            int cur_h = h;
            while (true) {
                int sh = hashes[idx];
                if (sh < 0) {
                    hashes[idx] = cur_h;
                    slots[idx] = cur_item;
                    _size++;
                    return;
                }
                int sdist = (idx - (sh & mask)) & mask;
                if (dist > sdist) {
                    hashes[idx] = cur_h;
                    G tmp_item = slots[idx];
                    slots[idx] = cur_item;
                    cur_h = sh;
                    cur_item = tmp_item;
                    dist = sdist;
                }
                idx = (idx + 1) & mask;
                dist++;
            }
        }

        private int find_slot (G item) {
            int h = hash_item (item);
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
                if (sh == h && eq_item (slots[idx], item))
                    return idx;
                idx = (idx + 1) & mask;
                dist++;
            }
        }

        public bool contains (G item) {
            return find_slot (item) >= 0;
        }

        public bool add (G item) {
            if ((_size + 1) * 10 >= _cap * 7) {
                if (_cap < 0x40000000)
                    rehash (_cap << 1);
                else if (_size >= _cap - 1)
                    return false;
            }
            int h = hash_item (item);
            int mask = _cap - 1;
            int idx = h & mask;
            int dist = 0;
            G cur_item = item;
            int cur_h = h;
            bool checking_dup = true;
            while (true) {
                int sh = hashes[idx];
                if (sh < 0) {
                    hashes[idx] = cur_h;
                    slots[idx] = cur_item;
                    _size++;
                    return true;
                }
                int sdist = (idx - (sh & mask)) & mask;
                if (checking_dup) {
                    if (sh == cur_h && eq_item (slots[idx], cur_item))
                        return false;
                    if (dist > sdist)
                        checking_dup = false;
                }
                if (dist > sdist) {
                    hashes[idx] = cur_h;
                    G tmp_item = slots[idx];
                    slots[idx] = cur_item;
                    cur_h = sh;
                    cur_item = tmp_item;
                    dist = sdist;
                }
                idx = (idx + 1) & mask;
                dist++;
            }
        }

        public bool remove (G item) {
            int idx = find_slot (item);
            if (idx < 0)
                return false;
            int mask = _cap - 1;
            int cur = idx;
            while (true) {
                int nxt = (cur + 1) & mask;
                int nh = hashes[nxt];
                if (nh < 0 || ((nxt - (nh & mask)) & mask) == 0) {
                    hashes[cur] = -1;
                    slots[cur] = zero_val;
                    break;
                }
                hashes[cur] = nh;
                slots[cur] = slots[nxt];
                cur = nxt;
            }
            _size--;
            if (_size == 0 && _cap > 16)
                init_table (16);
            return true;
        }

        public void clear () {
            if (_size > 0 || _cap > 16)
                init_table (16);
        }

        public Iterator<G> iterator () {
            return new HashSetIterator<G> (slots, hashes, _cap);
        }

        public bool forall (ForallFunc<G> f) {
            for (int i = 0; i < _cap; i++) {
                if (hashes[i] >= 0 && !f (slots[i]))
                    return false;
            }
            return true;
        }

        public G[] to_array () {
            var res = new G[_size];
            int k = 0;
            for (int i = 0; i < _cap; i++) {
                if (hashes[i] >= 0) {
                    res[k] = slots[i];
                    k++;
                }
            }
            return res;
        }

        public ArrayList<G> to_list () {
            var res = new ArrayList<G> ();
            for (int i = 0; i < _cap; i++) {
                if (hashes[i] >= 0)
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

    public class HashMap<K, V> : Object, Map<K, V> {
        private K[] karr;
        private V[] varr;
        private int[] hashes; // -1 = empty, >= 0 = occupied mixed hash
        private int _size;
        private int _cap;
        private int _seed;
        private Hasher<K>? _hasher;
        private HashDataFunc<K> _hash_fn;
        private EqualDataFunc<K> _eq_fn;
        private EqualDataFunc<V> _val_eq_fn;
        private bool _has_hash_fn = false;
        private bool _has_eq_fn = false;
        private bool _has_val_eq_fn = false;
        private K zero_k;
        private V zero_v;

        public int size {
            get { return _size; }
        }

        public bool is_empty {
            get { return _size == 0; }
        }

        public HashMap (Hasher<K>? hasher = null) {
            _hasher = hasher;
            _gee_next_seed = hash_mix (_gee_next_seed, 0x9E3779B9);
            _seed = _gee_next_seed;
            init_table (16);
        }

        public HashMap.with_funcs (HashDataFunc<K> key_hash_func, EqualDataFunc<K> key_equal_func) {
            _hasher = null;
            _hash_fn = key_hash_func;
            _eq_fn = key_equal_func;
            _has_hash_fn = true;
            _has_eq_fn = true;
            _gee_next_seed = hash_mix (_gee_next_seed, 0x9E3779B9);
            _seed = _gee_next_seed;
            init_table (16);
        }

        public void set_value_equal_func (EqualDataFunc<V> value_equal_func) {
            _val_eq_fn = value_equal_func;
            _has_val_eq_fn = true;
        }

        private void init_table (int cap) {
            _cap = cap;
            karr = new K[cap];
            varr = new V[cap];
            hashes = new int[cap];
            for (int i = 0; i < cap; i++)
                hashes[i] = -1;
            _size = 0;
        }

        private int hash_key (K key) {
            int raw;
            if (_has_hash_fn)
                raw = _hash_fn (key);
            else if (_hasher != null)
                raw = _hasher.hash (key);
            else
                raw = __planc_hash (key);
            return hash_mix (raw, _seed);
        }

        private bool eq_key (K a, K b) {
            if (_has_eq_fn)
                return _eq_fn (a, b);
            if (_hasher != null)
                return _hasher.equal (a, b);
            return a == b;
        }

        private void rehash (int new_cap) {
            K[] old_k = karr;
            V[] old_v = varr;
            int[] old_h = hashes;
            int old_cap = _cap;
            init_table (new_cap);
            int mask = new_cap - 1;
            for (int i = 0; i < old_cap; i++) {
                int oh = old_h[i];
                if (oh >= 0) {
                    insert_new (old_k[i], old_v[i], oh, mask);
                }
            }
        }

        private void insert_new (K key, V val, int h, int mask) {
            int idx = h & mask;
            int dist = 0;
            K cur_k = key;
            V cur_v = val;
            int cur_h = h;
            while (true) {
                int sh = hashes[idx];
                if (sh < 0) {
                    hashes[idx] = cur_h;
                    karr[idx] = cur_k;
                    varr[idx] = cur_v;
                    _size++;
                    return;
                }
                int sdist = (idx - (sh & mask)) & mask;
                if (dist > sdist) {
                    hashes[idx] = cur_h;
                    K tmp_k = karr[idx];
                    V tmp_v = varr[idx];
                    karr[idx] = cur_k;
                    varr[idx] = cur_v;
                    cur_h = sh;
                    cur_k = tmp_k;
                    cur_v = tmp_v;
                    dist = sdist;
                }
                idx = (idx + 1) & mask;
                dist++;
            }
        }

        private int find_slot (K key) {
            int h = hash_key (key);
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
                if (sh == h && eq_key (karr[idx], key))
                    return idx;
                idx = (idx + 1) & mask;
                dist++;
            }
        }

        public bool has_key (K key) {
            return find_slot (key) >= 0;
        }

        public bool has (K key, V val) {
            int idx = find_slot (key);
            if (idx < 0)
                return false;
            if (_has_val_eq_fn)
                return _val_eq_fn (varr[idx], val);
            return varr[idx] == val;
        }

        public void set (K key, V val) {
            if ((_size + 1) * 10 >= _cap * 7) {
                if (_cap < 0x40000000)
                    rehash (_cap << 1);
                else if (_size >= _cap - 1)
                    return;
            }
            int h = hash_key (key);
            int mask = _cap - 1;
            int idx = h & mask;
            int dist = 0;
            K cur_k = key;
            V cur_v = val;
            int cur_h = h;
            bool checking_dup = true;
            while (true) {
                int sh = hashes[idx];
                if (sh < 0) {
                    hashes[idx] = cur_h;
                    karr[idx] = cur_k;
                    varr[idx] = cur_v;
                    _size++;
                    return;
                }
                int sdist = (idx - (sh & mask)) & mask;
                if (checking_dup) {
                    if (sh == cur_h && eq_key (karr[idx], cur_k)) {
                        varr[idx] = cur_v;
                        return;
                    }
                    if (dist > sdist)
                        checking_dup = false;
                }
                if (dist > sdist) {
                    hashes[idx] = cur_h;
                    K tmp_k = karr[idx];
                    V tmp_v = varr[idx];
                    karr[idx] = cur_k;
                    varr[idx] = cur_v;
                    cur_h = sh;
                    cur_k = tmp_k;
                    cur_v = tmp_v;
                    dist = sdist;
                }
                idx = (idx + 1) & mask;
                dist++;
            }
        }

        public V get (K key) {
            int idx = find_slot (key);
            if (idx < 0)
                return zero_v;
            return varr[idx];
        }

        public bool unset (K key) {
            int idx = find_slot (key);
            if (idx < 0)
                return false;
            int mask = _cap - 1;
            int cur = idx;
            while (true) {
                int nxt = (cur + 1) & mask;
                int nh = hashes[nxt];
                if (nh < 0 || ((nxt - (nh & mask)) & mask) == 0) {
                    hashes[cur] = -1;
                    karr[cur] = zero_k;
                    varr[cur] = zero_v;
                    break;
                }
                hashes[cur] = nh;
                karr[cur] = karr[nxt];
                varr[cur] = varr[nxt];
                cur = nxt;
            }
            _size--;
            if (_size == 0 && _cap > 16)
                init_table (16);
            return true;
        }

        public void clear () {
            if (_size > 0 || _cap > 16)
                init_table (16);
        }

        public ArrayList<K> keys () {
            var res = new ArrayList<K> ();
            for (int i = 0; i < _cap; i++) {
                if (hashes[i] >= 0)
                    res.add (karr[i]);
            }
            return res;
        }

        public ArrayList<V> values () {
            var res = new ArrayList<V> ();
            for (int i = 0; i < _cap; i++) {
                if (hashes[i] >= 0)
                    res.add (varr[i]);
            }
            return res;
        }

        public ArrayList<MapEntry<K, V>> entries () {
            var res = new ArrayList<MapEntry<K, V>> ();
            for (int i = 0; i < _cap; i++) {
                if (hashes[i] >= 0)
                    res.add (new MapEntry<K, V> (karr[i], varr[i]));
            }
            return res;
        }
    }

    // ------------------------------------------------------------------
    // B-Tree with Eytzinger (BFS) Cache-Friendly Node Layout
    // ------------------------------------------------------------------

    internal const int EYTZ_MAX_KEYS = 15; // 2^4 - 1: complete binary tree per node

    internal class EytzNode<K, V> : Object {
        public int n;
        public bool leaf;
        // Eytzinger 1-based layout (indices 1..n)
        public K[] e_keys;
        public V[] e_vals;
        public int[] e_inord; // maps Eytzinger slot 1..n -> sorted index 0..n-1
        // Sorted arrays (0..n-1) and children (0..n)
        public K[] s_keys;
        public V[] s_vals;
        public EytzNode<K, V>?[] children;

        public EytzNode (bool is_leaf) {
            n = 0;
            leaf = is_leaf;
            e_keys = new K[EYTZ_MAX_KEYS + 1];
            e_vals = new V[EYTZ_MAX_KEYS + 1];
            e_inord = new int[EYTZ_MAX_KEYS + 1];
            s_keys = new K[EYTZ_MAX_KEYS];
            s_vals = new V[EYTZ_MAX_KEYS];
            children = new EytzNode<K, V>?[EYTZ_MAX_KEYS + 1];
        }

        private int build_eytz (int idx, int pos) {
            if (idx > n)
                return pos;
            pos = build_eytz (idx * 2, pos);
            e_keys[idx] = s_keys[pos];
            e_vals[idx] = s_vals[pos];
            e_inord[idx] = pos;
            pos++;
            return build_eytz (idx * 2 + 1, pos);
        }

        public void rebuild_eytz () {
            build_eytz (1, 0);
        }
    }

    public class EytzingerBTree<K, V> : Object {
        private EytzNode<K, V> root;
        private Comparator<K> cmp;
        private int _size;
        private V zero_v;

        public int size {
            get { return _size; }
        }

        public bool is_empty {
            get { return _size == 0; }
        }

        public EytzingerBTree (Comparator<K> comparator) {
            cmp = comparator;
            root = new EytzNode<K, V> (true);
            _size = 0;
        }

        public void clear () {
            root = new EytzNode<K, V> (true);
            _size = 0;
        }

        // Eytzinger search inside a node. Returns sorted index (0..n-1) if found,
        // or -(child_idx + 1) where child_idx (0..n) is the descent slot.
        private int eytz_search (EytzNode<K, V> node, K key) {
            int i = 1;
            int ge = 0;
            while (i <= node.n) {
                int c = cmp.compare (key, node.e_keys[i]);
                if (c == 0)
                    return node.e_inord[i];
                if (c < 0) {
                    ge = i;
                    i = i * 2;
                } else {
                    i = i * 2 + 1;
                }
            }
            int child_idx = (ge != 0) ? node.e_inord[ge] : node.n;
            return -(child_idx + 1);
        }

        public bool has_key (K key) {
            EytzNode<K, V>? cur = root;
            while (cur != null) {
                int r = eytz_search (cur, key);
                if (r >= 0)
                    return true;
                if (cur.leaf)
                    return false;
                cur = cur.children[-(r + 1)];
            }
            return false;
        }

        public V get (K key) {
            EytzNode<K, V>? cur = root;
            while (cur != null) {
                int r = eytz_search (cur, key);
                if (r >= 0)
                    return cur.s_vals[r];
                if (cur.leaf)
                    return zero_v;
                cur = cur.children[-(r + 1)];
            }
            return zero_v;
        }

        private void split_child (EytzNode<K, V> parent, int idx, EytzNode<K, V> full) {
            int mid = EYTZ_MAX_KEYS / 2; // 7
            var right = new EytzNode<K, V> (full.leaf);
            right.n = EYTZ_MAX_KEYS - mid - 1; // 7
            for (int j = 0; j < right.n; j++) {
                right.s_keys[j] = full.s_keys[mid + 1 + j];
                right.s_vals[j] = full.s_vals[mid + 1 + j];
            }
            if (!full.leaf) {
                for (int j = 0; j <= right.n; j++) {
                    right.children[j] = full.children[mid + 1 + j];
                    full.children[mid + 1 + j] = null;
                }
            }
            full.n = mid;
            full.rebuild_eytz ();
            right.rebuild_eytz ();

            for (int j = parent.n; j >= idx + 1; j--)
                parent.children[j + 1] = parent.children[j];
            parent.children[idx + 1] = right;

            for (int j = parent.n - 1; j >= idx; j--) {
                parent.s_keys[j + 1] = parent.s_keys[j];
                parent.s_vals[j + 1] = parent.s_vals[j];
            }
            parent.s_keys[idx] = full.s_keys[mid];
            parent.s_vals[idx] = full.s_vals[mid];
            parent.n++;
            parent.rebuild_eytz ();
        }

        private void insert_non_full (EytzNode<K, V> node, K key, V val) {
            int r = eytz_search (node, key);
            if (r >= 0) {
                node.s_vals[r] = val;
                node.rebuild_eytz ();
                return;
            }
            int pos = -(r + 1);
            if (node.leaf) {
                for (int j = node.n - 1; j >= pos; j--) {
                    node.s_keys[j + 1] = node.s_keys[j];
                    node.s_vals[j + 1] = node.s_vals[j];
                }
                node.s_keys[pos] = key;
                node.s_vals[pos] = val;
                node.n++;
                node.rebuild_eytz ();
                _size++;
                return;
            }
            EytzNode<K, V>? child = node.children[pos];
            if (child == null)
                return;
            if (child.n == EYTZ_MAX_KEYS) {
                split_child (node, pos, child);
                int c = cmp.compare (key, node.s_keys[pos]);
                if (c == 0) {
                    node.s_vals[pos] = val;
                    node.rebuild_eytz ();
                    return;
                }
                if (c > 0)
                    pos++;
            }
            EytzNode<K, V>? next_child = node.children[pos];
            if (next_child != null)
                insert_non_full (next_child, key, val);
        }

        public void set (K key, V val) {
            if (root.n == EYTZ_MAX_KEYS) {
                var new_root = new EytzNode<K, V> (false);
                new_root.children[0] = root;
                split_child (new_root, 0, root);
                root = new_root;
            }
            insert_non_full (root, key, val);
        }
    }

    // ------------------------------------------------------------------
    // Adaptive Radix Tree (ART) for string keys: Node4 / Node16 / Node48 / Node256
    // ------------------------------------------------------------------

    internal const int ART_KIND_4   = 1;
    internal const int ART_KIND_16  = 2;
    internal const int ART_KIND_48  = 3;
    internal const int ART_KIND_256 = 4;

    internal class ArtNode<V> : Object {
        public int kind;
        public int count;
        public string prefix;
        public bool has_val;
        public V val;

        public int[] keys; // byte values 0..255 (or index map 0..255 for ART_KIND_48)
        public ArtNode<V>?[] children;

        public ArtNode (int node_kind) {
            kind = node_kind;
            count = 0;
            prefix = "";
            has_val = false;
            if (node_kind == ART_KIND_4) {
                keys = new int[4];
                children = new ArtNode<V>?[4];
            } else if (node_kind == ART_KIND_16) {
                keys = new int[16];
                children = new ArtNode<V>?[16];
            } else if (node_kind == ART_KIND_48) {
                keys = new int[256];
                for (int i = 0; i < 256; i++)
                    keys[i] = -1;
                children = new ArtNode<V>?[48];
            } else {
                keys = new int[0];
                children = new ArtNode<V>?[256];
            }
        }

        public ArtNode<V>? find_child (int b) {
            if (kind == ART_KIND_4 || kind == ART_KIND_16) {
                for (int i = 0; i < count; i++) {
                    if (keys[i] == b)
                        return children[i];
                }
                return null;
            }
            if (kind == ART_KIND_48) {
                int slot = keys[b];
                return (slot >= 0) ? children[slot] : null;
            }
            return children[b];
        }

        public void replace_child (int b, ArtNode<V>? child) {
            if (kind == ART_KIND_4 || kind == ART_KIND_16) {
                for (int i = 0; i < count; i++) {
                    if (keys[i] == b) {
                        children[i] = child;
                        return;
                    }
                }
                return;
            }
            if (kind == ART_KIND_48) {
                int slot = keys[b];
                if (slot >= 0)
                    children[slot] = child;
                return;
            }
            children[b] = child;
        }

        public bool is_full () {
            if (kind == ART_KIND_4) return count == 4;
            if (kind == ART_KIND_16) return count == 16;
            if (kind == ART_KIND_48) return count == 48;
            return false;
        }

        public ArtNode<V> grow () {
            int next_kind = (kind == ART_KIND_4) ? ART_KIND_16 : ((kind == ART_KIND_16) ? ART_KIND_48 : ART_KIND_256);
            var n = new ArtNode<V> (next_kind);
            n.prefix = prefix;
            n.has_val = has_val;
            n.val = val;
            if (kind == ART_KIND_4 || kind == ART_KIND_16) {
                for (int i = 0; i < count; i++)
                    n.add_child (keys[i], children[i]);
            } else if (kind == ART_KIND_48) {
                for (int b = 0; b < 256; b++) {
                    if (keys[b] >= 0)
                        n.add_child (b, children[keys[b]]);
                }
            }
            return n;
        }

        public void add_child (int b, ArtNode<V>? child) {
            if (kind == ART_KIND_4 || kind == ART_KIND_16) {
                int pos = count;
                while (pos > 0 && keys[pos - 1] > b) {
                    keys[pos] = keys[pos - 1];
                    children[pos] = children[pos - 1];
                    pos--;
                }
                keys[pos] = b;
                children[pos] = child;
                count++;
                return;
            }
            if (kind == ART_KIND_48) {
                int slot = 0;
                while (slot < 48 && children[slot] != null)
                    slot++;
                keys[b] = slot;
                children[slot] = child;
                count++;
                return;
            }
            if (children[b] == null && child != null)
                count++;
            children[b] = child;
        }

        public void remove_child (int b) {
            if (kind == ART_KIND_4 || kind == ART_KIND_16) {
                for (int i = 0; i < count; i++) {
                    if (keys[i] == b) {
                        for (int j = i; j < count - 1; j++) {
                            keys[j] = keys[j + 1];
                            children[j] = children[j + 1];
                        }
                        children[count - 1] = null;
                        count--;
                        return;
                    }
                }
                return;
            }
            if (kind == ART_KIND_48) {
                int slot = keys[b];
                if (slot >= 0) {
                    keys[b] = -1;
                    children[slot] = null;
                    count--;
                }
                return;
            }
            if (children[b] != null) {
                children[b] = null;
                count--;
            }
        }
    }

    public class AdaptiveRadixTree<V> : Object {
        private ArtNode<V>? root;
        private int _size;
        private V zero_v;

        public int size {
            get { return _size; }
        }

        public bool is_empty {
            get { return _size == 0; }
        }

        public AdaptiveRadixTree () {
            root = null;
            _size = 0;
        }

        public void clear () {
            root = null;
            _size = 0;
        }

        private static int common_prefix_len (string a, int a_off, string b) {
            int max_l = a.length - a_off;
            if (b.length < max_l)
                max_l = b.length;
            int i = 0;
            while (i < max_l && a[a_off + i] == b[i])
                i++;
            return i;
        }

        private ArtNode<V>? find_node (string key) {
            ArtNode<V>? cur = root;
            int depth = 0;
            while (cur != null) {
                int plen = cur.prefix.length;
                if (plen > 0) {
                    if (key.length - depth < plen)
                        return null;
                    for (int i = 0; i < plen; i++) {
                        if (key[depth + i] != cur.prefix[i])
                            return null;
                    }
                    depth += plen;
                }
                if (depth == key.length)
                    return cur;
                int b = key[depth] & 0xFF;
                cur = cur.find_child (b);
                depth++;
            }
            return null;
        }

        public bool has_key (string key) {
            var n = find_node (key);
            return n != null && n.has_val;
        }

        public V get (string key) {
            var n = find_node (key);
            if (n != null && n.has_val)
                return n.val;
            return zero_v;
        }

        private ArtNode<V> insert_rec (ArtNode<V>? node, string key, int depth, V val) {
            if (node == null) {
                var leaf = new ArtNode<V> (ART_KIND_4);
                leaf.prefix = key.substring (depth);
                leaf.has_val = true;
                leaf.val = val;
                _size++;
                return leaf;
            }

            int cp = common_prefix_len (key, depth, node.prefix);
            if (cp < node.prefix.length) {
                var split = new ArtNode<V> (ART_KIND_4);
                split.prefix = node.prefix.substring (0, cp);
                int old_b = node.prefix[cp] & 0xFF;
                node.prefix = node.prefix.substring (cp + 1);
                split.add_child (old_b, node);

                if (depth + cp == key.length) {
                    split.has_val = true;
                    split.val = val;
                    _size++;
                } else {
                    int new_b = key[depth + cp] & 0xFF;
                    var leaf = new ArtNode<V> (ART_KIND_4);
                    leaf.prefix = key.substring (depth + cp + 1);
                    leaf.has_val = true;
                    leaf.val = val;
                    _size++;
                    split.add_child (new_b, leaf);
                }
                return split;
            }

            depth += cp;
            if (depth == key.length) {
                if (!node.has_val)
                    _size++;
                node.has_val = true;
                node.val = val;
                return node;
            }

            int b = key[depth] & 0xFF;
            ArtNode<V>? child = node.find_child (b);
            if (child != null) {
                ArtNode<V> updated = insert_rec (child, key, depth + 1, val);
                if (updated != child)
                    node.replace_child (b, updated);
                return node;
            }

            if (node.is_full ())
                node = node.grow ();
            var new_leaf = new ArtNode<V> (ART_KIND_4);
            new_leaf.prefix = key.substring (depth + 1);
            new_leaf.has_val = true;
            new_leaf.val = val;
            _size++;
            node.add_child (b, new_leaf);
            return node;
        }

        public void set (string key, V val) {
            root = insert_rec (root, key, 0, val);
        }

        public bool remove (string key) {
            if (root == null)
                return false;
            ArtNode<V>? cur = root;
            ArtNode<V>? parent = null;
            int parent_b = 0;
            int depth = 0;
            while (cur != null) {
                int plen = cur.prefix.length;
                if (plen > 0) {
                    if (key.length - depth < plen)
                        return false;
                    for (int i = 0; i < plen; i++) {
                        if (key[depth + i] != cur.prefix[i])
                            return false;
                    }
                    depth += plen;
                }
                if (depth == key.length) {
                    if (!cur.has_val)
                        return false;
                    cur.has_val = false;
                    cur.val = zero_v;
                    _size--;
                    if (cur.count == 0) {
                        if (parent == null)
                            root = null;
                        else
                            parent.remove_child (parent_b);
                    }
                    return true;
                }
                int b = key[depth] & 0xFF;
                parent = cur;
                parent_b = b;
                cur = cur.find_child (b);
                depth++;
            }
            return false;
        }

        private static string byte_str (int b) {
            if (b >= 32 && b <= 126) {
                string ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
                return ascii.substring (b - 32, 1);
            }
            if (b == 9) return "\t";
            if (b == 10) return "\n";
            if (b == 13) return "\r";
            return "?";
        }

        private void collect_keys (ArtNode<V>? node, string acc, ArrayList<string> out_keys) {
            if (node == null)
                return;
            string full = acc + node.prefix;
            if (node.has_val)
                out_keys.add (full);
            if (node.kind == ART_KIND_4 || node.kind == ART_KIND_16) {
                for (int i = 0; i < node.count; i++)
                    collect_keys (node.children[i], full + byte_str (node.keys[i]), out_keys);
            } else if (node.kind == ART_KIND_48) {
                for (int b = 0; b < 256; b++) {
                    if (node.keys[b] >= 0)
                        collect_keys (node.children[node.keys[b]], full + byte_str (b), out_keys);
                }
            } else {
                for (int b = 0; b < 256; b++) {
                    if (node.children[b] != null)
                        collect_keys (node.children[b], full + byte_str (b), out_keys);
                }
            }
        }

        public ArrayList<string> keys_with_prefix (string prefix) {
            var res = new ArrayList<string> ();
            ArtNode<V>? cur = root;
            int depth = 0;
            string acc = "";
            while (cur != null) {
                int cp = common_prefix_len (prefix, depth, cur.prefix);
                if (depth + cp == prefix.length) {
                    collect_keys (cur, acc, res);
                    return res;
                }
                if (cp < cur.prefix.length)
                    return res;
                acc = acc + cur.prefix;
                depth += cur.prefix.length;
                int b = prefix[depth] & 0xFF;
                acc = acc + byte_str (b);
                cur = cur.find_child (b);
                depth++;
            }
            return res;
        }
    }

    // ------------------------------------------------------------------
    // Cuckoo Filter (4 slots/bucket, 16-bit fingerprints, symmetric XOR buckets)
    // ------------------------------------------------------------------

    public class CuckooFilter : Object {
        private const int BUCKET_SLOTS = 4;
        private const int MAX_KICKS = 500;

        private int[] table; // 16-bit fingerprints (0 = empty)
        private int num_buckets;
        private int mask;
        private int _size;
        private int prng_state;

        public int size {
            get { return _size; }
        }

        public bool is_empty {
            get { return _size == 0; }
        }

        public CuckooFilter (int capacity_hint = 256) {
            int buckets = 16;
            int min_b = (capacity_hint + BUCKET_SLOTS - 1) / BUCKET_SLOTS;
            while (buckets < min_b)
                buckets = buckets << 1;
            num_buckets = buckets;
            mask = num_buckets - 1;
            table = new int[num_buckets * BUCKET_SLOTS];
            _size = 0;
            prng_state = 0x243F6A88;
        }

        public void clear () {
            int total = num_buckets * BUCKET_SLOTS;
            for (int i = 0; i < total; i++)
                table[i] = 0;
            _size = 0;
        }

        private int next_rand () {
            int x = prng_state;
            x = x ^ (x << 13);
            x = x ^ ((x >> 17) & 0x7FFF);
            x = x ^ (x << 5);
            prng_state = x;
            return x & 0x7FFFFFFF;
        }

        private static int str_fnv1a (string key) {
            uint32 h = 2166136261u;
            int len = key.length;
            for (int i = 0; i < len; i++) {
                h = h ^ (uint32) (key[i] & 0xFF);
                h = h * 16777619u;
            }
            return (int) (h & 0x7FFFFFFFu);
        }

        private static int fingerprint (int h) {
            int fp = ((h >> 16) ^ h) & 0xFFFF;
            return (fp == 0) ? 1 : fp;
        }

        private int alt_bucket (int bucket, int fp) {
            int fh = hash_mix (fp, 0x5BD1E995);
            int delta = fh & mask;
            if (delta == 0)
                delta = 1;
            return (bucket ^ delta) & mask;
        }

        private bool bucket_insert (int b, int fp) {
            int base_idx = b * BUCKET_SLOTS;
            for (int s = 0; s < BUCKET_SLOTS; s++) {
                if (table[base_idx + s] == 0) {
                    table[base_idx + s] = fp;
                    return true;
                }
            }
            return false;
        }

        private bool bucket_has (int b, int fp) {
            int base_idx = b * BUCKET_SLOTS;
            for (int s = 0; s < BUCKET_SLOTS; s++) {
                if (table[base_idx + s] == fp)
                    return true;
            }
            return false;
        }

        private bool bucket_remove (int b, int fp) {
            int base_idx = b * BUCKET_SLOTS;
            for (int s = 0; s < BUCKET_SLOTS; s++) {
                if (table[base_idx + s] == fp) {
                    table[base_idx + s] = 0;
                    return true;
                }
            }
            return false;
        }

        public bool add (string key) {
            int h = hash_mix (str_fnv1a (key), 0x9E3779B9);
            int fp = fingerprint (h);
            int i1 = h & mask;
            int i2 = alt_bucket (i1, fp);

            if (bucket_insert (i1, fp) || bucket_insert (i2, fp)) {
                _size++;
                return true;
            }

            int b = ((next_rand () & 1) == 0) ? i1 : i2;
            for (int kick = 0; kick < MAX_KICKS; kick++) {
                int slot = next_rand () % BUCKET_SLOTS;
                int idx = b * BUCKET_SLOTS + slot;
                int old_fp = table[idx];
                table[idx] = fp;
                fp = old_fp;
                b = alt_bucket (b, fp);
                if (bucket_insert (b, fp)) {
                    _size++;
                    return true;
                }
            }
            return false;
        }

        public bool contains (string key) {
            int h = hash_mix (str_fnv1a (key), 0x9E3779B9);
            int fp = fingerprint (h);
            int i1 = h & mask;
            int i2 = alt_bucket (i1, fp);
            return bucket_has (i1, fp) || bucket_has (i2, fp);
        }

        public bool remove (string key) {
            int h = hash_mix (str_fnv1a (key), 0x9E3779B9);
            int fp = fingerprint (h);
            int i1 = h & mask;
            int i2 = alt_bucket (i1, fp);
            if (bucket_remove (i1, fp) || bucket_remove (i2, fp)) {
                _size--;
                return true;
            }
            return false;
        }
    }

}
