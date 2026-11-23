// Pure-Vala Gee TreeSet<G> and TreeMap<K, V> (AVL-balanced BST) for PlanetOS.
namespace Gee {

    internal class AvlSetNode<G> : Object {
        public G val;
        public AvlSetNode<G>? left = null;
        public AvlSetNode<G>? right = null;
        public int height = 1;

        public AvlSetNode (G v) {
            val = v;
        }
    }

    internal class TreeSetIterator<G> : Object, Iterator<G> {
        private GenericArray<G> items;
        private int pos = -1;
        private G zero_val;

        public TreeSetIterator (GenericArray<G> arr) {
            items = arr;
        }

        public bool has_next () {
            return (pos + 1) < items.length;
        }

        public bool next () {
            if ((pos + 1) < items.length) {
                pos++;
                return true;
            }
            return false;
        }

        public G get () {
            if (pos < 0 || pos >= items.length)
                return zero_val;
            return items[pos];
        }
    }

    /**
     * Ordered set backed by an AVL tree (Gee.TreeSet). Use with_func (int_cmp / str_cmp)
     * for value ordering; the default constructor orders by hash.
     */
    public class TreeSet<G> : Object, Set<G> {
        private AvlSetNode<G>? root = null;
        private int _size = 0;
        private CompareDataFunc<G> _cmp_fn;
        private Comparator<G>? _cmp_obj = null;
        private bool has_cmp_fn = false;
        private G zero_val;

        public int size {
            get { return _size; }
        }

        public bool is_empty {
            get { return _size == 0; }
        }

        public TreeSet () {
        }

        public TreeSet.with_func (CompareDataFunc<G> compare_func) {
            _cmp_fn = compare_func;
            has_cmp_fn = true;
        }

        public TreeSet.with_comparator (Comparator<G> cmp) {
            _cmp_obj = cmp;
        }

        private int cmp (G a, G b) {
            if (has_cmp_fn)
                return _cmp_fn (a, b);
            if (_cmp_obj != null)
                return ((!) _cmp_obj).compare (a, b);
            // No comparator supplied: fall back to equality only. Ordered
            // iteration needs a comparator (use TreeSet.with_func (int_cmp)
            // or TreeSet.with_func (str_cmp)); structural operations stay valid.
            if (a == b) return 0;
            return (__planc_hash (a) < __planc_hash (b)) ? -1 : 1;
        }

        private static int h (AvlSetNode<G>? n) {
            return (n != null) ? ((!) n).height : 0;
        }

        private static void update_h (AvlSetNode<G> n) {
            int hl = h (n.left);
            int hr = h (n.right);
            n.height = ((hl > hr) ? hl : hr) + 1;
        }

        private static AvlSetNode<G> rot_right (AvlSetNode<G> y) {
            var x = (!) y.left;
            var t2 = x.right;
            x.right = y;
            y.left = t2;
            update_h (y);
            update_h (x);
            return x;
        }

        private static AvlSetNode<G> rot_left (AvlSetNode<G> x) {
            var y = (!) x.right;
            var t2 = y.left;
            y.left = x;
            x.right = t2;
            update_h (x);
            update_h (y);
            return y;
        }

        private static AvlSetNode<G> balance (AvlSetNode<G> n) {
            update_h (n);
            int bf = h (n.left) - h (n.right);
            if (bf > 1) {
                var l = (!) n.left;
                if (h (l.left) < h (l.right))
                    n.left = rot_left (l);
                return rot_right (n);
            }
            if (bf < -1) {
                var r = (!) n.right;
                if (h (r.right) < h (r.left))
                    n.right = rot_right (r);
                return rot_left (n);
            }
            return n;
        }

        private AvlSetNode<G> insert_rec (AvlSetNode<G>? node, G item, out bool added) {
            if (node == null) {
                added = true;
                return new AvlSetNode<G> (item);
            }
            var n = (!) node;
            int c = cmp (item, n.val);
            if (c < 0) {
                n.left = insert_rec (n.left, item, out added);
            } else if (c > 0) {
                n.right = insert_rec (n.right, item, out added);
            } else {
                added = false;
                return n;
            }
            return balance (n);
        }

        private static AvlSetNode<G> min_node (AvlSetNode<G> n) {
            var cur = n;
            while (cur.left != null)
                cur = (!) cur.left;
            return cur;
        }

        private AvlSetNode<G>? remove_rec (AvlSetNode<G>? node, G item, out bool removed) {
            if (node == null) {
                removed = false;
                return null;
            }
            var n = (!) node;
            int c = cmp (item, n.val);
            if (c < 0) {
                n.left = remove_rec (n.left, item, out removed);
            } else if (c > 0) {
                n.right = remove_rec (n.right, item, out removed);
            } else {
                removed = true;
                if (n.left == null)
                    return n.right;
                if (n.right == null)
                    return n.left;
                var succ = min_node ((!) n.right);
                n.val = succ.val;
                bool dummy = false;
                n.right = remove_rec (n.right, succ.val, out dummy);
            }
            return balance (n);
        }

        public bool add (G item) {
            bool added = false;
            root = insert_rec (root, item, out added);
            if (added)
                _size++;
            return added;
        }

        public bool contains (G item) {
            var cur = root;
            while (cur != null) {
                var n = (!) cur;
                int c = cmp (item, n.val);
                if (c == 0) return true;
                cur = (c < 0) ? n.left : n.right;
            }
            return false;
        }

        public bool remove (G item) {
            bool removed = false;
            root = remove_rec (root, item, out removed);
            if (removed)
                _size--;
            return removed;
        }

        public void clear () {
            root = null;
            _size = 0;
        }

        public G first () {
            if (root == null)
                return zero_val;
            return min_node ((!) root).val;
        }

        public G last () {
            if (root == null)
                return zero_val;
            var cur = (!) root;
            while (cur.right != null)
                cur = (!) cur.right;
            return cur.val;
        }

        private void collect_inorder (AvlSetNode<G>? node, GenericArray<G> out_arr) {
            if (node == null)
                return;
            var n = (!) node;
            collect_inorder (n.left, out_arr);
            out_arr.add (n.val);
            collect_inorder (n.right, out_arr);
        }

        public G[] to_array () {
            var arr = new GenericArray<G> ();
            collect_inorder (root, arr);
            var res = new G[arr.length];
            for (int i = 0; i < arr.length; i++)
                res[i] = arr[i];
            return res;
        }

        public Iterator<G> iterator () {
            var arr = new GenericArray<G> ();
            collect_inorder (root, arr);
            return new TreeSetIterator<G> (arr);
        }

        public bool forall (ForallFunc<G> f) {
            var arr = new GenericArray<G> ();
            collect_inorder (root, arr);
            for (int i = 0; i < arr.length; i++) {
                if (!f (arr[i]))
                    return false;
            }
            return true;
        }
    }

    internal class AvlMapNode<K, V> : Object {
        public K key;
        public V val;
        public AvlMapNode<K, V>? left = null;
        public AvlMapNode<K, V>? right = null;
        public int height = 1;

        public AvlMapNode (K k, V v) {
            key = k;
            val = v;
        }
    }

    /**
     * Ordered map backed by an AVL tree (Gee.TreeMap). Use with_func (int_cmp / str_cmp)
     * for key ordering; the default constructor orders by hash.
     */
    public class TreeMap<K, V> : Object, Map<K, V> {
        private AvlMapNode<K, V>? root = null;
        private int _size = 0;
        private CompareDataFunc<K> _cmp_fn;
        private Comparator<K>? _cmp_obj = null;
        private bool has_cmp_fn = false;
        private V zero_v;

        public int size {
            get { return _size; }
        }

        public bool is_empty {
            get { return _size == 0; }
        }

        public TreeMap () {
        }

        public TreeMap.with_func (CompareDataFunc<K> key_compare_func) {
            _cmp_fn = key_compare_func;
            has_cmp_fn = true;
        }

        public TreeMap.with_comparator (Comparator<K> cmp) {
            _cmp_obj = cmp;
        }

        private int cmp (K a, K b) {
            if (has_cmp_fn)
                return _cmp_fn (a, b);
            if (_cmp_obj != null)
                return ((!) _cmp_obj).compare (a, b);
            // No comparator supplied: order by the planc runtime hash, which is a
            // total order for int and string keys. Pass a comparator for custom order.
            int ha = __planc_hash (a);
            int hb = __planc_hash (b);
            if (a == b) return 0;
            if (ha != hb) return (ha < hb) ? -1 : 1;
            return 0;
        }

        private static int h (AvlMapNode<K, V>? n) {
            return (n != null) ? ((!) n).height : 0;
        }

        private static void update_h (AvlMapNode<K, V> n) {
            int hl = h (n.left);
            int hr = h (n.right);
            n.height = ((hl > hr) ? hl : hr) + 1;
        }

        private static AvlMapNode<K, V> rot_right (AvlMapNode<K, V> y) {
            var x = (!) y.left;
            var t2 = x.right;
            x.right = y;
            y.left = t2;
            update_h (y);
            update_h (x);
            return x;
        }

        private static AvlMapNode<K, V> rot_left (AvlMapNode<K, V> x) {
            var y = (!) x.right;
            var t2 = y.left;
            y.left = x;
            x.right = t2;
            update_h (x);
            update_h (y);
            return y;
        }

        private static AvlMapNode<K, V> balance (AvlMapNode<K, V> n) {
            update_h (n);
            int bf = h (n.left) - h (n.right);
            if (bf > 1) {
                var l = (!) n.left;
                if (h (l.left) < h (l.right))
                    n.left = rot_left (l);
                return rot_right (n);
            }
            if (bf < -1) {
                var r = (!) n.right;
                if (h (r.right) < h (r.left))
                    n.right = rot_right (r);
                return rot_left (n);
            }
            return n;
        }

        private AvlMapNode<K, V> insert_rec (AvlMapNode<K, V>? node, K key, V val, out bool added) {
            if (node == null) {
                added = true;
                return new AvlMapNode<K, V> (key, val);
            }
            var n = (!) node;
            int c = cmp (key, n.key);
            if (c < 0) {
                n.left = insert_rec (n.left, key, val, out added);
            } else if (c > 0) {
                n.right = insert_rec (n.right, key, val, out added);
            } else {
                added = false;
                n.val = val;
                return n;
            }
            return balance (n);
        }

        private static AvlMapNode<K, V> min_node (AvlMapNode<K, V> n) {
            var cur = n;
            while (cur.left != null)
                cur = (!) cur.left;
            return cur;
        }

        private AvlMapNode<K, V>? remove_rec (AvlMapNode<K, V>? node, K key, out bool removed, out V old_val) {
            if (node == null) {
                removed = false;
                old_val = zero_v;
                return null;
            }
            var n = (!) node;
            int c = cmp (key, n.key);
            if (c < 0) {
                n.left = remove_rec (n.left, key, out removed, out old_val);
            } else if (c > 0) {
                n.right = remove_rec (n.right, key, out removed, out old_val);
            } else {
                removed = true;
                old_val = n.val;
                if (n.left == null)
                    return n.right;
                if (n.right == null)
                    return n.left;
                var succ = min_node ((!) n.right);
                n.key = succ.key;
                n.val = succ.val;
                bool dummy = false;
                V dv;
                n.right = remove_rec (n.right, succ.key, out dummy, out dv);
            }
            return balance (n);
        }

        public bool has_key (K key) {
            var cur = root;
            while (cur != null) {
                var n = (!) cur;
                int c = cmp (key, n.key);
                if (c == 0) return true;
                cur = (c < 0) ? n.left : n.right;
            }
            return false;
        }

        public bool has (K key, V value) {
            var cur = root;
            while (cur != null) {
                var n = (!) cur;
                int c = cmp (key, n.key);
                if (c == 0) return n.val == value;
                cur = (c < 0) ? n.left : n.right;
            }
            return false;
        }

        public V get (K key) {
            var cur = root;
            while (cur != null) {
                var n = (!) cur;
                int c = cmp (key, n.key);
                if (c == 0) return n.val;
                cur = (c < 0) ? n.left : n.right;
            }
            return zero_v;
        }

        public void set (K key, V value) {
            bool added = false;
            root = insert_rec (root, key, value, out added);
            if (added)
                _size++;
        }

        public bool unset (K key) {
            bool removed = false;
            V old_v;
            root = remove_rec (root, key, out removed, out old_v);
            if (removed)
                _size--;
            return removed;
        }

        public void clear () {
            root = null;
            _size = 0;
        }
    }
}
