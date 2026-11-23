// Pure-Vala Gio InputStream/OutputStream hierarchy.
using GLib;
using Planet;

namespace Gio {

    [AsmBody(@"
        add $16, %rdi
        mov %rdi, %rax
        ret
    ")]
    private extern int __gio_arr_addr (uint8[] a);

    public class InputStream : Object {
        protected bool closed = false;
        protected bool pending = false;

        public virtual int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is already closed");
            return 0;
        }

        public virtual uint8[] read_bytes (int count, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is already closed");
            if (count <= 0)
                return new uint8[0];
            var buf = new uint8[count];
            int got = 0;
            if (!read_all (buf, out got, cancellable))
                return new uint8[0];
            if (got == count)
                return buf;
            var trimmed = new uint8[got];
            for (int i = 0; i < got; i++)
                trimmed[i] = buf[i];
            return trimmed;
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

        public bool has_pending () {
            return pending;
        }

        public bool set_pending () throws IOError {
            if (pending)
                throw new IOError.PENDING ("Stream has outstanding operation");
            pending = true;
            return true;
        }

        public void clear_pending () {
            pending = false;
        }
    }

    public class OutputStream : Object {
        protected bool closed = false;
        protected bool pending = false;

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

        public bool write_string (string str, out int bytes_written, Cancellable? cancellable = null) throws IOError {
            return write_all (str.data, out bytes_written, cancellable);
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

        public bool has_pending () {
            return pending;
        }

        public bool set_pending () throws IOError {
            if (pending)
                throw new IOError.FAILED ("Stream has outstanding operation");
            pending = true;
            return true;
        }

        public void clear_pending () {
            pending = false;
        }

        public virtual int splice (InputStream source, OutputStreamSpliceFlags flags = OutputStreamSpliceFlags.NONE, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is already closed");
            var buf = new uint8[4096];
            int total = 0;
            while (true) {
                int n = source.read (buf, cancellable);
                if (n <= 0)
                    break;
                if (n == buf.length) {
                    int w = 0;
                    if (!write_all (buf, out w, cancellable))
                        throw new IOError.FAILED ("Splice write failed");
                    total = total + w;
                } else {
                    var slice = new uint8[n];
                    for (int i = 0; i < n; i++)
                        slice[i] = buf[i];
                    int w = 0;
                    if (!write_all (slice, out w, cancellable))
                        throw new IOError.FAILED ("Splice write failed");
                    total = total + w;
                }
            }
            if ((flags & OutputStreamSpliceFlags.CLOSE_SOURCE) != 0)
                source.close (cancellable);
            if ((flags & OutputStreamSpliceFlags.CLOSE_TARGET) != 0)
                close (cancellable);
            return total;
        }
    }

    public class FilterInputStream : InputStream {
        protected InputStream base_stream;
        protected bool close_base_stream = true;

        protected FilterInputStream (InputStream base_stream) {
            this.base_stream = base_stream;
        }

        public InputStream get_base_stream () {
            return base_stream;
        }

        public bool get_close_base_stream () {
            return close_base_stream;
        }

        public void set_close_base_stream (bool close_base) {
            close_base_stream = close_base;
        }

        public override int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            return base_stream.read (buffer, cancellable);
        }

        public override int skip (int count, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            return base_stream.skip (count, cancellable);
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            closed = true;
            if (close_base_stream)
                return base_stream.close (cancellable);
            return true;
        }
    }

    public class FilterOutputStream : OutputStream {
        protected OutputStream base_stream;
        protected bool close_base_stream = true;

        protected FilterOutputStream (OutputStream base_stream) {
            this.base_stream = base_stream;
        }

        public OutputStream get_base_stream () {
            return base_stream;
        }

        public bool get_close_base_stream () {
            return close_base_stream;
        }

        public void set_close_base_stream (bool close_base) {
            close_base_stream = close_base;
        }

        public override int write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            return base_stream.write (buffer, cancellable);
        }

        public override bool flush (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            return base_stream.flush (cancellable);
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            closed = true;
            if (close_base_stream)
                return base_stream.close (cancellable);
            return true;
        }
    }

    public class FileInputStream : InputStream, Seekable {
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

        public bool can_seek () {
            return !closed && fd >= 0;
        }

        public bool can_truncate () {
            return false;
        }

        public bool truncate (int offset, Cancellable? cancellable = null) throws IOError {
            throw new IOError.NOT_SUPPORTED ("Cannot truncate input stream");
        }

        public FileInfo query_info (string attributes = "*", Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed || fd < 0)
                throw new IOError.CLOSED ("Stream is closed");
            int sz = Sys.file_size (fd);
            if (sz < 0)
                sz = 0;
            return new FileInfo ("", sz, FileType.REGULAR);
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

    public class FileOutputStream : OutputStream, Seekable {
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

        public bool can_seek () {
            return !closed && fd >= 0;
        }

        public bool can_truncate () {
            return false;
        }

        public bool truncate (int offset, Cancellable? cancellable = null) throws IOError {
            throw new IOError.NOT_SUPPORTED ("Truncate not supported");
        }

        public FileInfo query_info (string attributes = "*", Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed || fd < 0)
                throw new IOError.CLOSED ("Stream is closed");
            int sz = Sys.file_size (fd);
            if (sz < 0)
                sz = 0;
            return new FileInfo ("", sz, FileType.REGULAR);
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

    public class MemoryInputStream : InputStream, Seekable {
        private uint8[] data;
        private int used = 0;
        private int pos = 0;

        public MemoryInputStream () {
            data = new uint8[64];
        }

        [AsmBody(@"
            add $16, %rdi
            mov %rdi, %rax
            ret
        ")]
        private static extern int __mis_arr_addr (uint8[] a);

        public MemoryInputStream.from_data (uint8[] buf) {
            int cap = (buf.length > 64) ? buf.length : 64;
            data = new uint8[cap];
            if (buf.length > 0)
                Memory.copy (__mis_arr_addr (data), __mis_arr_addr (buf), (size_t) buf.length);
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
                if (used > 0)
                    Memory.copy (__mis_arr_addr (ndata), __mis_arr_addr (data), (size_t) used);
                data = ndata;
            }
            Memory.copy (__mis_arr_addr (data) + used, __mis_arr_addr (buf), (size_t) buf.length);
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
            if (n > 0)
                Memory.copy (__mis_arr_addr (buffer), __mis_arr_addr (data) + pos, (size_t) n);
            pos = pos + n;
            return n;
        }

        public int tell () {
            return pos;
        }

        public bool can_seek () {
            return !closed;
        }

        public bool can_truncate () {
            return false;
        }

        public bool truncate (int offset, Cancellable? cancellable = null) throws IOError {
            throw new IOError.NOT_SUPPORTED ("Cannot truncate MemoryInputStream");
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

    public class MemoryOutputStream : OutputStream, Seekable {
        private uint8[] data;
        private int used = 0;
        private int pos = 0;

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
            int end_pos = pos + buffer.length;
            if (end_pos > data.length) {
                int ncap = (data.length > 0) ? data.length * 2 : 64;
                while (ncap < end_pos)
                    ncap = ncap * 2;
                var ndata = new uint8[ncap];
                if (used > 0)
                    Memory.copy (__gio_arr_addr (ndata), __gio_arr_addr (data), (size_t) used);
                data = ndata;
            }
            Memory.copy (__gio_arr_addr (data) + pos, __gio_arr_addr (buffer), (size_t) buffer.length);
            pos = end_pos;
            if (pos > used)
                used = pos;
            return buffer.length;
        }

        public uint8[] get_data () {
            var res = new uint8[used];
            if (used > 0)
                Memory.copy (__gio_arr_addr (res), __gio_arr_addr (data), (size_t) used);
            return res;
        }

        public GLib.Bytes steal_as_bytes () {
            var res = get_data ();
            data = new uint8[64];
            used = 0;
            pos = 0;
            return new GLib.Bytes.take (res);
        }

        public uint8[] steal_data () {
            var res = get_data ();
            data = new uint8[64];
            used = 0;
            pos = 0;
            return res;
        }

        public int get_size () {
            return used;
        }

        public int get_data_size () {
            return used;
        }

        public int tell () {
            return pos;
        }

        public bool can_seek () {
            return !closed;
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

        public bool can_truncate () {
            return !closed;
        }

        public bool truncate (int offset, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            if (offset < 0)
                throw new IOError.INVALID_ARGUMENT ("Negative truncate offset");
            used = (offset < used) ? offset : used;
            if (pos > used)
                pos = used;
            return true;
        }
    }

    public class BufferedInputStream : FilterInputStream {
        protected uint8[] rbuf;
        protected int rpos = 0;
        protected int rlen = 0;
        protected int buf_size = 4096;

        public BufferedInputStream (InputStream base_stream) : base (base_stream) {
            this.rbuf = new uint8[4096];
        }

        public BufferedInputStream.sized (InputStream base_stream, int size) : base (base_stream) {
            int sz = (size > 0) ? size : 4096;
            this.buf_size = sz;
            this.rbuf = new uint8[sz];
        }

        public int get_buffer_size () {
            return buf_size;
        }

        public void set_buffer_size (int size) {
            if (size <= 0 || size == buf_size)
                return;
            int avail = rlen - rpos;
            int nsz = (avail > size) ? avail : size;
            var nbuf = new uint8[nsz];
            for (int i = 0; i < avail; i++)
                nbuf[i] = rbuf[rpos + i];
            rbuf = nbuf;
            rpos = 0;
            rlen = avail;
            buf_size = nsz;
        }

        public int get_available () {
            return rlen - rpos;
        }

        protected int refill (Cancellable? cancellable) throws IOError {
            if (rpos < rlen)
                return rlen - rpos;
            rpos = 0;
            rlen = base_stream.read (rbuf, cancellable);
            if (rlen < 0)
                rlen = 0;
            return rlen;
        }

        public int fill (int count, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            int avail = rlen - rpos;
            if (rpos > 0) {
                for (int i = 0; i < avail; i++)
                    rbuf[i] = rbuf[rpos + i];
                rpos = 0;
                rlen = avail;
            }
            int want = (count < 0 || count > buf_size - rlen) ? (buf_size - rlen) : count;
            if (want <= 0)
                return rlen;
            var tmp = new uint8[want];
            int n = base_stream.read (tmp, cancellable);
            if (n > 0) {
                for (int i = 0; i < n; i++)
                    rbuf[rlen + i] = tmp[i];
                rlen = rlen + n;
            }
            return rlen;
        }

        public int peek (uint8[] buffer, int offset = 0) throws IOError {
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            if (offset < 0 || offset >= rlen - rpos || buffer.length == 0)
                return 0;
            int avail = (rlen - rpos) - offset;
            int n = (buffer.length < avail) ? buffer.length : avail;
            for (int i = 0; i < n; i++)
                buffer[i] = rbuf[rpos + offset + i];
            return n;
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

        public int peek_byte () throws IOError {
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            if (rpos >= rlen)
                return -1;
            return (int) rbuf[rpos];
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            rpos = 0;
            rlen = 0;
            return base.close (cancellable);
        }
    }

    public class BufferedOutputStream : FilterOutputStream {
        private uint8[] wbuf;
        private int wpos = 0;
        private int buf_size = 4096;
        private bool auto_grow = false;

        public BufferedOutputStream (OutputStream base_stream) : base (base_stream) {
            this.wbuf = new uint8[4096];
        }

        public BufferedOutputStream.sized (OutputStream base_stream, int size) : base (base_stream) {
            int sz = (size > 0) ? size : 4096;
            this.buf_size = sz;
            this.wbuf = new uint8[sz];
        }

        public int get_buffer_size () {
            return buf_size;
        }

        public void set_buffer_size (int size) {
            if (size <= 0 || size == buf_size)
                return;
            if (wpos > size)
                size = wpos;
            var nbuf = new uint8[size];
            for (int i = 0; i < wpos; i++)
                nbuf[i] = wbuf[i];
            wbuf = nbuf;
            buf_size = size;
        }

        public bool get_auto_grow () {
            return auto_grow;
        }

        public void set_auto_grow (bool grow) {
            auto_grow = grow;
        }

        private void flush_buf (Cancellable? cancellable) throws IOError {
            if (wpos <= 0)
                return;
            var slice = new uint8[wpos];
            for (int i = 0; i < wpos; i++)
                slice[i] = wbuf[i];
            int written = 0;
            if (!base_stream.write_all (slice, out written, cancellable))
                throw new IOError.FAILED ("Buffered write failed");
            wpos = 0;
        }

        public override int write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            if (buffer.length == 0)
                return 0;
            if (wpos + buffer.length > buf_size) {
                if (auto_grow) {
                    int nsz = buf_size * 2;
                    while (nsz < wpos + buffer.length)
                        nsz = nsz * 2;
                    set_buffer_size (nsz);
                } else {
                    flush_buf (cancellable);
                    if (buffer.length >= buf_size) {
                        int w = 0;
                        if (!base_stream.write_all (buffer, out w, cancellable))
                            throw new IOError.FAILED ("Buffered write failed");
                        return w;
                    }
                }
            }
            Memory.copy (__gio_arr_addr (wbuf) + wpos, __gio_arr_addr (buffer), (size_t) buffer.length);
            wpos = wpos + buffer.length;
            return buffer.length;
        }

        public override bool flush (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            flush_buf (cancellable);
            return base_stream.flush (cancellable);
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            if (!closed)
                flush_buf (cancellable);
            return base.close (cancellable);
        }
    }

    public class DataInputStream : BufferedInputStream {
        private DataStreamByteOrder byte_order = DataStreamByteOrder.BIG_ENDIAN;
        private DataStreamNewlineType newline_type = DataStreamNewlineType.LF;

        public DataInputStream (InputStream base_stream) : base (base_stream) {
        }

        public DataStreamByteOrder get_byte_order () {
            return byte_order;
        }

        public void set_byte_order (DataStreamByteOrder order) {
            byte_order = order;
        }

        public DataStreamNewlineType get_newline_type () {
            return newline_type;
        }

        public void set_newline_type (DataStreamNewlineType type) {
            newline_type = type;
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

        private bool is_little_endian () {
            return byte_order == DataStreamByteOrder.LITTLE_ENDIAN
                || byte_order == DataStreamByteOrder.HOST_ENDIAN;
        }

        public uint16 read_uint16 (Cancellable? cancellable = null) throws IOError {
            uint16 b0 = (uint16) read_byte (cancellable);
            uint16 b1 = (uint16) read_byte (cancellable);
            if (is_little_endian ())
                return b0 | (b1 << 8);
            return (b0 << 8) | b1;
        }

        public int16 read_int16 (Cancellable? cancellable = null) throws IOError {
            return (int16) read_uint16 (cancellable);
        }

        public uint32 read_uint32 (Cancellable? cancellable = null) throws IOError {
            uint32 b0 = (uint32) read_byte (cancellable);
            uint32 b1 = (uint32) read_byte (cancellable);
            uint32 b2 = (uint32) read_byte (cancellable);
            uint32 b3 = (uint32) read_byte (cancellable);
            if (is_little_endian ())
                return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
        }

        public int32 read_int32 (Cancellable? cancellable = null) throws IOError {
            return (int32) read_uint32 (cancellable);
        }

        public uint64 read_uint64 (Cancellable? cancellable = null) throws IOError {
            uint64 lo = (uint64) read_uint32 (cancellable);
            uint64 hi = (uint64) read_uint32 (cancellable);
            if (is_little_endian ())
                return lo | (hi << 32);
            return (lo << 32) | hi;
        }

        public int64 read_int64 (Cancellable? cancellable = null) throws IOError {
            return (int64) read_uint64 (cancellable);
        }

        public string? read_upto (string stop_chars, int stop_chars_len, out int length, Cancellable? cancellable = null) throws IOError {
            length = 0;
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            int slen = (stop_chars_len < 0) ? stop_chars.length : stop_chars_len;
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
                bool stop = false;
                for (int i = 0; i < slen; i++) {
                    if (stop_chars[i] == ch) {
                        stop = true;
                        break;
                    }
                }
                if (stop)
                    break;
                rpos = rpos + 1;
                if (used >= cap) {
                    if (cap >= 16777216)
                        throw new IOError.FAILED ("Line or token exceeds maximum buffer size");
                    int ncap = cap * 2;
                    var nbuf = new uint8[ncap];
                    if (used > 0)
                        Memory.copy (__gio_arr_addr (nbuf), __gio_arr_addr (buf), (size_t) used);
                    buf = nbuf;
                    cap = ncap;
                }
                buf[used] = ch;
                used = used + 1;
            }
            length = used;
            return __planc_host_bytes_to_str (buf, used);
        }

        public string? read_until (string stop_chars, out int length, Cancellable? cancellable = null) throws IOError {
            string? res = read_upto (stop_chars, stop_chars.length, out length, cancellable);
            if (res != null && rpos < rlen)
                rpos = rpos + 1;
            return res;
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
                if (ch == '\n') {
                    if (newline_type == DataStreamNewlineType.CR) {
                        // In CR-only mode, '\n' is part of the line.
                    } else {
                        break;
                    }
                } else if (ch == '\r') {
                    if (newline_type == DataStreamNewlineType.CR)
                        break;
                    if (newline_type == DataStreamNewlineType.CR_LF || newline_type == DataStreamNewlineType.ANY) {
                        if (refill (cancellable) > 0 && rbuf[rpos] == '\n')
                            rpos = rpos + 1;
                        break;
                    }
                    continue;
                }
                if (used >= cap) {
                    if (cap >= 16777216)
                        throw new IOError.FAILED ("Line or token exceeds maximum buffer size");
                    int ncap = cap * 2;
                    var nbuf = new uint8[ncap];
                    if (used > 0)
                        Memory.copy (__gio_arr_addr (nbuf), __gio_arr_addr (buf), (size_t) used);
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

    public class DataOutputStream : FilterOutputStream {
        private DataStreamByteOrder byte_order = DataStreamByteOrder.BIG_ENDIAN;

        public DataOutputStream (OutputStream base_stream) : base (base_stream) {
        }

        public DataStreamByteOrder get_byte_order () {
            return byte_order;
        }

        public void set_byte_order (DataStreamByteOrder order) {
            byte_order = order;
        }

        private bool is_little_endian () {
            return byte_order == DataStreamByteOrder.LITTLE_ENDIAN
                || byte_order == DataStreamByteOrder.HOST_ENDIAN;
        }

        public bool put_byte (uint8 data, Cancellable? cancellable = null) throws IOError {
            var b = new uint8[1];
            b[0] = data;
            int n = base_stream.write (b, cancellable);
            return n == 1;
        }

        public bool put_uint16 (uint16 data, Cancellable? cancellable = null) throws IOError {
            var b = new uint8[2];
            if (is_little_endian ()) {
                b[0] = (uint8) (data & 0xff);
                b[1] = (uint8) ((data >> 8) & 0xff);
            } else {
                b[0] = (uint8) ((data >> 8) & 0xff);
                b[1] = (uint8) (data & 0xff);
            }
            int w = 0;
            return base_stream.write_all (b, out w, cancellable);
        }

        public bool put_int16 (int16 data, Cancellable? cancellable = null) throws IOError {
            return put_uint16 ((uint16) data, cancellable);
        }

        public bool put_uint32 (uint32 data, Cancellable? cancellable = null) throws IOError {
            var b = new uint8[4];
            if (is_little_endian ()) {
                b[0] = (uint8) (data & 0xff);
                b[1] = (uint8) ((data >> 8) & 0xff);
                b[2] = (uint8) ((data >> 16) & 0xff);
                b[3] = (uint8) ((data >> 24) & 0xff);
            } else {
                b[0] = (uint8) ((data >> 24) & 0xff);
                b[1] = (uint8) ((data >> 16) & 0xff);
                b[2] = (uint8) ((data >> 8) & 0xff);
                b[3] = (uint8) (data & 0xff);
            }
            int w = 0;
            return base_stream.write_all (b, out w, cancellable);
        }

        public bool put_int32 (int32 data, Cancellable? cancellable = null) throws IOError {
            return put_uint32 ((uint32) data, cancellable);
        }

        public bool put_uint64 (uint64 data, Cancellable? cancellable = null) throws IOError {
            var b = new uint8[8];
            if (is_little_endian ()) {
                for (int i = 0; i < 8; i++)
                    b[i] = (uint8) ((data >> (i * 8)) & 0xff);
            } else {
                for (int i = 0; i < 8; i++)
                    b[i] = (uint8) ((data >> ((7 - i) * 8)) & 0xff);
            }
            int w = 0;
            return base_stream.write_all (b, out w, cancellable);
        }

        public bool put_int64 (int64 data, Cancellable? cancellable = null) throws IOError {
            return put_uint64 ((uint64) data, cancellable);
        }

        public bool put_string (string str, Cancellable? cancellable = null) throws IOError {
            if (str.length == 0)
                return true;
            int w = 0;
            return base_stream.write_all (str.data, out w, cancellable);
        }
    }

}
