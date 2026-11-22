// Pure-Vala Gee ArrayQueue<G> and PriorityQueue<G>.
namespace Gee {

    internal class ArrayQueueIterator<G> : Object, Iterator<G> {
        private G[] buf_ref;
        private int head_ref;
        private int size_ref;
        private int cap_ref;
        private int pos;
        private G zero_val;

        public ArrayQueueIterator (G[] b, int h, int s, int c) {
            buf_ref = b;
            head_ref = h;
            size_ref = s;
            cap_ref = c;
            pos = -1;
        }

        public bool has_next () {
            return (pos + 1) < size_ref;
        }

        public bool next () {
            if ((pos + 1) < size_ref) {
                pos++;
                return true;
            }
            return false;
        }

        public G get () {
            if (pos < 0 || pos >= size_ref)
                return zero_val;
            return buf_ref[(head_ref + pos) & (cap_ref - 1)];
        }
    }

    public class ArrayQueue<G> : Object, Queue<G> {
        private G[] buf;
        private int head;
        private int tail;
        private int _size;
        private int _cap;
        private G zero_val;

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
            if (_cap >= 0x40000000)
                return;
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
            if (_size == _cap) {
                if (_cap >= 0x40000000)
                    return false;
                grow ();
            }
            buf[tail] = item;
            tail = (tail + 1) & (_cap - 1);
            _size++;
            return true;
        }

        public G peek () {
            if (_size <= 0)
                return zero_val;
            return buf[head];
        }

        public G poll () {
            if (_size <= 0)
                return zero_val;
            G val = buf[head];
            buf[head] = zero_val;
            head = (head + 1) & (_cap - 1);
            _size--;
            return val;
        }

        public bool add (G item) {
            return offer (item);
        }

        public bool contains (G item) {
            int mask = _cap - 1;
            for (int i = 0; i < _size; i++) {
                if (buf[(head + i) & mask] == item)
                    return true;
            }
            return false;
        }

        public bool remove (G item) {
            int mask = _cap - 1;
            int found = -1;
            for (int i = 0; i < _size; i++) {
                if (buf[(head + i) & mask] == item) {
                    found = i;
                    break;
                }
            }
            if (found < 0)
                return false;
            for (int i = found; i + 1 < _size; i++)
                buf[(head + i) & mask] = buf[(head + i + 1) & mask];
            _size--;
            tail = (head + _size) & mask;
            buf[tail] = zero_val;
            return true;
        }

        public G[] to_array () {
            var res = new G[_size];
            int mask = _cap - 1;
            for (int i = 0; i < _size; i++)
                res[i] = buf[(head + i) & mask];
            return res;
        }

        public Iterator<G> iterator () {
            return new ArrayQueueIterator<G> (buf, head, _size, _cap);
        }

        public bool forall (ForallFunc<G> f) {
            int mask = _cap - 1;
            for (int i = 0; i < _size; i++) {
                if (!f (buf[(head + i) & mask]))
                    return false;
            }
            return true;
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

    internal class PriorityQueueIterator<G> : Object, Iterator<G> {
        private GenericArray<G> heap_ref;
        private int pos;
        private G zero_val;

        public PriorityQueueIterator (GenericArray<G> h) {
            heap_ref = h;
            pos = -1;
        }

        public bool has_next () {
            return (pos + 1) < heap_ref.length;
        }

        public bool next () {
            if ((pos + 1) < heap_ref.length) {
                pos++;
                return true;
            }
            return false;
        }

        public G get () {
            if (pos < 0 || pos >= heap_ref.length)
                return zero_val;
            return heap_ref[pos];
        }
    }

    public class PriorityQueue<G> : Object, Queue<G> {
        private GenericArray<G> heap;
        private Comparator<G>? cmp;
        private CompareDataFunc<G> cmp_fn;
        private bool has_cmp_fn = false;
        private G zero_val;

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

        public PriorityQueue.with_func (CompareDataFunc<G> compare_func) {
            cmp = null;
            cmp_fn = compare_func;
            has_cmp_fn = true;
            heap = new GenericArray<G> ();
        }

        private int do_cmp (G a, G b) {
            if (has_cmp_fn)
                return cmp_fn (a, b);
            return cmp.compare (a, b);
        }

        public bool add (G item) {
            return offer (item);
        }

        public bool contains (G item) {
            for (int i = 0; i < heap.length; i++) {
                if (heap[i] == item)
                    return true;
            }
            return false;
        }

        public bool remove (G item) {
            int found = -1;
            for (int i = 0; i < heap.length; i++) {
                if (heap[i] == item) {
                    found = i;
                    break;
                }
            }
            if (found < 0)
                return false;
            int last = heap.length - 1;
            if (found == last) {
                heap.remove_index (last);
                return true;
            }
            heap[found] = heap[last];
            heap.remove_index (last);
            int n = heap.length;
            int idx = found;
            while (idx > 0) {
                int p = (idx - 1) >> 1;
                if (do_cmp (heap[idx], heap[p]) < 0) {
                    G tmp = heap[p];
                    heap[p] = heap[idx];
                    heap[idx] = tmp;
                    idx = p;
                } else {
                    break;
                }
            }
            while (true) {
                int l = (idx << 1) + 1;
                int r = l + 1;
                int sm = idx;
                if (l < n && do_cmp (heap[l], heap[sm]) < 0) sm = l;
                if (r < n && do_cmp (heap[r], heap[sm]) < 0) sm = r;
                if (sm == idx)
                    break;
                G tmp = heap[idx];
                heap[idx] = heap[sm];
                heap[sm] = tmp;
                idx = sm;
            }
            return true;
        }

        public G[] to_array () {
            var res = new G[heap.length];
            for (int i = 0; i < heap.length; i++)
                res[i] = heap[i];
            return res;
        }

        public Iterator<G> iterator () {
            return new PriorityQueueIterator<G> (heap);
        }

        public bool forall (ForallFunc<G> f) {
            for (int i = 0; i < heap.length; i++) {
                if (!f (heap[i]))
                    return false;
            }
            return true;
        }

        public bool offer (G item) {
            int i = heap.length;
            heap.add (item);
            while (i > 0) {
                int p = (i - 1) >> 1;
                if (do_cmp (heap[i], heap[p]) < 0) {
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
            if (heap.length == 0)
                return zero_val;
            return heap[0];
        }

        public G poll () {
            if (heap.length == 0)
                return zero_val;
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
                if (l < n && do_cmp (heap[l], heap[sm]) < 0) sm = l;
                if (r < n && do_cmp (heap[r], heap[sm]) < 0) sm = r;
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
