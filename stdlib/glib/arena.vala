// Safe region allocator ("arena") for planc code.
//
// A raw bump allocator hands out pointers that can outlive the arena, which is
// exactly the kind of dangling reference planc tries to make impossible. This
// region never exposes a pointer: callers get an ArenaHandle (offset + length +
// generation) and every access is validated against the arena first. reset()
// bumps the generation, so a stale handle is rejected instead of reading
// recycled bytes.
//
// The API is total: an invalid handle never touches memory, it makes the call a
// no-op and increments `rejected`. Callers that want hard failure can assert on
// `rejected` after a batch of operations.
namespace GLib {

    public struct ArenaHandle {
        public int offset;
        public int length;
        public uint32 generation;
    }

    public class Arena : Object {
        private uint8[] store;
        private int cursor;
        private uint32 gen;
        private int failures;

        public Arena (int capacity = 4096) {
            if (capacity <= 0)
                capacity = 1;
            store = new uint8[capacity];
            cursor = 0;
            gen = 1;
        }

        public int capacity {
            get { return store.length; }
        }

        public int used {
            get { return cursor; }
        }

        public uint32 generation {
            get { return gen; }
        }

        // Number of rejected operations, so a caller can fail loudly on its own
        // terms instead of inheriting an allocator panic.
        public int rejected {
            get { return failures; }
        }

        public void reset () {
            cursor = 0;
            gen++;
        }

        // Reserves n bytes. A negative or oversized request is refused (an
        // offset 0, length 0, generation 0 handle) instead of wrapping.
        public ArenaHandle alloc (int n) {
            if (n < 0 || n > store.length - cursor) {
                failures++;
                return ArenaHandle ();
            }
            var h = ArenaHandle () {
                offset = cursor,
                length = n,
                generation = gen
            };
            cursor += n;
            return h;
        }

        public bool valid (ArenaHandle h) {
            if (h.generation != gen)
                return false;
            if (h.offset < 0 || h.length < 0)
                return false;
            if (h.offset > store.length || h.length > store.length - h.offset)
                return false;
            return true;
        }

        public uint8 get (ArenaHandle h, int i) {
            if (!valid (h) || i < 0 || i >= h.length) {
                failures++;
                return 0;
            }
            return store[h.offset + i];
        }

        public void set (ArenaHandle h, int i, uint8 v) {
            if (!valid (h) || i < 0 || i >= h.length) {
                failures++;
                return;
            }
            store[h.offset + i] = v;
        }

        public int get_int (ArenaHandle h, int index) {
            int pos = index * 4;
            if (!valid (h) || pos < 0 || pos + 4 > h.length) {
                failures++;
                return 0;
            }
            uint32 v = 0;
            for (int k = 0; k < 4; k++)
                v |= ((uint32) store[h.offset + pos + k]) << (8 * k);
            return (int) v;
        }

        public void set_int (ArenaHandle h, int index, int value) {
            int pos = index * 4;
            if (!valid (h) || pos < 0 || pos + 4 > h.length) {
                failures++;
                return;
            }
            uint32 v = (uint32) value;
            for (int k = 0; k < 4; k++)
                store[h.offset + pos + k] = (uint8) ((v >> (8 * k)) & 0xFF);
        }

        // The only way bytes leave the arena: an owned copy.
        public uint8[] copy_out (ArenaHandle h) {
            if (!valid (h)) {
                failures++;
                return new uint8[0];
            }
            uint8[] out_b = new uint8[h.length];
            for (int i = 0; i < h.length; i++)
                out_b[i] = store[h.offset + i];
            return out_b;
        }
    }
}