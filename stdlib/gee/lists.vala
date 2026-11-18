// Pure-Vala Gee ArrayList<G> and LinkedList<G>.
namespace Gee {

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

}
