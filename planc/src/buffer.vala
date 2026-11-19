// Byte buffer, string builder, and shared host formatting utilities.
//
// Deliberately avoids GLib classes so the compiler builds cleanly both in
// Stage 0 (valac + host_stage0) and Stages 1-3 (planc + host_native).

namespace Planc {

    public errordomain FileError {
        FAILED
    }

    public sealed class StrBuilder : Object {

        private uint8[] buf;
        private int used = 0;

        public StrBuilder (string init = "") {
            buf = new uint8[64];
            if (init != "")
                append (init);
        }

        public int length {
            get { return used; }
        }

        public void truncate (int new_len) {
            if (new_len >= 0 && new_len <= used)
                used = new_len;
        }

        public string str {
            owned get { return Host.bytes_to_string (buf, used); }
        }

        private void ensure (int extra) {
            if (used + extra <= buf.length)
                return;
            int cap = buf.length;
            while (cap < used + extra)
                cap = cap * 2;
            var bigger = new uint8[cap];
            for (int i = 0; i < used; i++)
                bigger[i] = buf[i];
            buf = bigger;
        }

        public void append (string s) {
            var slen = s.length;
            if (slen == 0)
                return;
            ensure (slen);
            for (int i = 0; i < slen; i++) {
                buf[used] = s[i];
                used++;
            }
        }

        public void append_c (char c) {
            ensure (1);
            buf[used] = (uint8) c;
            used++;
        }
    }

    public sealed class Buffer : Object {

        private uint8[] storage;
        private int used = 0;

        public Buffer (int initial_capacity = 256) {
            storage = new uint8[initial_capacity];
        }

        public int length {
            get { return used; }
        }

        public void truncate (int new_len) {
            if (new_len >= 0 && new_len <= used)
                used = new_len;
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
            var slen = s.length;
            reserve (slen);
            for (int i = 0; i < slen; i++) {
                storage[used] = s[i];
                used++;
            }
        }

        public void zeroes (int count) {
            for (int i = 0; i < count; i++)
                u8 (0);
        }

        public void patch_u32le (int position, uint32 v) {
            if (position + 4 > used) {
                Host.panic (@"patch outside buffer: $position");
                return;
            }
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
