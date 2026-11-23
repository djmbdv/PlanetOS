// Pure-Vala GLib.Thread (valadoc.org/glib-2.0/GLib.Thread.html), Mutex, and Cond.
using Planet;
using GLib;

private void _c_glib_thread_trampoline (int slot) {
    _ThreadSlots.trampoline (slot);
}

namespace GLib {

    public errordomain ThreadError {
        AGAIN
    }

    public delegate uint8[]? ThreadFunc ();
    public delegate uint8[] PthreadFunc (uint8[] arg);
    public delegate void _ThreadEntry (int slot);

    public class _ThreadBase : Object {
        public virtual void _run_slot () {}
    }

    public class _ThreadSlots : Object {
        private static _ThreadBase[] _slots;
        private static bool[] _used;
        private static int[] _lock;

        private static void ensure_init () {
            if (_slots == null) {
                _slots = new _ThreadBase[256];
                _used = new bool[256];
                _lock = new int[1];
            }
        }

        public static int alloc (_ThreadBase t) {
            ensure_init ();
            __planc_host_spin_lock (_lock);
            int chosen = -1;
            for (int i = 0; i < _used.length; i++) {
                if (!_used[i]) {
                    _used[i] = true;
                    _slots[i] = t;
                    chosen = i;
                    break;
                }
            }
            __planc_host_spin_unlock (_lock);
            return chosen;
        }

        public static void trampoline (int slot) {
            _ThreadBase? t = null;
            __planc_host_spin_lock (_lock);
            if (_used != null && slot >= 0 && slot < _used.length && _used[slot]) {
                t = _slots[slot];
                _used[slot] = false;
            }
            __planc_host_spin_unlock (_lock);
            if (t != null)
                ((!) t)._run_slot ();
        }
    }

    private void _glib_thread_trampoline (int slot) {
        _ThreadSlots.trampoline (slot);
    }

    public class Thread : _ThreadBase {
        private string? _name = null;
        private ThreadFunc? _func = null;
        private PthreadFunc? _pfunc = null;
        private uint8[] _parg = new uint8[0];
        private uint8[]? _result = null;
        private int64 _handle = 0;
        private bool _joined = false;
        private bool _has_thread = false;

        public Thread (string? name, ThreadFunc func) {
            _name = name;
            _func = func;
            start_slot ();
        }

        private static int64 _spawn_entry (_ThreadEntry fn, int slot) {
            return __planc_host_thread_spawn (fn, slot);
        }

        public Thread.try_new (string? name, ThreadFunc func) throws ThreadError {
            _name = name;
            _func = func;
            int slot = _ThreadSlots.alloc (this);
            if (slot < 0)
                throw new ThreadError.AGAIN ("No free thread slots");
            _handle = _spawn_entry (_c_glib_thread_trampoline, slot);
            _has_thread = true;
        }

        public Thread.with_arg (string? name, PthreadFunc func, uint8[] arg) {
            _name = name;
            _pfunc = func;
            _parg = arg;
            start_slot ();
        }

        private void start_slot () {
            int slot = _ThreadSlots.alloc (this);
            if (slot >= 0) {
                _handle = _spawn_entry (_c_glib_thread_trampoline, slot);
                _has_thread = true;
            } else {
                _run_slot ();
                _joined = true;
            }
        }

        public override void _run_slot () {
            if (_func != null)
                _result = ((!) _func) ();
            else if (_pfunc != null)
                _result = ((!) _pfunc) (_parg);
        }

        public uint8[]? join () {
            if (_has_thread && !_joined) {
                __planc_host_thread_join (_handle);
                _joined = true;
            }
            return _result;
        }

        public string? get_name () {
            return _name;
        }

        public static bool supported () {
            return true;
        }

        public static void yield_ () {
            Sys.yield_cpu ();
        }
    }

    [AsmBody(@"
        # __thread_trylock(lock_arr in rdi) -> al (bool)
        xor %eax, %eax
        mov $1, %edx
        .byte 0xf0, 0x0f, 0xb1, 0x57, 0x10
        .byte 0x0f, 0x94, 0xc0
        movzbl %al, %eax
        ret
    ")]
    private extern bool __thread_trylock (int[] lock_arr);

    public class RecMutex : Object {
        private int[] _lock = new int[1];

        public RecMutex () {
        }

        public void @lock () {
            __planc_host_spin_lock (_lock);
        }

        public bool trylock () {
            return __thread_trylock (_lock);
        }

        public void unlock () {
            __planc_host_spin_unlock (_lock);
        }
    }

    public class Cond : Object {
        private int _seq = 0;

        public Cond () {
        }

        public void wait (RecMutex mutex) {
            int seen = _seq;
            mutex.unlock ();
            while (_seq == seen)
                Sys.yield_cpu ();
            mutex.@lock ();
        }

        public bool wait_until (RecMutex mutex, int64 end_time) {
            int seen = _seq;
            mutex.unlock ();
            while (_seq == seen) {
                int64 now_us = (int64) Sys.ticks () * 10000;
                if (now_us >= end_time) {
                    mutex.@lock ();
                    return false;
                }
                Sys.yield_cpu ();
            }
            mutex.@lock ();
            return true;
        }

        public void signal () {
            _seq = _seq + 1;
        }

        public void broadcast () {
            _seq = _seq + 1;
        }
    }

    public class Mutex : Object {
        private int[] _lock = new int[1];

        public Mutex () {
        }

        public void @lock () {
            __planc_host_spin_lock (_lock);
        }

        public bool trylock () {
            return __thread_trylock (_lock);
        }

        public void unlock () {
            __planc_host_spin_unlock (_lock);
        }
    }

    public class RWLock : Object {
        private int[] _guard = new int[1];
        private int _readers = 0;
        private int _writers_waiting = 0;
        private bool _writer = false;

        public RWLock () {
        }

        public void reader_lock () {
            while (true) {
                __planc_host_spin_lock (_guard);
                if (!_writer && _writers_waiting == 0) {
                    _readers++;
                    __planc_host_spin_unlock (_guard);
                    return;
                }
                __planc_host_spin_unlock (_guard);
                Sys.yield_cpu ();
            }
        }

        public bool reader_trylock () {
            __planc_host_spin_lock (_guard);
            bool ok = (!_writer && _writers_waiting == 0);
            if (ok)
                _readers++;
            __planc_host_spin_unlock (_guard);
            return ok;
        }

        public void reader_unlock () {
            __planc_host_spin_lock (_guard);
            if (_readers > 0)
                _readers--;
            __planc_host_spin_unlock (_guard);
        }

        public void writer_lock () {
            __planc_host_spin_lock (_guard);
            _writers_waiting++;
            while (_writer || _readers > 0) {
                __planc_host_spin_unlock (_guard);
                Sys.yield_cpu ();
                __planc_host_spin_lock (_guard);
            }
            _writers_waiting--;
            _writer = true;
            __planc_host_spin_unlock (_guard);
        }

        public bool writer_trylock () {
            __planc_host_spin_lock (_guard);
            bool ok = (!_writer && _readers == 0);
            if (ok)
                _writer = true;
            __planc_host_spin_unlock (_guard);
            return ok;
        }

        public void writer_unlock () {
            __planc_host_spin_lock (_guard);
            _writer = false;
            __planc_host_spin_unlock (_guard);
        }
    }
}
