// Pure-Vala GLib.AsyncQueue<G> for PlanetOS.
using Planet;

namespace GLib {

    internal class AsyncQueueNode<G> : Object {
        public G data;
        public AsyncQueueNode<G>? next = null;

        public AsyncQueueNode (G item) {
            data = item;
        }
    }

    /**
     * Thread-safe asynchronous queue (GLib.AsyncQueue).
     */
    public class AsyncQueue<G> : Object {
        private AsyncQueueNode<G>? head = null;
        private AsyncQueueNode<G>? tail = null;
        private int _len = 0;
        private int[] _lock = new int[1];

        public AsyncQueue () {}

        public void push (G data) {
            var node = new AsyncQueueNode<G> (data);
            __planc_host_spin_lock (_lock);
            if (tail != null)
                ((!) tail).next = node;
            else
                head = node;
            tail = node;
            _len++;
            __planc_host_spin_unlock (_lock);
        }

        public G? try_pop () {
            __planc_host_spin_lock (_lock);
            if (head == null) {
                __planc_host_spin_unlock (_lock);
                return null;
            }
            var n = (!) head;
            G val = n.data;
            head = n.next;
            if (head == null)
                tail = null;
            _len--;
            __planc_host_spin_unlock (_lock);
            return val;
        }

        public G pop () {
            while (true) {
                __planc_host_spin_lock (_lock);
                if (head != null) {
                    var n = (!) head;
                    G val = n.data;
                    head = n.next;
                    if (head == null)
                        tail = null;
                    _len--;
                    __planc_host_spin_unlock (_lock);
                    return val;
                }
                __planc_host_spin_unlock (_lock);
                Sys.yield_cpu ();
            }
        }

        public int length () {
            __planc_host_spin_lock (_lock);
            int n = _len;
            __planc_host_spin_unlock (_lock);
            return n;
        }
    }
}
