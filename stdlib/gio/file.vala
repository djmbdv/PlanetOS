// Pure-Vala Gio File, FileInfo, and FileEnumerator.
using GLib;
using Planet;

namespace Gio {

    public class ContentType : Object {
        public static string guess (string? filename, uint8[]? data, out bool result_uncertain) {
            result_uncertain = false;
            if (data != null && data.length >= 4) {
                if (data[0] == 0x7f && data[1] == 'E' && data[2] == 'L' && data[3] == 'F')
                    return "application/x-executable";
                if (data[0] == '#' && data[1] == '!')
                    return "application/x-shellscript";
                if (data[0] == '{' || data[0] == '[')
                    return "application/json";
            }
            if (filename != null) {
                if (filename.has_suffix (".spv"))
                    return "application/x-spirv";
                if (filename.has_suffix (".vala") || filename.has_suffix (".vapi"))
                    return "text/x-vala";
                if (filename.has_suffix (".c") || filename.has_suffix (".h"))
                    return "text/x-c";
                if (filename.has_suffix (".elf"))
                    return "application/x-executable";
                if (filename.has_suffix (".json"))
                    return "application/json";
                if (filename.has_suffix (".txt") || filename.has_suffix (".md")
                    || filename.has_suffix (".sh") || filename.has_suffix (".log"))
                    return "text/plain";
            }
            result_uncertain = true;
            return "application/octet-stream";
        }

        public static bool equals (string type1, string type2) {
            return type1 == type2;
        }

        public static bool is_a (string type, string supertype) {
            if (type == supertype)
                return true;
            if (supertype == "text/plain" && type.has_prefix ("text/"))
                return true;
            if (supertype == "application/octet-stream")
                return true;
            return false;
        }

        public static string get_description (string type) {
            if (type == "inode/directory")
                return "folder";
            if (type == "text/plain")
                return "plain text document";
            if (type == "text/x-vala")
                return "Vala source code";
            if (type == "text/x-c")
                return "C source code";
            if (type == "application/json")
                return "JSON document";
            if (type == "application/x-executable")
                return "executable";
            if (type == "application/x-spirv")
                return "SPIR-V shader";
            return type;
        }
    }

    public class FileInfo : Object {
        private string name;
        private int size;
        private FileType ftype;
        private string? content_type_val = null;

        public FileInfo (string name, int size, FileType ftype = FileType.REGULAR) {
            this.name = name;
            this.size = size;
            this.ftype = ftype;
        }

        public string get_name () {
            return name.substring (0);
        }

        public void set_name (string name) {
            this.name = name;
        }

        public string get_display_name () {
            return get_name ();
        }

        public string get_edit_name () {
            return get_name ();
        }

        public int get_size () {
            return size;
        }

        public void set_size (int size) {
            this.size = size;
        }

        public FileType get_file_type () {
            return ftype;
        }

        public void set_file_type (FileType type) {
            this.ftype = type;
        }

        public bool get_is_hidden () {
            return name.has_prefix (".") && name != "." && name != "..";
        }

        public bool get_is_backup () {
            return name.has_suffix ("~");
        }

        public string get_content_type () {
            if (content_type_val != null)
                return content_type_val;
            if (ftype == FileType.DIRECTORY)
                return "inode/directory";
            bool unc = false;
            return ContentType.guess (name, null, out unc);
        }

        public void set_content_type (string content_type) {
            this.content_type_val = content_type;
        }

        public bool has_attribute (string attribute) {
            return attribute == "standard::name"
                || attribute == "standard::display-name"
                || attribute == "standard::edit-name"
                || attribute == "standard::size"
                || attribute == "standard::type"
                || attribute == "standard::content-type"
                || attribute == "standard::is-hidden"
                || attribute == "standard::is-backup";
        }

        public string? get_attribute_string (string attribute) {
            if (attribute == "standard::name" || attribute == "standard::display-name" || attribute == "standard::edit-name")
                return get_name ();
            if (attribute == "standard::content-type")
                return get_content_type ();
            return null;
        }

        public int32 get_attribute_int32 (string attribute) {
            if (attribute == "standard::type")
                return (int32) ftype;
            return 0;
        }

        public uint64 get_attribute_uint64 (string attribute) {
            if (attribute == "standard::size")
                return (uint64) size;
            return 0;
        }

        public bool get_attribute_boolean (string attribute) {
            if (attribute == "standard::is-hidden")
                return get_is_hidden ();
            if (attribute == "standard::is-backup")
                return get_is_backup ();
            return false;
        }

        public FileInfo dup () {
            var copy = new FileInfo (name, size, ftype);
            if (content_type_val != null)
                copy.set_content_type (content_type_val);
            return copy;
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

        public bool is_closed () {
            return closed;
        }

        public bool has_pending () {
            return false;
        }

        public File get_container () {
            return File.new_for_path (base_path.length > 0 ? base_path : ".");
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
            if (arg.has_prefix ("file://"))
                return new_for_uri (arg);
            return new File (arg);
        }

        public static File new_for_uri (string uri) {
            if (uri.has_prefix ("file://")) {
                string rest = uri.substring (7);
                return new File (rest.length > 0 ? rest : "/");
            }
            return new File (uri);
        }

        public static File parse_name (string parse_name) {
            if (parse_name.has_prefix ("file://"))
                return new_for_uri (parse_name);
            return new File (parse_name);
        }

        public string get_path () {
            return path_str.substring (0);
        }

        public string get_uri () {
            if (path_str.has_prefix ("/"))
                return "file://" + path_str;
            return "file:///" + path_str;
        }

        public string get_parse_name () {
            return get_path ();
        }

        public bool equal (File file2) {
            return path_str == file2.get_path ();
        }

        public bool has_prefix (File prefix) {
            string p = prefix.get_path ();
            if (p == "/")
                return path_str.has_prefix ("/") && path_str != "/";
            if (p.has_suffix ("/"))
                p = p.substring (0, p.length - 1);
            if (!path_str.has_prefix (p))
                return false;
            return path_str.length > p.length && path_str[p.length] == '/';
        }

        public string? get_relative_path (File descendant) {
            if (!descendant.has_prefix (this))
                return null;
            string dp = descendant.get_path ();
            if (path_str == "/")
                return dp.substring (1);
            int off = path_str.has_suffix ("/") ? path_str.length : (path_str.length + 1);
            return dp.substring (off);
        }

        public bool has_parent (File? parent = null) {
            var p = get_parent ();
            if (p == null)
                return false;
            if (parent == null)
                return true;
            return p.equal (parent);
        }

        public File resolve_relative_path (string relative_path) {
            if (relative_path.has_prefix ("/"))
                return new File (relative_path);
            return get_child (relative_path);
        }

        public string get_basename () {
            if (path_str == "/")
                return "/";
            int len = path_str.length;
            while (len > 1 && path_str[len - 1] == '/')
                len = len - 1;
            int slash = path_str.substring (0, len).last_index_of_char ('/');
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
            int slash = path_str.substring (0, len).last_index_of_char ('/');
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

        public bool make_directory_with_parents (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (query_exists (cancellable))
                return true;
            var parent = get_parent ();
            if (parent != null && !parent.query_exists (cancellable))
                parent.make_directory_with_parents (cancellable);
            if (!query_exists (cancellable))
                return make_directory (cancellable);
            return true;
        }

        public FileType query_file_type (FileQueryInfoFlags flags = FileQueryInfoFlags.NONE, Cancellable? cancellable = null) {
            if (cancellable != null && cancellable.is_cancelled ())
                return FileType.UNKNOWN;
            if (path_str == "/" || path_str == "." || path_str.length == 0)
                return FileType.DIRECTORY;
            int kind = Sys.stat (normalize_fs_path ());
            if (kind == 2)
                return FileType.DIRECTORY;
            if (kind == 1)
                return FileType.REGULAR;
            return FileType.UNKNOWN;
        }

        public bool trash (Cancellable? cancellable = null) throws IOError {
            return delete (cancellable);
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
            int src_kind = Sys.stat (src);
            if (src_kind == 0)
                throw new IOError.NOT_FOUND ("Source file does not exist");
            if (destination.query_exists (cancellable)) {
                if ((flags & FileCopyFlags.OVERWRITE) == 0)
                    throw new IOError.EXISTS ("Target file exists");
                if (Sys.unlink (dst) < 0)
                    throw new IOError.FAILED ("Failed to replace target");
            }
            if (Sys.rename (src, dst) < 0) {
                if (src_kind != 1)
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
            if (destination.query_exists (cancellable) && (flags & FileCopyFlags.OVERWRITE) == 0)
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
                if ((flags & FileCreateFlags.REPLACE_DESTINATION) == 0)
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
            if (make_backup && query_exists (cancellable)) {
                var bak = new File (path_str + "~");
                copy (bak, FileCopyFlags.OVERWRITE, cancellable);
            }
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
            try {
                int sz = Sys.file_size (fd);
                if (sz < 0)
                    sz = 0;
                if (sz > 67108864)
                    throw new IOError.FAILED ("File exceeds maximum load_contents size");
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
                if (got == sz) {
                    contents = buf;
                } else {
                    var trimmed = new uint8[got];
                    for (int i = 0; i < got; i++)
                        trimmed[i] = buf[i];
                    contents = trimmed;
                }
            } finally {
                Sys.close (fd);
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
