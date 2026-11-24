// Pure-Vala GLib.BookmarkFile (the `[Bookmark N]` INI format) for PlanetOS.
using Planet;

namespace GLib {

    public errordomain BookmarkFileError {
        INVALID_URI,
        INVALID_VALUE,
        URI_NOT_FOUND,
        READ,
        WRITE
    }

    private class BookmarkItem : Object {
        public string uri;
        public string title = "";
        public string mime_type = "";
        public string description = "";
        public string icon = "";
        public GenericArray<string> groups = new GenericArray<string> ();

        public BookmarkItem (string uri) {
            this.uri = uri;
        }
    }

    /**
     * Bookmark list stored as `[Bookmark N]` groups (GLib.BookmarkFile). Each
     * URI is validated with GLib.Uri, so callers can rely on the components.
     */
    public class BookmarkFile : Object {
        private GenericArray<BookmarkItem> items = new GenericArray<BookmarkItem> ();
        private HashTable<string, int> index =
            new HashTable<string, int> (GLib.str_hash, GLib.str_equal);

        public BookmarkFile () {}

        private void reindex () {
            index = new HashTable<string, int> (GLib.str_hash, GLib.str_equal);
            for (int i = 0; i < items.length; i++)
                index.insert (items[i].uri, i);
        }

        private int find (string uri) {
            int i = -1;
            string orig = "";
            if (!index.lookup_extended (uri, out orig, out i))
                return -1;
            return i;
        }

        private BookmarkItem? item_or_null (string uri) {
            int i = find (uri);
            return (i >= 0) ? items[i] : null;
        }

        private BookmarkItem ensure (string uri) throws BookmarkFileError {
            int i = find (uri);
            if (i >= 0)
                return items[i];
            try {
                Uri.parse (uri);
            } catch (UriError e) {
                throw new BookmarkFileError.INVALID_URI (@"Invalid bookmark URI '$uri'");
            }
            var item = new BookmarkItem (uri);
            index.insert (uri, items.length);
            items.add (item);
            return item;
        }

        public bool load_from_data (string data, size_t length) throws BookmarkFileError {
            var kf = new KeyFile ();
            int n = (length == 0 || (int) length > data.length) ? data.length : (int) length;
            try {
                kf.load_from_data (data, n, KeyFileFlags.NONE);
            } catch (KeyFileError e) {
                throw new BookmarkFileError.INVALID_VALUE (e.message);
            }
            items = new GenericArray<BookmarkItem> ();
            index = new HashTable<string, int> (GLib.str_hash, GLib.str_equal);
            var groups = kf.get_groups ();
            for (int g = 0; g < groups.length; g++) {
                string group = groups[g];
                if (!group.has_prefix ("Bookmark"))
                    continue;
                string uri = "";
                try {
                    uri = kf.get_string (group, "URI");
                } catch (KeyFileError e) {
                    continue;
                }
                try {
                    Uri.parse (uri);
                } catch (UriError e) {
                    throw new BookmarkFileError.INVALID_URI (@"Invalid bookmark URI '$uri'");
                }
                var item = new BookmarkItem (uri);
                item.title = kf_get (kf, group, "Title");
                item.mime_type = kf_get (kf, group, "MimeType");
                item.description = kf_get (kf, group, "Description");
                item.icon = kf_get (kf, group, "Icon");
                string groups_text = kf_get (kf, group, "Groups");
                int start = 0;
                for (int k = 0; k <= groups_text.length; k++) {
                    if (k == groups_text.length || groups_text[k] == ';' || groups_text[k] == ',') {
                        if (k > start)
                            item.groups.add (groups_text.substring (start, k - start));
                        start = k + 1;
                    }
                }
                items.add (item);
            }
            reindex ();
            return true;
        }

        private static string kf_get (KeyFile kf, string group, string key) {
            try {
                return kf.get_string (group, key);
            } catch (KeyFileError e) {
                return "";
            }
        }

        public bool load_from_file (string filename) throws BookmarkFileError {
            string text = "";
            if (!FileUtils.get_contents (filename, out text))
                throw new BookmarkFileError.READ (@"Cannot read '$filename'");
            return load_from_data (text, text.length);
        }

        public string to_data (out size_t length) {
            var kf = new KeyFile ();
            for (int i = 0; i < items.length; i++) {
                var item = items[i];
                string group = @"Bookmark $i";
                kf.set_string (group, "URI", item.uri);
                if (item.title.length > 0)
                    kf.set_string (group, "Title", item.title);
                if (item.mime_type.length > 0)
                    kf.set_string (group, "MimeType", item.mime_type);
                if (item.description.length > 0)
                    kf.set_string (group, "Description", item.description);
                if (item.icon.length > 0)
                    kf.set_string (group, "Icon", item.icon);
                if (item.groups.length > 0) {
                    var sb = new StringBuilder ();
                    for (int g = 0; g < item.groups.length; g++) {
                        sb.append (item.groups[g]);
                        sb.append_c (';');
                    }
                    kf.set_string (group, "Groups", sb.str);
                }
            }
            int len = 0;
            string data = kf.to_data (out len);
            length = (size_t) len;
            return data;
        }

        public bool to_file (string filename) throws BookmarkFileError {
            size_t len = 0;
            string data = to_data (out len);
            if (!FileUtils.set_contents (filename, data))
                throw new BookmarkFileError.WRITE (@"Cannot write '$filename'");
            return true;
        }

        public bool has_item (string uri) {
            return item_or_null (uri) != null;
        }

        public string[] get_uris () {
            var res = new string[items.length];
            for (int i = 0; i < items.length; i++)
                res[i] = items[i].uri;
            return res;
        }

        public int get_size () {
            return items.length;
        }

        public string get_title (string uri) throws BookmarkFileError {
            var item = item_or_null (uri);
            if (item == null)
                throw new BookmarkFileError.URI_NOT_FOUND (@"No bookmark for '$uri'");
            return ((!) item).title;
        }

        public void set_title (string uri, string? title) throws BookmarkFileError {
            var item = ensure (uri);
            item.title = (title != null) ? (!) title : "";
        }

        public string get_mime_type (string uri) throws BookmarkFileError {
            var item = item_or_null (uri);
            if (item == null)
                throw new BookmarkFileError.URI_NOT_FOUND (@"No bookmark for '$uri'");
            return ((!) item).mime_type;
        }

        public void set_mime_type (string uri, string? mime_type) throws BookmarkFileError {
            var item = ensure (uri);
            item.mime_type = (mime_type != null) ? (!) mime_type : "";
        }

        public string get_description (string uri) throws BookmarkFileError {
            var item = item_or_null (uri);
            if (item == null)
                throw new BookmarkFileError.URI_NOT_FOUND (@"No bookmark for '$uri'");
            return ((!) item).description;
        }

        public void set_description (string uri, string? description) throws BookmarkFileError {
            var item = ensure (uri);
            item.description = (description != null) ? (!) description : "";
        }

        public string get_icon (string uri) throws BookmarkFileError {
            var item = item_or_null (uri);
            if (item == null)
                throw new BookmarkFileError.URI_NOT_FOUND (@"No bookmark for '$uri'");
            return ((!) item).icon;
        }

        public void set_icon (string uri, string? icon) throws BookmarkFileError {
            var item = ensure (uri);
            item.icon = (icon != null) ? (!) icon : "";
        }

        public bool has_group (string uri, string group) {
            var item = item_or_null (uri);
            if (item == null)
                return false;
            for (int g = 0; g < ((!) item).groups.length; g++) {
                if (((!) item).groups[g] == group)
                    return true;
            }
            return false;
        }

        public void add_group (string uri, string group) throws BookmarkFileError {
            var item = ensure (uri);
            for (int g = 0; g < item.groups.length; g++) {
                if (item.groups[g] == group)
                    return;
            }
            item.groups.add (group);
        }

        public string[] get_groups (string uri) {
            var item = item_or_null (uri);
            if (item == null)
                return new string[0];
            var res = new string[((!) item).groups.length];
            for (int g = 0; g < ((!) item).groups.length; g++)
                res[g] = ((!) item).groups[g];
            return res;
        }

        public bool remove_item (string uri) {
            int i = find (uri);
            if (i < 0)
                return false;
            items.remove_index (i);
            reindex ();
            return true;
        }

        public bool remove_group (string uri, string group) throws BookmarkFileError {
            var item = item_or_null (uri);
            if (item == null)
                throw new BookmarkFileError.URI_NOT_FOUND (@"No bookmark for '$uri'");
            for (int g = 0; g < ((!) item).groups.length; g++) {
                if (((!) item).groups[g] == group) {
                    ((!) item).groups.remove_index (g);
                    return true;
                }
            }
            return false;
        }

        public void remove_all () {
            items = new GenericArray<BookmarkItem> ();
            index = new HashTable<string, int> (GLib.str_hash, GLib.str_equal);
        }
    }
}
