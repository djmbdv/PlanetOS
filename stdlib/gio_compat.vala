// Pure-Vala Gio compatibility layer for PlanetOS (zero C, zero .vapi).
// Implements File, FileInfo, FileEnumerator, InputStream, OutputStream,
// FileInputStream, FileOutputStream, MemoryInputStream, MemoryOutputStream,
// DataInputStream, DataOutputStream, Cancellable, IOError, and Application.

using Planet;

namespace Gio {

    public errordomain IOError {
        FAILED,
        NOT_FOUND,
        EXISTS,
        INVALID_ARGUMENT,
        NOT_SUPPORTED,
        CANCELLED,
        CLOSED
    }

    public enum FileType {
        UNKNOWN,
        REGULAR,
        DIRECTORY,
        SYMBOLIC_LINK,
        SPECIAL,
        SHORTCUT,
        MOUNTABLE
    }

    public enum FileQueryInfoFlags {
        NONE,
        NOFOLLOW_SYMLINKS
    }

    public enum FileCreateFlags {
        NONE,
        PRIVATE,
        REPLACE_DESTINATION
    }

    public enum FileCopyFlags {
        NONE,
        OVERWRITE,
        BACKUP,
        ALL_METADATA
    }

    public enum SeekType {
        CUR,
        SET,
        END
    }

    public enum ApplicationFlags {
        FLAGS_NONE,
        HANDLES_OPEN,
        NON_UNIQUE
    }

    public class Cancellable : Object {
        private bool cancelled = false;

        public Cancellable () {}

        public bool is_cancelled () {
            return cancelled;
        }

        public void cancel () {
            cancelled = true;
        }

        public void reset () {
            cancelled = false;
        }

        public bool set_error_if_cancelled () throws IOError {
            if (cancelled)
                throw new IOError.CANCELLED ("Operation was cancelled");
            return false;
        }
    }

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
            if (buffer.length == 0)
                return true;
            var tmp = new uint8[buffer.length];
            while (bytes_read < buffer.length) {
                int rem = buffer.length - bytes_read;
                var slice = new uint8[rem];
                int n = read (slice, cancellable);
                if (n <= 0)
                    break;
                for (int i = 0; i < n; i++) {
                    buffer[bytes_read + i] = slice[i];
                }
                bytes_read = bytes_read + n;
            }
            return true;
        }

        public virtual int skip (int count, Cancellable? cancellable = null) throws IOError {
            if (count <= 0)
                return 0;
            var tmp = new uint8[count];
            return read (tmp, cancellable);
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
            if (buffer.length == 0)
                return true;
            int n = write (buffer, cancellable);
            if (n > 0)
                bytes_written = n;
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

        public DataInputStream (InputStream base_stream) {
            this.base_stream = base_stream;
        }

        public override int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            return base_stream.read (buffer, cancellable);
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            closed = true;
            return base_stream.close (cancellable);
        }

        public uint8 read_byte (Cancellable? cancellable = null) throws IOError {
            var b = new uint8[1];
            int n = base_stream.read (b, cancellable);
            if (n <= 0)
                throw new IOError.FAILED ("End of stream");
            return b[0];
        }

        public string? read_line (out int length, Cancellable? cancellable = null) throws IOError {
            length = 0;
            var buf = new uint8[256];
            int cap = 256;
            int used = 0;
            var one = new uint8[1];
            while (true) {
                int n = base_stream.read (one, cancellable);
                if (n <= 0) {
                    if (used == 0)
                        return null;
                    break;
                }
                if (one[0] == '\n')
                    break;
                if (one[0] == '\r')
                    continue;
                if (used >= cap) {
                    int ncap = cap * 2;
                    var nbuf = new uint8[ncap];
                    for (int i = 0; i < used; i++)
                        nbuf[i] = buf[i];
                    buf = nbuf;
                    cap = ncap;
                }
                buf[used] = one[0];
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

    public class FileInfo : Object {
        private string name;
        private int size;
        private FileType ftype;

        public FileInfo (string name, int size, FileType ftype = FileType.REGULAR) {
            this.name = name;
            this.size = size;
            this.ftype = ftype;
        }

        public string get_name () {
            return name.substring (0);
        }

        public int get_size () {
            return size;
        }

        public FileType get_file_type () {
            return ftype;
        }

        public string get_content_type () {
            if (ftype == FileType.DIRECTORY)
                return "inode/directory";
            if (name.has_suffix (".spv"))
                return "application/x-spirv";
            if (name.has_suffix (".vala"))
                return "text/x-vala";
            if (name.has_suffix (".elf"))
                return "application/x-executable";
            if (name.has_suffix (".txt") || name.has_suffix (".md")
                || name.has_suffix (".sh") || name.has_suffix (".log"))
                return "text/plain";
            return "application/octet-stream";
        }
    }

    public class FileEnumerator : Object {
        private string base_path;
        private GenericArray<string> names;
        private int idx = 0;
        private bool closed = false;

        public FileEnumerator (string base_path, GenericArray<string> names) {
            this.base_path = base_path;
            this.names = names;
        }

        public FileInfo? next_file (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed || idx >= names.length)
                return null;
            string name = names[idx];
            idx = idx + 1;
            string full = (base_path.length == 0 || base_path == "/") ? name : base_path + "/" + name;
            int kind = Sys.stat (full);
            int sz = 0;
            if (kind == 1) {
                int fd = Sys.open (full);
                if (fd >= 0) {
                    sz = Sys.file_size (fd);
                    if (sz < 0)
                        sz = 0;
                    Sys.close (fd);
                }
            }
            return new FileInfo (name, sz, (kind == 2) ? FileType.DIRECTORY : FileType.REGULAR);
        }

        public bool close (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            closed = true;
            return true;
        }
    }

    public class File : Object {
        private string path_str;

        private File (string path) {
            this.path_str = path;
        }

        public static File new_for_path (string path) {
            return new File (path);
        }

        public static File new_for_commandline_arg (string arg) {
            return new File (arg);
        }

        public string get_path () {
            return path_str.substring (0);
        }

        public string get_basename () {
            if (path_str == "/")
                return "/";
            int len = path_str.length;
            while (len > 1 && path_str[len - 1] == '/')
                len = len - 1;
            int slash = -1;
            for (int i = len - 1; i >= 0; i--) {
                if (path_str[i] == '/') {
                    slash = i;
                    break;
                }
            }
            if (slash < 0)
                return path_str.substring (0, len);
            return path_str.substring (slash + 1, len - slash - 1);
        }

        public File? get_parent () {
            if (path_str == "/" || path_str == "." || path_str.length == 0)
                return null;
            int len = path_str.length;
            while (len > 1 && path_str[len - 1] == '/')
                len = len - 1;
            int slash = -1;
            for (int i = len - 1; i >= 0; i--) {
                if (path_str[i] == '/') {
                    slash = i;
                    break;
                }
            }
            if (slash < 0)
                return new File (".");
            if (slash == 0)
                return new File ("/");
            return new File (path_str.substring (0, slash));
        }

        public File get_child (string name) {
            if (path_str.length == 0 || path_str == ".")
                return new File (name);
            if (path_str[path_str.length - 1] == '/')
                return new File (path_str + name);
            return new File (path_str + "/" + name);
        }

        private string normalize_fs_path () {
            if (path_str.length > 0 && path_str[0] == '/')
                return path_str.substring (1);
            return path_str;
        }

        public bool query_exists (Cancellable? cancellable = null) {
            if (cancellable != null && cancellable.is_cancelled ())
                return false;
            if (path_str == "/" || path_str == "." || path_str.length == 0)
                return true;
            return Sys.stat (normalize_fs_path ()) != 0;
        }

        public bool make_directory (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (Sys.mkdir (normalize_fs_path ()) < 0)
                throw new IOError.FAILED ("Failed to create directory");
            return true;
        }

        public bool delete (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            string p = normalize_fs_path ();
            if (Sys.unlink (p) < 0)
                throw new IOError.FAILED ("Failed to delete file");
            return true;
        }

        public bool move (File destination, FileCopyFlags flags = FileCopyFlags.NONE, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            string src = normalize_fs_path ();
            string dst = destination.normalize_fs_path ();
            if (src == dst)
                return true;
            if (destination.query_exists ()) {
                if (flags != FileCopyFlags.OVERWRITE)
                    throw new IOError.EXISTS ("Target file exists");
                if (Sys.unlink (dst) < 0)
                    throw new IOError.FAILED ("Failed to replace target");
            }
            if (Sys.rename (src, dst) < 0)
                throw new IOError.FAILED ("Failed to move file");
            return true;
        }

        public FileInfo query_info (string attributes = "*", FileQueryInfoFlags flags = FileQueryInfoFlags.NONE, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (path_str == "/" || path_str == "." || path_str.length == 0)
                return new FileInfo (get_basename (), 0, FileType.DIRECTORY);
            string p = normalize_fs_path ();
            int kind = Sys.stat (p);
            if (kind == 0)
                throw new IOError.NOT_FOUND ("No such file");
            int sz = 0;
            if (kind == 1) {
                int fd = Sys.open (p);
                if (fd >= 0) {
                    sz = Sys.file_size (fd);
                    if (sz < 0)
                        sz = 0;
                    Sys.close (fd);
                }
            }
            return new FileInfo (get_basename (), sz, (kind == 2) ? FileType.DIRECTORY : FileType.REGULAR);
        }

        public FileInputStream read (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            string p = normalize_fs_path ();
            int fd = Sys.open (p);
            if (fd < 0)
                throw new IOError.NOT_FOUND ("Failed to open file for reading");
            return new FileInputStream (fd);
        }

        public FileOutputStream create (FileCreateFlags flags = FileCreateFlags.NONE, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            string p = normalize_fs_path ();
            int existing = Sys.open (p);
            if (existing >= 0) {
                Sys.close (existing);
                if (flags != FileCreateFlags.REPLACE_DESTINATION)
                    throw new IOError.EXISTS ("File already exists");
            }
            int fd = Sys.create (p);
            if (fd < 0)
                throw new IOError.FAILED ("Failed to create file");
            return new FileOutputStream (fd, 0);
        }

        public FileOutputStream replace (string? etag = null, bool make_backup = false, FileCreateFlags flags = FileCreateFlags.NONE, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            string p = normalize_fs_path ();
            int fd = Sys.create (p);
            if (fd < 0)
                throw new IOError.FAILED ("Failed to replace file");
            return new FileOutputStream (fd, 0);
        }

        public FileOutputStream append_to (FileCreateFlags flags = FileCreateFlags.NONE, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            string p = normalize_fs_path ();
            int fd = Sys.open (p);
            if (fd < 0) {
                fd = Sys.create (p);
                if (fd < 0)
                    throw new IOError.FAILED ("Failed to open file for append");
                return new FileOutputStream (fd, 0);
            }
            int pos = Sys.seek (fd, -1);
            if (pos < 0)
                pos = 0;
            return new FileOutputStream (fd, pos);
        }

        public bool load_contents (Cancellable? cancellable, out uint8[] contents, out string? etag_out) throws IOError {
            etag_out = null;
            contents = new uint8[0];
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            string p = normalize_fs_path ();
            int fd = Sys.open (p);
            if (fd < 0)
                throw new IOError.NOT_FOUND ("File not found");
            int sz = Sys.file_size (fd);
            if (sz < 0)
                sz = 0;
            var buf = new uint8[sz];
            int got = 0;
            while (got < sz) {
                int rem = sz - got;
                var chunk = new uint8[rem];
                int r = Sys.read (fd, chunk, rem);
                if (r <= 0)
                    break;
                for (int i = 0; i < r; i++)
                    buf[got + i] = chunk[i];
                got = got + r;
            }
            Sys.close (fd);
            if (got == sz) {
                contents = buf;
            } else {
                var trimmed = new uint8[got];
                for (int i = 0; i < got; i++)
                    trimmed[i] = buf[i];
                contents = trimmed;
            }
            return true;
        }

        public bool replace_contents (uint8[] contents, string? etag, bool make_backup, FileCreateFlags flags, out string? new_etag, Cancellable? cancellable = null) throws IOError {
            new_etag = null;
            var stream = replace (etag, make_backup, flags, cancellable);
            int written = 0;
            bool ok = stream.write_all (contents, out written, cancellable);
            stream.close (cancellable);
            return ok;
        }

        public FileEnumerator enumerate_children (string attributes = "*", FileQueryInfoFlags flags = FileQueryInfoFlags.NONE, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            var buf = new uint8[4096];
            string dir = normalize_fs_path ();
            if (dir.length == 0)
                dir = "/";
            int n = Sys.readdir_path (dir, buf, 4096);
            if (n < 0)
                throw new IOError.NOT_FOUND ("Not a directory");
            var list = new GenericArray<string> ();
            if (n > 0) {
                int start = 0;
                for (int i = 0; i < n; i++) {
                    if (buf[i] == '\n') {
                        if (i > start) {
                            var slice = new uint8[i - start];
                            for (int k = 0; k < i - start; k++)
                                slice[k] = buf[start + k];
                            list.add (__planc_host_bytes_to_str (slice, i - start));
                        }
                        start = i + 1;
                    }
                }
                if (n > start) {
                    var slice = new uint8[n - start];
                    for (int k = 0; k < n - start; k++)
                        slice[k] = buf[start + k];
                    list.add (__planc_host_bytes_to_str (slice, n - start));
                }
            }
            return new FileEnumerator (normalize_fs_path (), list);
        }
    }

    public class Application : Object {
        private string? app_id;
        private ApplicationFlags flags;
        private int hold_count = 0;

        public signal void activate ();

        public Application (string? application_id = null, ApplicationFlags flags = ApplicationFlags.FLAGS_NONE) {
            this.app_id = application_id;
            this.flags = flags;
        }

        public string? get_application_id () {
            return (app_id != null) ? app_id.substring (0) : null;
        }

        public ApplicationFlags get_flags () {
            return flags;
        }

        public void hold () {
            hold_count = hold_count + 1;
        }

        public void release () {
            if (hold_count > 0)
                hold_count = hold_count - 1;
        }

        public int run (string[] args) {
            activate ();
            return 0;
        }
    }
}
