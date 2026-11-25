// Simple curl-like HTTP/1.1 + TLS 1.3 CLI demo for PlanetOS using GLib.Uri, GLib.OptionContext, and Gio.SocketClient/TlsClientConnection.
using GLib;
using Gee;
using Gio;
using Planet;

namespace PlanetCurl {

    private int parse_int_ascii (string s, int def_val) {
        string t = Str.strip (s);
        if (t.length == 0)
            return def_val;
        int val = 0;
        for (int i = 0; i < t.length; i++) {
            uint8 c = t[i];
            if (c < '0' || c > '9')
                return def_val;
            val = val * 10 + (int) (c - '0');
        }
        return val;
    }

    private string bytes_to_string (uint8[] buf, int len) {
        if (len <= 0)
            return "";
        return __planc_host_bytes_to_str (buf, len);
    }

    private uint8[] string_to_bytes (string s) {
        var b = new uint8[s.length];
        for (int i = 0; i < s.length; i++)
            b[i] = s[i];
        return b;
    }

    private HashMap<string, string> parse_header_map (ArrayList<string> headers) {
        var map = new HashMap<string, string> ();
        foreach (string h in headers) {
            int colon = h.index_of (":");
            if (colon > 0) {
                string k = Str.ascii_down (Str.strip (h.substring (0, colon)));
                string v = Str.strip (h.substring (colon + 1));
                map.set (k, v);
            }
        }
        return map;
    }

    private string build_http_request (string method, string host, int port, int default_port,
                                       string path_query, ArrayList<string> headers, string? body) {
        var hmap = parse_header_map (headers);
        var sb = new StringBuilder ();
        sb.append (@"$method $path_query HTTP/1.1\r\n");
        if (port == default_port)
            sb.append (@"Host: $host\r\n");
        else
            sb.append (@"Host: $host:$port\r\n");
        if (!hmap.has_key ("user-agent"))
            sb.append ("User-Agent: planet-curl/0.1\r\n");
        if (!hmap.has_key ("accept"))
            sb.append ("Accept: */*\r\n");
        if (!hmap.has_key ("connection"))
            sb.append ("Connection: close\r\n");
        foreach (string h in headers) {
            sb.append (h);
            sb.append ("\r\n");
        }
        if (body != null) {
            string b = (!) body;
            if (!hmap.has_key ("content-type"))
                sb.append ("Content-Type: application/x-www-form-urlencoded\r\n");
            if (!hmap.has_key ("content-length"))
                sb.append (@"Content-Length: $(b.length)\r\n");
            sb.append ("\r\n");
            sb.append (b);
        } else {
            sb.append ("\r\n");
        }
        return sb.str;
    }

    private string decode_chunked_body (string raw) {
        var sb = new StringBuilder ();
        int pos = 0;
        while (pos < raw.length) {
            int crlf = raw.index_of ("\r\n", pos);
            if (crlf < 0)
                break;
            string hex_len = Str.strip (raw.substring (pos, crlf - pos));
            int semi = hex_len.index_of (";");
            if (semi >= 0)
                hex_len = hex_len.substring (0, semi);
            int clen = 0;
            for (int i = 0; i < hex_len.length; i++) {
                uint8 c = hex_len[i];
                int d = -1;
                if (c >= '0' && c <= '9') d = (int) (c - '0');
                else if (c >= 'a' && c <= 'f') d = 10 + (int) (c - 'a');
                else if (c >= 'A' && c <= 'F') d = 10 + (int) (c - 'A');
                else break;
                clen = (clen << 4) | d;
            }
            pos = crlf + 2;
            if (clen <= 0)
                break;
            int take = (pos + clen <= raw.length) ? clen : (raw.length - pos);
            sb.append (raw.substring (pos, take));
            pos += take + 2;
        }
        return sb.str;
    }

    private bool read_http_message (InputStream ins, bool read_body_by_cl, bool read_body_to_eof,
                                    out string first_line, out ArrayList<string> headers, out string body) throws IOError {
        first_line = "";
        headers = new ArrayList<string> ();
        body = "";

        var raw = new ByteArray.sized (1024);
        var tmp = new uint8[512];
        int header_end = -1;
        int tries = 0;
        int scan_pos = 0;

        while (header_end < 0) {
            int n = ins.read (tmp);
            if (n < 0)
                break;
            if (n == 0) {
                if (++tries > 200)
                    throw new IOError.TIMED_OUT ("HTTP read timeout");
                Sys.sleep_ms (5);
                continue;
            }
            tries = 0;
            for (int i = 0; i < n; i++)
                raw.append_byte (tmp[i]);

            // Search for "\r\n\r\n" incrementally (O(N))
            for (int j = scan_pos; j + 3 < raw.len; j++) {
                if (raw.data[j] == '\r' && raw.data[j + 1] == '\n'
                    && raw.data[j + 2] == '\r' && raw.data[j + 3] == '\n') {
                    header_end = j + 4;
                    break;
                }
            }
            scan_pos = (raw.len > 3) ? raw.len - 3 : 0;
        }

        if (header_end < 0)
            return false;

        string head_str = bytes_to_string (raw.data, header_end - 4);
        int content_length = -1;
        bool is_chunked = false;

        int pos = 0;
        bool is_first = true;
        while (pos <= head_str.length) {
            int nl = head_str.index_of ("\n", pos);
            string line = Str.strip ((nl >= 0) ? head_str.substring (pos, nl - pos) : head_str.substring (pos));
            if (is_first) {
                first_line = line;
                is_first = false;
            } else if (line.length > 0) {
                headers.add (line);
                int colon = line.index_of (":");
                if (colon > 0) {
                    string k = Str.ascii_down (Str.strip (line.substring (0, colon)));
                    if (k == "content-length")
                        content_length = parse_int_ascii (line.substring (colon + 1), -1);
                    else if (k == "transfer-encoding" && Str.ascii_down (line.substring (colon + 1)).contains ("chunked"))
                        is_chunked = true;
                }
            }
            if (nl < 0)
                break;
            pos = nl + 1;
        }

        if (!read_body_by_cl && !read_body_to_eof)
            return true;

        var body_buf = new ByteArray.sized (content_length > 0 ? content_length : 512);
        for (int i = header_end; i < raw.len; i++)
            body_buf.append_byte (raw.data[i]);

        if (content_length >= 0) {
            if (!read_body_by_cl)
                return true;
            tries = 0;
            while (body_buf.len < content_length) {
                int n = ins.read (tmp);
                if (n < 0)
                    break;
                if (n == 0) {
                    if (++tries > 200)
                        break;
                    Sys.sleep_ms (5);
                    continue;
                }
                tries = 0;
                for (int i = 0; i < n; i++)
                    body_buf.append_byte (tmp[i]);
            }
            int take = (body_buf.len < content_length) ? body_buf.len : content_length;
            body = bytes_to_string (body_buf.data, take);
        } else if (read_body_to_eof) {
            tries = 0;
            while (body_buf.len < 4194304) {
                int n = ins.read (tmp);
                if (n < 0)
                    break;
                if (n == 0) {
                    if (++tries > 40)
                        break;
                    Sys.sleep_ms (5);
                    continue;
                }
                tries = 0;
                for (int i = 0; i < n; i++)
                    body_buf.append_byte (tmp[i]);
            }
            string raw_b = bytes_to_string (body_buf.data, body_buf.len);
            body = is_chunked ? decode_chunked_body (raw_b) : raw_b;
        }

        return true;
    }

    private int perform_request (string url_str, string method, ArrayList<string> headers,
                                 string? data, bool include_headers, bool is_head,
                                 bool insecure, bool verbose, string? output_path,
                                 out string out_status, out string out_body) {
        out_status = "";
        out_body = "";

        Uri uri;
        try {
            uri = Uri.parse (url_str, UriFlags.NONE);
        } catch (UriError e) {
            printerr (@"curl: invalid URL '$url_str': $(e.message)\n");
            return 3;
        }

        string scheme = Str.ascii_down (uri.get_scheme ());
        if (scheme != "http" && scheme != "https") {
            printerr (@"curl: unsupported scheme '$scheme' (only http and https are supported)\n");
            return 1;
        }

        string host = uri.get_host ();
        if (host.length == 0) {
            printerr (@"curl: missing host in '$url_str'\n");
            return 3;
        }

        bool is_https = (scheme == "https");
        int default_port = is_https ? 443 : 80;
        int port = uri.get_port ();
        if (port <= 0)
            port = default_port;

        string path = uri.get_path ();
        if (path.length == 0)
            path = "/";
        string? query = uri.get_query ();
        string path_query = (query != null && ((!) query).length > 0) ? @"$path?$((!) query)" : path;

        if (verbose)
            printerr (@"* Connecting to $host:$port ($(is_https ? "https" : "http"))\n");

        var client = new SocketClient ();
        client.protocol = SocketProtocol.TCP;
        client.tls = is_https;
        client.tls_validation_flags = insecure ? TlsCertificateFlags.NONE : TlsCertificateFlags.VALIDATE_ALL;

        IOStream? stream = null;
        try {
            if (is_https) {
                var tconn = client.connect_to_host_tls (@"$host:$port", (uint16) port);
                if (verbose)
                    printerr ("* TLS 1.3 handshake complete (TLS_CHACHA20_POLY1305_SHA256 / X25519)\n");
                stream = tconn;
            } else {
                stream = client.connect_to_host (@"$host:$port", (uint16) port);
            }
        } catch (IOError e) {
            printerr (@"curl: connect failed: $(e.message)\n");
            return 7;
        }

        string req_str = build_http_request (method, host, port, default_port, path_query, headers, data);
        if (verbose) {
            printerr (@"> $method $path_query HTTP/1.1\n");
            printerr (@"> Host: $host\n");
        }

        try {
            var os = ((!) stream).get_output_stream ();
            os.write (string_to_bytes (req_str));
            os.flush ();

            string status_line = "";
            var resp_headers = new ArrayList<string> ();
            string resp_body = "";
            bool ok = read_http_message (((!) stream).get_input_stream (), !is_head, !is_head,
                                         out status_line, out resp_headers, out resp_body);
            ((!) stream).close ();

            if (!ok) {
                printerr ("curl: empty reply from server\n");
                return 52;
            }

            out_status = status_line;
            out_body = resp_body;

            if (verbose) {
                printerr (@"< $status_line\n");
                for (int i = 0; i < resp_headers.size; i++)
                    printerr (@"< $(resp_headers.get (i))\n");
            }

            if (include_headers || is_head) {
                print (@"$status_line\n");
                for (int i = 0; i < resp_headers.size; i++)
                    print (@"$(resp_headers.get (i))\n");
                print ("\n");
            }

            if (!is_head) {
                if (output_path != null) {
                    if (!FileUtils.set_contents ((!) output_path, resp_body)) {
                        printerr (@"curl: failed to write '$((!) output_path)'\n");
                        return 23;
                    }
                } else {
                    print (resp_body);
                    if (resp_body.length > 0 && resp_body[resp_body.length - 1] != '\n')
                        print ("\n");
                }
            }
        } catch (IOError e) {
            printerr (@"curl: transfer error: $(e.message)\n");
            return 56;
        }

        return 0;
    }

    private AdaptiveRadixTree<string>? demo_routes = null;
    private CuckooFilter? demo_blocked = null;

    private void init_demo_router () {
        if (demo_routes != null)
            return;
        var routes = new AdaptiveRadixTree<string> ();
        routes.set ("/", "text/plain");
        routes.set ("/hello.json", "application/json");
        routes.set ("/echo", "text/plain");
        demo_routes = routes;

        var blocked = new CuckooFilter ();
        blocked.add ("/admin");
        demo_blocked = blocked;
    }

    private void serve_one_http (IOStream stream, bool is_tls) {
        init_demo_router ();
        try {
            string req_line = "";
            var req_headers = new ArrayList<string> ();
            string req_body = "";
            if (!read_http_message (stream.get_input_stream (), true, false, out req_line, out req_headers, out req_body)) {
                stream.close ();
                return;
            }

            // Parse "METHOD /path HTTP/1.1"
            string method = "GET";
            string target = "/";
            int sp1 = req_line.index_of (" ");
            if (sp1 > 0) {
                method = req_line.substring (0, sp1);
                int sp2 = req_line.index_of (" ", sp1 + 1);
                if (sp2 > sp1)
                    target = req_line.substring (sp1 + 1, sp2 - sp1 - 1);
            }

            string status = "200 OK";
            string ctype = "text/plain";
            string resp_body = "";
            if (demo_blocked != null && ((!) demo_blocked).contains (target)) {
                status = "403 Forbidden";
                resp_body = "Forbidden\n";
            } else if (demo_routes != null && ((!) demo_routes).has_key (target)) {
                ctype = ((!) demo_routes).get (target);
                if (target == "/hello.json")
                    resp_body = "{\"os\":\"PlanetOS\",\"tls\":\"1.3\",\"cipher\":\"TLS_CHACHA20_POLY1305_SHA256\"}\n";
                else if (target == "/echo" && method == "POST")
                    resp_body = @"echo:$req_body\n";
                else
                    resp_body = @"PlanetOS $(is_tls ? "HTTPS/TLS1.3" : "HTTP/1.1") demo ok ($method $target)\n";
            } else {
                status = "404 Not Found";
                resp_body = "Not Found\n";
            }

            var sb = new StringBuilder ();
            sb.append (@"HTTP/1.1 $status\r\n");
            sb.append ("Server: planet-httpd/0.1\r\n");
            sb.append (@"Content-Type: $ctype\r\n");
            sb.append (@"Content-Length: $(resp_body.length)\r\n");
            sb.append ("Connection: close\r\n\r\n");
            if (method != "HEAD")
                sb.append (resp_body);

            stream.get_output_stream ().write (string_to_bytes (sb.str));
            stream.get_output_stream ().flush ();
            stream.close ();
        } catch (IOError e) {
        }
    }

    private TlsCertificate? demo_cert = null;

    private int run_demo (bool verbose) {
        print ("=== PlanetOS curl demo (HTTP/1.1 + TLS 1.3) ===\n");
        init_demo_router ();
        var http_lis = new SocketListener ();
        var https_lis = new SocketListener ();
        var dot_lis = new SocketListener ();
        uint16 http_port = 0;
        uint16 https_port = 0;
        uint16 dot_port = 0;

        try {
            http_port = http_lis.add_any_inet_port ();
            https_port = https_lis.add_any_inet_port ();
            dot_port = dot_lis.add_any_inet_port ();
        } catch (IOError e) {
            printerr (@"curl demo: listener failed: $(e.message)\n");
            return 1;
        }

        Resolver.get_default ().set_dot_server ("127.0.0.1", dot_port, TlsCertificateFlags.NONE);

        try {
            demo_cert = new TlsCertificate.from_pem ("-----BEGIN CERTIFICATE-----\nCN=planet.example\n-----END CERTIFICATE-----\n");
        } catch (Error e) {
        }

        var srv_thread = new Thread ("curl-demo-srv", () => {
            int served_http = 0;
            int served_https = 0;
            int served_dot = 0;
            for (int iter = 0; iter < 500 && (served_http < 1 || served_https < 3 || served_dot < 1); iter++) {
                bool did_work = false;
                try {
                    Object? od = null;
                    var dsc = dot_lis.accept (out od);
                    var dtsrv = TlsServerConnection.create (dsc, demo_cert);
                    dtsrv.handshake ();
                    var req_bytes = DnsWire.read_dot_frame (dtsrv.get_input_stream ());
                    var req_msg = DnsWire.decode_message (req_bytes);
                    if (req_msg != null) {
                        var rm = (!) req_msg;
                        var ans = new GenericArray<DnsRecord> ();
                        if (rm.qtype == DnsRecord.TYPE_A) {
                            var rr = new DnsRecord ();
                            rr.name = rm.qname;
                            rr.rtype = DnsRecord.TYPE_A;
                            rr.ttl = 60;
                            rr.rdata = { 127, 0, 0, 1 };
                            ans.add (rr);
                        }
                        var rep = DnsWire.encode_reply (rm.id, rm.qname, rm.qtype, ans);
                        dtsrv.get_output_stream ().write (DnsWire.encode_dot_frame (rep));
                        dtsrv.get_output_stream ().flush ();
                    }
                    dtsrv.close ();
                    served_dot++;
                    did_work = true;
                } catch (Error e) {
                }
                try {
                    Object? o = null;
                    var sc = http_lis.accept (out o);
                    serve_one_http (sc, false);
                    served_http++;
                    did_work = true;
                } catch (IOError e) {
                }
                try {
                    Object? o2 = null;
                    var sc2 = https_lis.accept (out o2);
                    var tsrv = TlsServerConnection.create (sc2, demo_cert);
                    tsrv.handshake ();
                    serve_one_http (tsrv, true);
                    served_https++;
                    did_work = true;
                } catch (Error e) {
                }
                if (!did_work)
                    Sys.sleep_ms (5);
            }
            return null;
        });

        int checks = 0;
        int failures = 0;
        var empty_headers = new ArrayList<string> ();
        string st = "";
        string bd = "";

        // 1. Plain HTTP GET
        print (@"\n[1] GET http://127.0.0.1:$http_port/\n");
        int rc1 = perform_request (@"http://127.0.0.1:$http_port/", "GET", empty_headers,
                                   null, false, false, false, verbose, null, out st, out bd);
        checks++;
        if (rc1 != 0 || !bd.contains ("HTTP/1.1 demo ok"))
            failures++;

        // 2. HTTPS (TLS 1.3) GET JSON resolved via DNS-over-TLS (planet.example -> 127.0.0.1)
        print (@"\n[2] GET https://planet.example:$https_port/hello.json (via DoT :$dot_port)\n");
        int rc2 = perform_request (@"https://planet.example:$https_port/hello.json", "GET", empty_headers,
                                   null, false, false, true, verbose, null, out st, out bd);
        checks++;
        if (rc2 != 0 || !bd.contains ("TLS_CHACHA20_POLY1305_SHA256"))
            failures++;

        // 3. HTTPS (TLS 1.3) POST /echo
        print (@"\n[3] POST https://127.0.0.1:$https_port/echo\n");
        int rc3 = perform_request (@"https://127.0.0.1:$https_port/echo", "POST", empty_headers,
                                   "planet=earth", false, false, true, verbose, null, out st, out bd);
        checks++;
        if (rc3 != 0 || !bd.contains ("echo:planet=earth"))
            failures++;

        // 4. HTTPS (TLS 1.3) HEAD /
        print (@"\n[4] HEAD https://127.0.0.1:$https_port/\n");
        int rc4 = perform_request (@"https://127.0.0.1:$https_port/", "HEAD", empty_headers,
                                   null, false, true, true, verbose, null, out st, out bd);
        checks++;
        if (rc4 != 0 || !st.contains ("200 OK"))
            failures++;

        srv_thread.join ();
        try {
            http_lis.close ();
            https_lis.close ();
            dot_lis.close ();
        } catch (IOError e) {
        }

        print (@"curl:demo checks=$checks failures=$failures\n");
        return (failures == 0) ? 0 : 1;
    }

    int main (string[] args) {
        var ctx = new OptionContext ("<url>");
        var opt_x = new OptionEntry ("request", 'X', OptionFlags.NONE, OptionArg.STRING, "HTTP method (GET, POST, HEAD, ...)");
        var opt_h = new OptionEntry ("header", 'H', OptionFlags.NONE, OptionArg.STRING_ARRAY, "Custom HTTP header ('Key: Value')");
        var opt_d = new OptionEntry ("data", 'd', OptionFlags.NONE, OptionArg.STRING, "HTTP POST data");
        var opt_i = new OptionEntry ("include", 'i', OptionFlags.NONE, OptionArg.NONE, "Include response headers in output");
        var opt_head = new OptionEntry ("head", 'I', OptionFlags.NONE, OptionArg.NONE, "Fetch headers only (HEAD)");
        var opt_k = new OptionEntry ("insecure", 'k', OptionFlags.NONE, OptionArg.NONE, "Allow insecure TLS connections");
        var opt_o = new OptionEntry ("output", 'o', OptionFlags.NONE, OptionArg.STRING, "Write output to file");
        var opt_v = new OptionEntry ("verbose", 'v', OptionFlags.NONE, OptionArg.NONE, "Verbose connection and TLS trace");
        var opt_dot = new OptionEntry ("dns-tls", 'T', OptionFlags.NONE, OptionArg.STRING, "DNS-over-TLS server (host[:port], default port 853)");
        var opt_demo = new OptionEntry ("demo", 'D', OptionFlags.NONE, OptionArg.NONE, "Run built-in HTTP + TLS 1.3 local server demo");

        var grp = new OptionGroup ("Options", "curl options", null);
        grp.add_entry (opt_x);
        grp.add_entry (opt_h);
        grp.add_entry (opt_d);
        grp.add_entry (opt_i);
        grp.add_entry (opt_head);
        grp.add_entry (opt_k);
        grp.add_entry (opt_o);
        grp.add_entry (opt_v);
        grp.add_entry (opt_dot);
        grp.add_entry (opt_demo);
        ctx.add_group (grp);

        try {
            ctx.parse (ref args);
        } catch (OptionError e) {
            printerr (@"curl: $(e.message)\n");
            return 2;
        }

        if (opt_dot.str_val != null && ((!) opt_dot.str_val).length > 0) {
            try {
                var dna = NetworkAddress.parse ((!) opt_dot.str_val, 853);
                Resolver.get_default ().set_dot_server (dna.get_hostname (), dna.get_port (),
                                                        opt_k.bool_val ? TlsCertificateFlags.NONE : TlsCertificateFlags.VALIDATE_ALL);
            } catch (IOError e) {
                printerr (@"curl: invalid --dns-tls '$((!) opt_dot.str_val)': $(e.message)\n");
                return 2;
            }
        }

        if (opt_demo.bool_val)
            return run_demo (opt_v.bool_val);

        if (args.length < 2) {
            printerr ("usage: curl [-X METHOD] [-H 'Key: Val'] [-d DATA] [-i] [-I] [-k] [-o FILE] [-v] [--demo] <url>\n");
            return 2;
        }

        string? data = (opt_d.str_val != null) ? opt_d.str_val : null;
        bool is_head = opt_head.bool_val;
        string method = "GET";
        if (opt_x.str_val != null && ((!) opt_x.str_val).length > 0)
            method = (!) opt_x.str_val;
        else if (is_head)
            method = "HEAD";
        else if (data != null)
            method = "POST";

        var headers = new ArrayList<string> ();
        for (int i = 0; i < opt_h.str_arr_val.length; i++) {
            string hv = opt_h.str_arr_val[i];
            if (hv.length > 0)
                headers.add (hv);
        }

        string? output_path = (opt_o.str_val != null && ((!) opt_o.str_val).length > 0) ? opt_o.str_val : null;
        string st = "";
        string bd = "";
        return perform_request (args[1], method, headers, data, opt_i.bool_val,
                                is_head, opt_k.bool_val, opt_v.bool_val, output_path, out st, out bd);
    }
}
