// Byte buffer with little-endian writers.
//
// Deliberately not GLib.ByteArray: this is the same type the self-hosted
// compiler will need, and nothing below depends on GLib beyond the language
// itself.

namespace Planc {

    public class Buffer : Object {

        private uint8[] storage;
        private int used = 0;

        public Buffer (int initial_capacity = 256) {
            storage = new uint8[initial_capacity];
        }

        public int length {
            get { return used; }
        }

        private void reserve (int extra) {
            if (used + extra <= storage.length)
                return;
            int grown = storage.length;
            while (grown < used + extra)
                grown *= 2;
            var bigger = new uint8[grown];
            for (int i = 0; i < used; i++)
                bigger[i] = storage[i];
            storage = bigger;
        }

        public void u8 (uint8 v) {
            reserve (1);
            storage[used++] = v;
        }

        public void u16le (uint16 v) {
            u8 ((uint8) (v & 0xff));
            u8 ((uint8) ((v >> 8) & 0xff));
        }

        public void u32le (uint32 v) {
            for (int i = 0; i < 4; i++)
                u8 ((uint8) ((v >> (8 * i)) & 0xff));
        }

        public void u64le (uint64 v) {
            for (int i = 0; i < 8; i++)
                u8 ((uint8) ((v >> (8 * i)) & 0xff));
        }

        public void bytes (uint8[] data) {
            reserve (data.length);
            for (int i = 0; i < data.length; i++)
                storage[used++] = data[i];
        }

        // Raw bytes of a UTF-8 string, without the terminating NUL.
        public void ascii (string s) {
            bytes (s.data);
        }

        public void zeroes (int count) {
            for (int i = 0; i < count; i++)
                u8 (0);
        }

        public void patch_u32le (int position, uint32 v) {
            if (position + 4 > used)
                error ("patch outside buffer: %d", position);
            for (int i = 0; i < 4; i++)
                storage[position + i] = (uint8) ((v >> (8 * i)) & 0xff);
        }

        public uint8[] to_array () {
            var copy = new uint8[used];
            for (int i = 0; i < used; i++)
                copy[i] = storage[i];
            return copy;
        }
    }
}
