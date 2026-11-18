// Pure-Vala Gio File, FileInfo, and FileEnumerator.
using GLib;
using Planet;

namespace Gio {

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
            string full = (base_path.length == 0 || base_path == "/" || base_path == ".") ? name : base_path + "/" + name;
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
            if (Sys.rename (src, dst) < 0) {
                if (Sys.stat (src) != 1)
                    throw new IOError.FAILED ("Failed to move file");
                copy (destination, flags, cancellable);
                delete (cancellable);
            }
            return true;
        }

        public bool copy (File destination, FileCopyFlags flags = FileCopyFlags.NONE, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            string src = normalize_fs_path ();
            string dst = destination.normalize_fs_path ();
            if (src == dst)
                return true;
            if (destination.query_exists (cancellable) && flags != FileCopyFlags.OVERWRITE)
                throw new IOError.EXISTS ("Target file exists");
            var inp = read (cancellable);
            FileOutputStream? outp = null;
            try {
                outp = destination.replace (null, false, FileCreateFlags.REPLACE_DESTINATION, cancellable);
                var buf = new uint8[4096];
                while (true) {
                    int n = inp.read (buf, cancellable);
                    if (n <= 0)
                        break;
                    if (n == buf.length) {
                        int w = 0;
                        if (!outp.write_all (buf, out w, cancellable))
                            throw new IOError.FAILED ("Copy write failed");
                    } else {
                        var slice = new uint8[n];
                        for (int i = 0; i < n; i++)
                            slice[i] = buf[i];
                        int w = 0;
                        if (!outp.write_all (slice, out w, cancellable))
                            throw new IOError.FAILED ("Copy write failed");
                    }
                }
            } finally {
                inp.close (null);
                if (outp != null)
                    outp.close (null);
            }
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
            if (sz > 0) {
                int first = Sys.read (fd, buf, sz);
                if (first > 0)
                    got = first;
            }
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
            bool ok = false;
            try {
                int written = 0;
                ok = stream.write_all (contents, out written, cancellable);
            } finally {
                stream.close (null);
            }
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

}
