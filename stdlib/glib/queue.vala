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
        private GLib.RecMutex _mutex = new GLib.RecMutex ();
        private GLib.Cond _cond = new GLib.Cond ();

        public AsyncQueue () {}

        public void push (G data) {
            var node = new AsyncQueueNode<G> (data);
            _mutex.@lock ();
            if (tail != null)
                ((!) tail).next = node;
            else
                head = node;
            tail = node;
            _len++;
            _cond.signal ();
            _mutex.unlock ();
        }

        public G? try_pop () {
            _mutex.@lock ();
            if (head == null) {
                _mutex.unlock ();
                return null;
            }
            var n = (!) head;
            G val = n.data;
            head = n.next;
            if (head == null)
                tail = null;
            _len--;
            _mutex.unlock ();
            return val;
        }

        public G pop () {
            _mutex.@lock ();
            while (head == null)
                _cond.wait (_mutex);
            var n = (!) head;
            G val = n.data;
            head = n.next;
            if (head == null)
                tail = null;
            _len--;
            _mutex.unlock ();
            return val;
        }

        public int length () {
            _mutex.@lock ();
            int n = _len;
            _mutex.unlock ();
            return n;
        }
    }
}
