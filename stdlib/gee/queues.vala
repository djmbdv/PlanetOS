// Pure-Vala Gee ArrayQueue<G> and PriorityQueue<G>.
namespace Gee {

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
