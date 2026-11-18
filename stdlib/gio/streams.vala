// Pure-Vala Gio InputStream/OutputStream hierarchy.
using GLib;
using Planet;

namespace Gio {

    public class InputStream : Object {
        protected bool closed = false;

        public virtual int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is already closed");
            return 0;
        }

        public virtual bool read_all (uint8[] buffer, out int bytes_read, Cancellable? cancellable = null) throws IOError {
            bytes_read = 0;
            if (buffer.length == 0) {
                if (cancellable != null && cancellable.is_cancelled ())
                    throw new IOError.CANCELLED ("Operation was cancelled");
                if (closed)
                    throw new IOError.CLOSED ("Stream is already closed");
                return true;
            }
            int first = read (buffer, cancellable);
            if (first <= 0)
                return true;
            bytes_read = first;
            while (bytes_read < buffer.length) {
                int rem = buffer.length - bytes_read;
                var slice = new uint8[rem];
                int n = read (slice, cancellable);
                if (n <= 0)
                    break;
                for (int i = 0; i < n; i++)
                    buffer[bytes_read + i] = slice[i];
                bytes_read = bytes_read + n;
            }
            return true;
        }

        public virtual int skip (int count, Cancellable? cancellable = null) throws IOError {
            if (count <= 0) {
                if (cancellable != null && cancellable.is_cancelled ())
                    throw new IOError.CANCELLED ("Operation was cancelled");
                if (closed)
                    throw new IOError.CLOSED ("Stream is already closed");
                return 0;
            }
            int skipped = 0;
            int chunk_sz = (count < 4096) ? count : 4096;
            var tmp = new uint8[chunk_sz];
            while (skipped < count) {
                int rem = count - skipped;
                if (rem < chunk_sz)
                    tmp = new uint8[rem];
                int n = read (tmp, cancellable);
                if (n <= 0)
                    break;
                skipped = skipped + n;
            }
            return skipped;
        }

        public virtual bool close (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            closed = true;
            return true;
        }

        public bool is_closed () {
            return closed;
        }
    }

    public class OutputStream : Object {
        protected bool closed = false;

        public virtual int write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is already closed");
            return 0;
        }

        public virtual bool write_all (uint8[] buffer, out int bytes_written, Cancellable? cancellable = null) throws IOError {
            bytes_written = 0;
            if (buffer.length == 0) {
                if (cancellable != null && cancellable.is_cancelled ())
                    throw new IOError.CANCELLED ("Operation was cancelled");
                if (closed)
                    throw new IOError.CLOSED ("Stream is already closed");
                return true;
            }
            int first = write (buffer, cancellable);
            if (first <= 0)
                return false;
            bytes_written = first;
            while (bytes_written < buffer.length) {
                int rem = buffer.length - bytes_written;
                var slice = new uint8[rem];
                for (int i = 0; i < rem; i++)
                    slice[i] = buffer[bytes_written + i];
                int n = write (slice, cancellable);
                if (n <= 0)
                    break;
                bytes_written = bytes_written + n;
            }
            return bytes_written == buffer.length;
        }

        public virtual bool flush (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is already closed");
            return true;
        }

        public virtual bool close (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            closed = true;
            return true;
        }

        public bool is_closed () {
            return closed;
        }
    }

    public class FileInputStream : InputStream {
        private int fd;
        private int pos = 0;

        public FileInputStream (int fd) {
            this.fd = fd;
        }

        ~FileInputStream () {
            if (!closed && fd >= 0) {
                Sys.close (fd);
                fd = -1;
                closed = true;
            }
        }

        public override int skip (int count, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed || fd < 0)
                throw new IOError.CLOSED ("Stream is closed");
            if (count <= 0)
                return 0;
            int sz = Sys.file_size (fd);
            int target = pos + count;
            if (sz >= 0 && target > sz)
                target = sz;
            int old_pos = pos;
            int res = Sys.seek (fd, target);
            if (res < 0)
                throw new IOError.FAILED ("Skip failed");
            pos = res;
            return (pos > old_pos) ? (pos - old_pos) : 0;
        }

        public override int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed || fd < 0)
                throw new IOError.CLOSED ("Stream is closed");
            if (buffer.length == 0)
                return 0;
            int n = Sys.read (fd, buffer, buffer.length);
            if (n < 0)
                throw new IOError.FAILED ("Read failed");
            pos = pos + n;
            return n;
        }

        public int tell () {
            return pos;
        }

        public bool seek (int offset, SeekType type, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed || fd < 0)
                throw new IOError.CLOSED ("Stream is closed");
            int target = offset;
            if (type == SeekType.CUR) {
                target = pos + offset;
            } else if (type == SeekType.END) {
                int sz = Sys.file_size (fd);
                if (sz < 0)
                    sz = 0;
                target = sz + offset;
            }
            if (target < 0)
                throw new IOError.INVALID_ARGUMENT ("Negative seek offset");
            int res = Sys.seek (fd, target);
            if (res < 0)
                throw new IOError.FAILED ("Seek failed");
            pos = res;
            return true;
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            if (!closed && fd >= 0) {
                Sys.close (fd);
                fd = -1;
            }
            closed = true;
            return true;
        }
    }

    public class FileOutputStream : OutputStream {
        private int fd;
        private int pos = 0;

        public FileOutputStream (int fd, int initial_pos = 0) {
            this.fd = fd;
            this.pos = initial_pos;
        }

        ~FileOutputStream () {
            if (!closed && fd >= 0) {
                Sys.close (fd);
                fd = -1;
                closed = true;
            }
        }

        public override int write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed || fd < 0)
                throw new IOError.CLOSED ("Stream is closed");
            if (buffer.length == 0)
                return 0;
            int n = Sys.write (fd, buffer, buffer.length);
            if (n < 0)
                throw new IOError.FAILED ("Write failed");
            pos = pos + n;
            return n;
        }

        public int tell () {
            return pos;
        }

        public bool seek (int offset, SeekType type, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed || fd < 0)
                throw new IOError.CLOSED ("Stream is closed");
            int target = offset;
            if (type == SeekType.CUR) {
                target = pos + offset;
            } else if (type == SeekType.END) {
                int sz = Sys.file_size (fd);
                if (sz < 0)
                    sz = 0;
                target = sz + offset;
            }
            if (target < 0)
                throw new IOError.INVALID_ARGUMENT ("Negative seek offset");
            int res = Sys.seek (fd, target);
            if (res < 0)
                throw new IOError.FAILED ("Seek failed");
            pos = res;
            return true;
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            if (!closed && fd >= 0) {
                Sys.close (fd);
                fd = -1;
            }
            closed = true;
            return true;
        }
    }

    public class MemoryInputStream : InputStream {
        private uint8[] data;
        private int used = 0;
        private int pos = 0;

        public MemoryInputStream () {
            data = new uint8[64];
        }

        public MemoryInputStream.from_data (uint8[] buf) {
            int cap = (buf.length > 64) ? buf.length : 64;
            data = new uint8[cap];
            for (int i = 0; i < buf.length; i++)
                data[i] = buf[i];
            used = buf.length;
        }

        public void add_data (uint8[] buf) {
            if (buf.length == 0)
                return;
            if (used + buf.length > data.length) {
                int ncap = (data.length > 0) ? data.length * 2 : 64;
                while (ncap < used + buf.length)
                    ncap = ncap * 2;
                var ndata = new uint8[ncap];
                for (int i = 0; i < used; i++)
                    ndata[i] = data[i];
                data = ndata;
            }
            for (int i = 0; i < buf.length; i++)
                data[used + i] = buf[i];
            used = used + buf.length;
        }

        public override int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            int avail = used - pos;
            if (avail <= 0 || buffer.length == 0)
                return 0;
            int n = (buffer.length < avail) ? buffer.length : avail;
            for (int i = 0; i < n; i++)
                buffer[i] = data[pos + i];
            pos = pos + n;
            return n;
        }

        public int tell () {
            return pos;
        }

        public bool seek (int offset, SeekType type, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            int target = offset;
            if (type == SeekType.CUR)
                target = pos + offset;
            else if (type == SeekType.END)
                target = used + offset;
            if (target < 0)
                throw new IOError.INVALID_ARGUMENT ("Negative seek offset");
            pos = (target <= used) ? target : used;
            return true;
        }
    }

    public class MemoryOutputStream : OutputStream {
        private uint8[] data;
        private int used = 0;

        public MemoryOutputStream () {
            data = new uint8[64];
        }

        public override int write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            if (buffer.length == 0)
                return 0;
            if (used + buffer.length > data.length) {
                int ncap = (data.length > 0) ? data.length * 2 : 64;
                while (ncap < used + buffer.length)
                    ncap = ncap * 2;
                var ndata = new uint8[ncap];
                for (int i = 0; i < used; i++)
                    ndata[i] = data[i];
                data = ndata;
            }
            for (int i = 0; i < buffer.length; i++)
                data[used + i] = buffer[i];
            used = used + buffer.length;
            return buffer.length;
        }

        public uint8[] get_data () {
            var res = new uint8[used];
            for (int i = 0; i < used; i++)
                res[i] = data[i];
            return res;
        }

        public int get_data_size () {
            return used;
        }
    }

    public class DataInputStream : InputStream {
        private InputStream base_stream;
        private uint8[] rbuf;
        private int rpos = 0;
        private int rlen = 0;

        public DataInputStream (InputStream base_stream) {
            this.base_stream = base_stream;
            this.rbuf = new uint8[512];
        }

        private int refill (Cancellable? cancellable) throws IOError {
            if (rpos < rlen)
                return rlen - rpos;
            rpos = 0;
            rlen = base_stream.read (rbuf, cancellable);
            if (rlen < 0)
                rlen = 0;
            return rlen;
        }

        public override int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            if (buffer.length == 0)
                return 0;
            if (rpos < rlen) {
                int avail = rlen - rpos;
                int n = (buffer.length < avail) ? buffer.length : avail;
                for (int i = 0; i < n; i++)
                    buffer[i] = rbuf[rpos + i];
                rpos = rpos + n;
                return n;
            }
            return base_stream.read (buffer, cancellable);
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            closed = true;
            rpos = 0;
            rlen = 0;
            return base_stream.close (cancellable);
        }

        public uint8 read_byte (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            if (refill (cancellable) <= 0)
                throw new IOError.FAILED ("End of stream");
            uint8 b = rbuf[rpos];
            rpos = rpos + 1;
            return b;
        }

        public string? read_line (out int length, Cancellable? cancellable = null) throws IOError {
            length = 0;
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            var buf = new uint8[256];
            int cap = 256;
            int used = 0;
            while (true) {
                if (refill (cancellable) <= 0) {
                    if (used == 0)
                        return null;
                    break;
                }
                uint8 ch = rbuf[rpos];
                rpos = rpos + 1;
                if (ch == '\n')
                    break;
                if (ch == '\r')
                    continue;
                if (used >= cap) {
                    int ncap = cap * 2;
                    var nbuf = new uint8[ncap];
                    for (int i = 0; i < used; i++)
                        nbuf[i] = buf[i];
                    buf = nbuf;
                    cap = ncap;
                }
                buf[used] = ch;
                used = used + 1;
            }
            length = used;
            return __planc_host_bytes_to_str (buf, used);
        }
    }

    public class DataOutputStream : OutputStream {
        private OutputStream base_stream;

        public DataOutputStream (OutputStream base_stream) {
            this.base_stream = base_stream;
        }

        public override int write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            return base_stream.write (buffer, cancellable);
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            closed = true;
            return base_stream.close (cancellable);
        }

        public bool put_byte (uint8 data, Cancellable? cancellable = null) throws IOError {
            var b = new uint8[1];
            b[0] = data;
            int n = base_stream.write (b, cancellable);
            return n == 1;
        }

        public bool put_string (string str, Cancellable? cancellable = null) throws IOError {
            if (str.length == 0)
                return true;
            var b = new uint8[str.length];
            for (int i = 0; i < str.length; i++)
                b[i] = str[i];
            int n = base_stream.write (b, cancellable);
            return n == str.length;
        }
    }

}
