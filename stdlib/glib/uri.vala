// Pure-Vala GLib.Uri: RFC 3986 parsing, building, resolving and escaping.
using Planet;

namespace GLib {

    public enum UriFlags {
        NONE = 0,
        PARSE_RELAXED = 1,
        HAS_PASSWORD = 2,
        ENCODED = 4,
        NON_DNS = 8,
        ENCODED_PATH = 16,
        ENCODED_QUERY = 32,
        ENCODED_FRAGMENT = 64,
        SCHEME_NORMALIZE = 128
    }

    public errordomain UriError {
        FAILED,
        BAD_ENCODING,
        BAD_SCHEME,
        BAD_USERINFO,
        BAD_HOST,
        BAD_PORT,
        BAD_PATH,
        BAD_QUERY,
        BAD_FRAGMENT
    }

    /**
     * An absolute or relative URI reference (GLib.Uri). The parser keeps the
     * components separate, so callers never concatenate paths by hand.
     */
    public class Uri : Object {
        private string scheme = "";
        private string userinfo = "";
        private string host = "";
        private int port = -1;
        private string path_str = "";
        private string query_str = "";
        private string fragment_str = "";
        private bool has_query = false;
        private bool has_fragment = false;
        private bool has_authority = false;
        private UriFlags uri_flags = UriFlags.NONE;

        public Uri (string scheme, string? userinfo, string? host, int port,
                    string path, string? query, string? fragment,
                    UriFlags flags = UriFlags.NONE) throws UriError {
            this.scheme = (scheme != null) ? scheme : "";
            this.userinfo = (userinfo != null) ? (!) userinfo : "";
            this.host = (host != null) ? (!) host : "";
            this.port = port;
            this.path_str = path;
            this.uri_flags = flags;
            this.has_authority = (this.host.length > 0 || this.userinfo.length > 0 || port >= 0);
            if (query != null) {
                this.query_str = (!) query;
                this.has_query = true;
            }
            if (fragment != null) {
                this.fragment_str = (!) fragment;
                this.has_fragment = true;
            }
            if (this.scheme.length > 0 && !valid_scheme (this.scheme))
                throw new UriError.BAD_SCHEME (@"Invalid scheme '$(this.scheme)'");
            if (this.port < -1 || this.port > 65535)
                throw new UriError.BAD_PORT ("Port out of range");
        }

        private static bool valid_scheme (string text) {
            if (text.length == 0)
                return false;
            char first = text[0];
            bool first_ok = (first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z');
            if (!first_ok)
                return false;
            for (int i = 1; i < text.length; i++) {
                char c = text[i];
                bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                       || (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.';
                if (!ok)
                    return false;
            }
            return true;
        }

        private static int parse_port (string text) throws UriError {
            if (text.length == 0)
                return -1;
            int value = 0;
            for (int i = 0; i < text.length; i++) {
                char c = text[i];
                if (c < '0' || c > '9')
                    throw new UriError.BAD_PORT (@"Invalid port '$text'");
                value = value * 10 + (int) (c - '0');
                if (value > 65535)
                    throw new UriError.BAD_PORT (@"Port '$text' out of range");
            }
            return value;
        }

        public static Uri parse (string uri_ref, UriFlags flags = UriFlags.NONE) throws UriError {
            string rest = uri_ref;
            string scheme = "";
            string userinfo = "";
            string host = "";
            int port = -1;
            string path_str = "";
            string query_str = "";
            string fragment_str = "";
            bool has_query = false;
            bool has_fragment = false;
            bool has_authority = false;
            UriFlags out_flags = flags;

            int hash = rest.index_of_char ('#');
            if (hash >= 0) {
                fragment_str = rest.substring (hash + 1);
                rest = rest.substring (0, hash);
                has_fragment = true;
            }
            int qm = rest.index_of_char ('?');
            if (qm >= 0) {
                query_str = rest.substring (qm + 1);
                rest = rest.substring (0, qm);
                has_query = true;
            }
            int colon = rest.index_of_char (':');
            if (colon > 0) {
                string maybe = rest.substring (0, colon);
                if (valid_scheme (maybe)) {
                    scheme = maybe;
                    rest = rest.substring (colon + 1);
                    if ((out_flags & UriFlags.SCHEME_NORMALIZE) != 0)
                        scheme = Str.ascii_down (scheme);
                }
            }
            if (rest.has_prefix ("//")) {
                has_authority = true;
                rest = rest.substring (2);
                int slash = rest.index_of_char ('/');
                string authority = (slash >= 0) ? rest.substring (0, slash) : rest;
                path_str = (slash >= 0) ? rest.substring (slash) : "";
                int at = authority.last_index_of_char ('@');
                string hostport = authority;
                if (at >= 0) {
                    userinfo = authority.substring (0, at);
                    hostport = authority.substring (at + 1);
                    if (userinfo.index_of_char (':') >= 0)
                        out_flags = out_flags | UriFlags.HAS_PASSWORD;
                }
                if (hostport.has_prefix ("[")) {
                    int rb = hostport.index_of_char (']');
                    if (rb < 0)
                        throw new UriError.BAD_HOST (@"Unterminated IPv6 host in '$authority'");
                    host = hostport.substring (0, rb + 1);
                    string tail = hostport.substring (rb + 1);
                    if (tail.has_prefix (":"))
                        port = parse_port (tail.substring (1));
                    else if (tail.length > 0)
                        throw new UriError.BAD_HOST (@"Trailing text after IPv6 host in '$authority'");
                    out_flags = out_flags | UriFlags.NON_DNS;
                } else {
                    int pc = hostport.last_index_of_char (':');
                    if (pc >= 0) {
                        host = hostport.substring (0, pc);
                        port = parse_port (hostport.substring (pc + 1));
                    } else {
                        host = hostport;
                    }
                }
            } else {
                path_str = rest;
            }

            var uri = new Uri (scheme, userinfo, host, port, path_str,
                               has_query ? query_str : null,
                               has_fragment ? fragment_str : null,
                               out_flags);
            uri.has_authority = has_authority;
            return uri;
        }

        // RFC 3986 section 5.2.4.
        private static string remove_dot_segments (string path_in) {
            var parts = new GenericArray<string> ();
            bool absolute = path_in.has_prefix ("/");
            int i = 0;
            while (i < path_in.length) {
                if (path_in[i] == '/') {
                    i++;
                    continue;
                }
                int j = i;
                while (j < path_in.length && path_in[j] != '/')
                    j++;
                string seg = path_in.substring (i, j - i);
                if (seg == ".") {
                    // drop
                } else if (seg == "..") {
                    if (parts.length > 0)
                        parts.remove_index (parts.length - 1);
                } else {
                    parts.add (seg);
                }
                i = j;
            }
            var sb = new StringBuilder ();
            if (absolute)
                sb.append_c ('/');
            for (int k = 0; k < parts.length; k++) {
                if (k > 0)
                    sb.append_c ('/');
                sb.append (parts[k]);
            }
            if (path_in.has_suffix ("/") && parts.length > 0 && !sb.str.has_suffix ("/"))
                sb.append_c ('/');
            return sb.str;
        }

        // Resolves `uri_ref` against `ref_base` (RFC 3986 section 5.2).
        public static Uri resolve_relative (Uri ref_base, string uri_ref, UriFlags flags = UriFlags.NONE) throws UriError {
            if (uri_ref.length == 0)
                return ref_base;
            int colon = uri_ref.index_of_char (':');
            int slash = uri_ref.index_of_char ('/');
            int qm = uri_ref.index_of_char ('?');
            int hash = uri_ref.index_of_char ('#');
            bool colon_first = colon > 0
                && (slash < 0 || colon < slash)
                && (qm < 0 || colon < qm)
                && (hash < 0 || colon < hash)
                && valid_scheme (uri_ref.substring (0, colon));
            if (colon_first || uri_ref.has_prefix ("//")) {
                var full = parse (uri_ref, flags);
                if (full.scheme.length == 0)
                    full.scheme = ref_base.scheme;
                if (!full.has_authority) {
                    full.host = ref_base.host;
                    full.userinfo = ref_base.userinfo;
                    full.port = ref_base.port;
                    full.has_authority = ref_base.has_authority;
                }
                return full;
            }
            if (uri_ref.has_prefix ("#")) {
                return new Uri (ref_base.scheme, ref_base.userinfo, ref_base.host,
                                ref_base.port, ref_base.path_str,
                                ref_base.has_query ? ref_base.query_str : null,
                                uri_ref.substring (1), flags);
            }
            if (uri_ref.has_prefix ("?")) {
                int h2 = uri_ref.index_of_char ('#');
                string q = (h2 >= 0) ? uri_ref.substring (1, h2 - 1) : uri_ref.substring (1);
                string? f = (h2 >= 0) ? uri_ref.substring (h2 + 1) : null;
                return new Uri (ref_base.scheme, ref_base.userinfo, ref_base.host,
                                ref_base.port, ref_base.path_str, q, f, flags);
            }
            string ref_path = uri_ref;
            string ref_query = "";
            string ref_fragment = "";
            bool ref_has_query = false;
            bool ref_has_fragment = false;
            int h3 = ref_path.index_of_char ('#');
            if (h3 >= 0) {
                ref_fragment = ref_path.substring (h3 + 1);
                ref_path = ref_path.substring (0, h3);
                ref_has_fragment = true;
            }
            int q3 = ref_path.index_of_char ('?');
            if (q3 >= 0) {
                ref_query = ref_path.substring (q3 + 1);
                ref_path = ref_path.substring (0, q3);
                ref_has_query = true;
            }
            string merged;
            if (ref_path.length > 0 && ref_path[0] == '/') {
                merged = ref_path;
            } else if (ref_base.path_str.length == 0) {
                merged = "/" + ref_path;
            } else {
                int last = ref_base.path_str.last_index_of_char ('/');
                if (last < 0)
                    merged = ref_path;
                else
                    merged = ref_base.path_str.substring (0, last + 1) + ref_path;
            }
            merged = remove_dot_segments (merged);
            return new Uri (ref_base.scheme, ref_base.userinfo, ref_base.host,
                            ref_base.port, merged,
                            ref_has_query ? ref_query : null,
                            ref_has_fragment ? ref_fragment : null,
                            flags);
        }

        public string get_scheme () { return scheme; }
        public string get_userinfo () { return userinfo; }
        public string get_host () { return host; }
        public int get_port () { return port; }
        public string get_query () { return query_str; }
        public string get_fragment () { return fragment_str; }
        public UriFlags get_flags () { return uri_flags; }

        public bool has_query_component () { return has_query; }
        public bool has_fragment_component () { return has_fragment; }

        public string get_path () {
            if ((uri_flags & UriFlags.ENCODED_PATH) != 0)
                return path_str;
            size_t illegal = 0;
            return unescape_string (path_str, out illegal);
        }

        public string get_path_encoded () {
            return path_str;
        }

        // Adds a path segment, inserting the separator only when needed.
        public void set_path (string path) {
            path_str = path;
        }

        public string to_string () {
            var sb = new StringBuilder ();
            if (scheme.length > 0) {
                sb.append (scheme);
                sb.append_c (':');
            }
            if (has_authority) {
                sb.append ("//");
                if (userinfo.length > 0) {
                    sb.append (userinfo);
                    sb.append_c ('@');
                }
                sb.append (host);
                if (port >= 0) {
                    sb.append_c (':');
                    sb.append (port.to_string ());
                }
            }
            sb.append (path_str);
            if (has_query) {
                sb.append_c ('?');
                sb.append (query_str);
            }
            if (has_fragment) {
                sb.append_c ('#');
                sb.append (fragment_str);
            }
            return sb.str;
        }

        // True when `other` has the same scheme, host and port.
        public bool same_origin (Uri other) {
            return scheme == other.scheme && host == other.host && port == other.port;
        }

        private const string HEX = "0123456789ABCDEF";

        private static bool unreserved (uint8 c) {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                || (c >= '0' && c <= '9')
                || c == '-' || c == '.' || c == '_' || c == '~';
        }

        public static string escape_string (string unescaped, string? reserved_chars_allowed = null, bool allow_utf8 = true) {
            var sb = new StringBuilder ();
            for (int i = 0; i < unescaped.length; i++) {
                uint8 c = unescaped[i];
                bool keep = unreserved (c);
                if (!keep && c >= 0x80 && allow_utf8)
                    keep = true;
                if (!keep && reserved_chars_allowed != null) {
                    for (int j = 0; j < ((!) reserved_chars_allowed).length; j++) {
                        if (((uint8) ((!) reserved_chars_allowed)[j]) == c) {
                            keep = true;
                            break;
                        }
                    }
                }
                if (keep) {
                    sb.append_c ((char) c);
                } else {
                    sb.append_c ('%');
                    sb.append_c (HEX[(c >> 4) & 0x0F]);
                    sb.append_c (HEX[c & 0x0F]);
                }
            }
            return sb.str;
        }

        private static int hex_value (uint8 c) {
            if (c >= '0' && c <= '9')
                return (int) (c - '0');
            if (c >= 'a' && c <= 'f')
                return (int) (c - 'a') + 10;
            if (c >= 'A' && c <= 'F')
                return (int) (c - 'A') + 10;
            return -1;
        }

        public static string unescape_string (string escaped_string, out size_t illegal_characters) {
            var sb = new StringBuilder ();
            illegal_characters = 0;
            int i = 0;
            while (i < escaped_string.length) {
                uint8 c = escaped_string[i];
                if (c != '%') {
                    sb.append_c ((char) c);
                    i++;
                    continue;
                }
                if (i + 2 >= escaped_string.length) {
                    illegal_characters = illegal_characters + 1;
                    sb.append_c ('%');
                    i++;
                    continue;
                }
                int hi = hex_value (escaped_string[i + 1]);
                int lo = hex_value (escaped_string[i + 2]);
                if (hi < 0 || lo < 0) {
                    illegal_characters = illegal_characters + 1;
                    sb.append_c ('%');
                    i++;
                    continue;
                }
                sb.append_c ((char) (uint8) (hi * 16 + lo));
                i += 3;
            }
            return sb.str;
        }
    }
}
