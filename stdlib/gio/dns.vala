// Pure-Vala GIO DNS & GLib.Resolver service inspired by Go net/dnsclient.go,
// GTK/GIO GLib.Resolver, RFC 9156 (QNAME Minimisation), and RFC 7858 (DNS-over-TLS, port 853).
using GLib;
using Planet;

namespace Gio {

    public enum ResolverRecordType {
        SRV = 1,
        MX = 2,
        TXT = 3,
        SOA = 4,
        NS = 5
    }

    [Flags]
    public enum ResolverNameLookupFlags {
        DEFAULT = 0,
        IPV4_ONLY = 1,
        IPV6_ONLY = 2
    }

    public errordomain ResolverError {
        NOT_FOUND,
        TEMPORARY_FAILURE,
        INTERNAL
    }

    public class SrvTarget : Object {
        public string hostname { get; private set; }
        public uint16 port { get; private set; }
        public uint16 priority { get; private set; }
        public uint16 weight { get; private set; }

        public SrvTarget (string hostname, uint16 port, uint16 priority, uint16 weight) {
            this.hostname = hostname;
            this.port = port;
            this.priority = priority;
            this.weight = weight;
        }

        public string get_hostname () { return hostname; }
        public uint16 get_port () { return port; }
        public uint16 get_priority () { return priority; }
        public uint16 get_weight () { return weight; }

        public static GenericArray<SrvTarget> list_sort (GenericArray<SrvTarget> targets) {
            // Sort ascending by priority, then descending by weight (RFC 2782)
            for (int i = 0; i < targets.length; i++) {
                for (int j = i + 1; j < targets.length; j++) {
                    var a = targets[i];
                    var b = targets[j];
                    bool swap = false;
                    if (b.priority < a.priority)
                        swap = true;
                    else if (b.priority == a.priority && b.weight > a.weight)
                        swap = true;
                    if (swap) {
                        targets[i] = b;
                        targets[j] = a;
                    }
                }
            }
            return targets;
        }
    }

    public class DnsRecord : Object {
        public const uint16 TYPE_A = 1;
        public const uint16 TYPE_NS = 2;
        public const uint16 TYPE_CNAME = 5;
        public const uint16 TYPE_SOA = 6;
        public const uint16 TYPE_PTR = 12;
        public const uint16 TYPE_MX = 15;
        public const uint16 TYPE_TXT = 16;
        public const uint16 TYPE_AAAA = 28;
        public const uint16 TYPE_SRV = 33;

        public string name = "";
        public uint16 rtype = 0;
        public uint16 rclass = 1;
        public uint32 ttl = 60;
        public string target = "";
        public uint16 priority = 0;
        public uint16 weight = 0;
        public uint16 port = 0;
        public uint8[] rdata = new uint8[0];
    }

    public class DnsMessage : Object {
        public uint16 id = 0;
        public uint16 flags = 0x0100; // RD=1
        public string qname = "";
        public uint16 qtype = DnsRecord.TYPE_A;
        public uint16 qclass = 1;
        public GenericArray<DnsRecord> answers = new GenericArray<DnsRecord> ();

        public uint8 rcode () {
            return (uint8) (flags & 0x000F);
        }
    }

    // RFC 1035 wire codec + RFC 9156 QNAME minimisation + RFC 7858 DNS-over-TLS framing
    public class DnsWire : Object {
        private static void write_be16 (ByteArray ba, uint16 val) {
            uint16 be = GLib.to_be16 (val);
            ba.append_byte ((uint8) (be & 0xFF));
            ba.append_byte ((uint8) ((be >> 8) & 0xFF));
        }

        private static void write_be32 (ByteArray ba, uint32 val) {
            uint32 be = GLib.to_be32 (val);
            ba.append_byte ((uint8) (be & 0xFF));
            ba.append_byte ((uint8) ((be >> 8) & 0xFF));
            ba.append_byte ((uint8) ((be >> 16) & 0xFF));
            ba.append_byte ((uint8) ((be >> 24) & 0xFF));
        }

        private static uint16 read_be16 (uint8[] buf, int off) {
            uint16 raw = (uint16) (((uint16) buf[off]) | ((uint16) buf[off + 1] << 8));
            return GLib.from_be16 (raw);
        }

        private static uint32 read_be32 (uint8[] buf, int off) {
            uint32 raw = ((uint32) buf[off])
                       | ((uint32) buf[off + 1] << 8)
                       | ((uint32) buf[off + 2] << 16)
                       | ((uint32) buf[off + 3] << 24);
            return GLib.from_be32 (raw);
        }

        public static bool encode_name (ByteArray ba, string name) {
            string s = Str.strip (name);
            if (s.length == 0 || s == ".") {
                ba.append_byte (0);
                return true;
            }
            int i = 0;
            while (i < s.length) {
                int dot = s.index_of (".", i);
                int end = (dot >= 0) ? dot : s.length;
                int lab_len = end - i;
                if (lab_len <= 0 || lab_len > 63)
                    return false;
                ba.append_byte ((uint8) lab_len);
                for (int k = i; k < end; k++)
                    ba.append_byte ((uint8) s[k]);
                i = end + 1;
            }
            ba.append_byte (0);
            return true;
        }

        // Compression-safe RFC 1035 name decoder with pointer loop-guard (max 16 jumps).
        public static bool decode_name (uint8[] msg, int start_off, out string name, out int next_off) {
            name = "";
            next_off = start_off;
            var sb = new StringBuilder ();
            int off = start_off;
            bool jumped = false;
            int jumps = 0;

            while (off < msg.length) {
                uint8 len = msg[off];
                if (len == 0) {
                    if (!jumped)
                        next_off = off + 1;
                    name = sb.str;
                    return true;
                }
                if ((len & 0xC0) == 0xC0) {
                    if (off + 1 >= msg.length || ++jumps > 16)
                        return false;
                    int ptr = (((int) (len & 0x3F)) << 8) | (int) msg[off + 1];
                    if (ptr >= msg.length)
                        return false;
                    if (!jumped)
                        next_off = off + 2;
                    jumped = true;
                    off = ptr;
                    continue;
                }
                if ((len & 0xC0) != 0)
                    return false;
                off++;
                if (off + (int) len > msg.length)
                    return false;
                if (sb.len > 0)
                    sb.append (".");
                for (int i = 0; i < (int) len; i++)
                    sb.append_c ((char) msg[off + i]);
                off += (int) len;
            }
            return false;
        }

        public static uint8[] encode_query (uint16 id, string qname, uint16 qtype, uint16 qclass = 1) {
            var ba = new ByteArray.sized (64);
            write_be16 (ba, id);
            write_be16 (ba, 0x0100); // RD=1
            write_be16 (ba, 1);      // QDCOUNT=1
            write_be16 (ba, 0);      // ANCOUNT=0
            write_be16 (ba, 0);      // NSCOUNT=0
            write_be16 (ba, 0);      // ARCOUNT=0
            encode_name (ba, qname);
            write_be16 (ba, qtype);
            write_be16 (ba, qclass);
            return ba.steal ();
        }

        public static uint8[] encode_reply (uint16 id, string qname, uint16 qtype, GenericArray<DnsRecord> answers, uint8 rcode = 0) {
            var ba = new ByteArray.sized (128);
            write_be16 (ba, id);
            uint16 fl = (uint16) (0x8180 | (rcode & 0x0F)); // QR=1, RD=1, RA=1
            write_be16 (ba, fl);
            write_be16 (ba, 1);
            write_be16 (ba, (uint16) answers.length);
            write_be16 (ba, 0);
            write_be16 (ba, 0);
            encode_name (ba, qname);
            write_be16 (ba, qtype);
            write_be16 (ba, 1);

            for (int i = 0; i < answers.length; i++) {
                var rr = answers[i];
                encode_name (ba, rr.name.length > 0 ? rr.name : qname);
                write_be16 (ba, rr.rtype);
                write_be16 (ba, rr.rclass);
                write_be32 (ba, rr.ttl);
                if (rr.rtype == DnsRecord.TYPE_A && rr.rdata.length == 4) {
                    write_be16 (ba, 4);
                    for (int k = 0; k < 4; k++) ba.append_byte (rr.rdata[k]);
                } else if (rr.rtype == DnsRecord.TYPE_AAAA && rr.rdata.length == 16) {
                    write_be16 (ba, 16);
                    for (int k = 0; k < 16; k++) ba.append_byte (rr.rdata[k]);
                } else if (rr.rtype == DnsRecord.TYPE_TXT) {
                    int tlen = (rr.target.length > 255) ? 255 : rr.target.length;
                    write_be16 (ba, (uint16) (tlen + 1));
                    ba.append_byte ((uint8) tlen);
                    for (int k = 0; k < tlen; k++) ba.append_byte ((uint8) rr.target[k]);
                } else if (rr.rtype == DnsRecord.TYPE_SRV) {
                    var sub = new ByteArray.sized (64);
                    write_be16 (sub, rr.priority);
                    write_be16 (sub, rr.weight);
                    write_be16 (sub, rr.port);
                    encode_name (sub, rr.target);
                    write_be16 (ba, (uint16) sub.len);
                    ba.append (sub.steal ());
                } else if (rr.rtype == DnsRecord.TYPE_MX) {
                    var sub = new ByteArray.sized (64);
                    write_be16 (sub, rr.priority);
                    encode_name (sub, rr.target);
                    write_be16 (ba, (uint16) sub.len);
                    ba.append (sub.steal ());
                } else if (rr.rtype == DnsRecord.TYPE_CNAME || rr.rtype == DnsRecord.TYPE_PTR || rr.rtype == DnsRecord.TYPE_NS) {
                    var sub = new ByteArray.sized (64);
                    encode_name (sub, rr.target);
                    write_be16 (ba, (uint16) sub.len);
                    ba.append (sub.steal ());
                } else {
                    write_be16 (ba, (uint16) rr.rdata.length);
                    for (int k = 0; k < rr.rdata.length; k++) ba.append_byte (rr.rdata[k]);
                }
            }

            return ba.steal ();
        }

        public static DnsMessage? decode_message (uint8[] msg) {
            if (msg.length < 12)
                return null;
            var dm = new DnsMessage ();
            dm.id = read_be16 (msg, 0);
            dm.flags = read_be16 (msg, 2);
            uint16 qd = read_be16 (msg, 4);
            uint16 an = read_be16 (msg, 6);
            int off = 12;

            for (int q = 0; q < (int) qd; q++) {
                string qn = "";
                int next = 0;
                if (!decode_name (msg, off, out qn, out next) || next + 4 > msg.length)
                    return null;
                if (q == 0) {
                    dm.qname = qn;
                    dm.qtype = read_be16 (msg, next);
                    dm.qclass = read_be16 (msg, next + 2);
                }
                off = next + 4;
            }

            for (int a = 0; a < (int) an; a++) {
                string rname = "";
                int next = 0;
                if (!decode_name (msg, off, out rname, out next) || next + 10 > msg.length)
                    break;
                var rr = new DnsRecord ();
                rr.name = rname;
                rr.rtype = read_be16 (msg, next);
                rr.rclass = read_be16 (msg, next + 2);
                rr.ttl = read_be32 (msg, next + 4);
                uint16 rdlen = read_be16 (msg, next + 8);
                int rdoff = next + 10;
                if (rdoff + (int) rdlen > msg.length)
                    break;

                rr.rdata = new uint8[(int) rdlen];
                if (rdlen > 0)
                    Memory.copy (Sys.byte_arr_addr (rr.rdata), Sys.byte_arr_addr (msg) + rdoff, (size_t) rdlen);

                if (rr.rtype == DnsRecord.TYPE_TXT && rdlen >= 1) {
                    int tlen = (int) msg[rdoff];
                    if (tlen > (int) rdlen - 1) tlen = (int) rdlen - 1;
                    var sb = new StringBuilder ();
                    for (int k = 0; k < tlen; k++) sb.append_c ((char) msg[rdoff + 1 + k]);
                    rr.target = sb.str;
                } else if (rr.rtype == DnsRecord.TYPE_SRV && rdlen >= 7) {
                    rr.priority = read_be16 (msg, rdoff);
                    rr.weight = read_be16 (msg, rdoff + 2);
                    rr.port = read_be16 (msg, rdoff + 4);
                    string tgt = "";
                    int dummy = 0;
                    if (decode_name (msg, rdoff + 6, out tgt, out dummy))
                        rr.target = tgt;
                } else if (rr.rtype == DnsRecord.TYPE_MX && rdlen >= 3) {
                    rr.priority = read_be16 (msg, rdoff);
                    string tgt = "";
                    int dummy = 0;
                    if (decode_name (msg, rdoff + 2, out tgt, out dummy))
                        rr.target = tgt;
                } else if (rr.rtype == DnsRecord.TYPE_CNAME || rr.rtype == DnsRecord.TYPE_PTR || rr.rtype == DnsRecord.TYPE_NS) {
                    string tgt = "";
                    int dummy = 0;
                    if (decode_name (msg, rdoff, out tgt, out dummy))
                        rr.target = tgt;
                }

                dm.answers.add (rr);
                off = rdoff + (int) rdlen;
            }
            return dm;
        }

        // RFC 9156 §2: Progressive QNAME minimisation label sequence
        // e.g. "a.b.example.com" -> ["com", "example.com", "b.example.com", "a.b.example.com"]
        public static GenericArray<string> qname_minimise_steps (string qname) {
            var steps = new GenericArray<string> ();
            string s = Str.strip (qname);
            while (s.length > 0 && s[s.length - 1] == '.')
                s = s.substring (0, s.length - 1);
            if (s.length == 0)
                return steps;
            var parts = new GenericArray<string> ();
            int i = 0;
            while (i < s.length) {
                int dot = s.index_of (".", i);
                int end = (dot >= 0) ? dot : s.length;
                if (end > i)
                    parts.add (s.substring (i, end - i));
                i = end + 1;
            }
            string acc = "";
            for (int k = parts.length - 1; k >= 0; k--) {
                acc = (acc.length == 0) ? parts[k] : @"$(parts[k]).$acc";
                steps.add (acc);
            }
            return steps;
        }

        // RFC 7858 §3.3: 2-byte big-endian length-prefixed DNS-over-TLS frame
        public static uint8[] encode_dot_frame (uint8[] dns_msg) {
            var frame = new uint8[2 + dns_msg.length];
            uint16 be = GLib.to_be16 ((uint16) dns_msg.length);
            frame[0] = (uint8) (be & 0xFF);
            frame[1] = (uint8) ((be >> 8) & 0xFF);
            if (dns_msg.length > 0)
                Memory.copy (Sys.byte_arr_addr (frame) + 2, Sys.byte_arr_addr (dns_msg), (size_t) dns_msg.length);
            return frame;
        }

        private static void read_exact (InputStream ins, uint8[] dst) throws IOError {
            int got = 0;
            int tries = 0;
            while (got < dst.length) {
                var tmp = new uint8[dst.length - got];
                int n = ins.read (tmp);
                if (n < 0)
                    throw new IOError.FAILED ("DoT unexpected EOF");
                if (n == 0) {
                    if (++tries > 200)
                        throw new IOError.TIMED_OUT ("DoT read timeout");
                    Sys.sleep_ms (5);
                    continue;
                }
                Memory.copy (Sys.byte_arr_addr (dst) + got, Sys.byte_arr_addr (tmp), (size_t) n);
                got += n;
            }
        }

        public static uint8[] read_dot_frame (InputStream ins) throws IOError {
            var len_buf = new uint8[2];
            read_exact (ins, len_buf);
            uint16 flen = read_be16 (len_buf, 0);
            if (flen == 0 || flen > 4096)
                throw new IOError.FAILED ("Invalid DoT frame length");
            var payload = new uint8[(int) flen];
            read_exact (ins, payload);
            return payload;
        }
    }

    private class DnsCacheEntry : Object {
        public GenericArray<InetAddress> addrs = new GenericArray<InetAddress> ();
        public int64 expires_tick = 0;
    }

    public class Resolver : Object {
        private static int once_state = 0;
        private static Resolver? default_resolver;

        private HashTable<string, int> cache_idx = new HashTable<string, int> (str_hash, str_equal);
        private GenericArray<DnsCacheEntry> cache_entries = new GenericArray<DnsCacheEntry> ();
        private HashTable<string, string> hosts = new HashTable<string, string> (str_hash, str_equal);
        private string? dot_server_host = null;
        private uint16 dot_server_port = 853;
        private TlsCertificateFlags dot_tls_flags = TlsCertificateFlags.VALIDATE_ALL;
        private uint16 next_txid = 0x1001;

        public Resolver () {
            hosts.insert ("localhost", "127.0.0.1");
            hosts.insert ("planetos.local", "127.0.0.1");
            hosts.insert ("gateway", "10.0.2.2");
            hosts.insert ("slirp", "10.0.2.2");
            hosts.insert ("cloudflare-dns.com", "1.1.1.1");
        }

        public static Resolver get_default () {
            while (AtomicInt.get (ref once_state) != 2) {
                if (AtomicInt.compare_and_exchange (ref once_state, 0, 1)) {
                    default_resolver = new Resolver ();
                    AtomicInt.set (ref once_state, 2);
                    break;
                }
                Sys.yield_cpu ();
            }
            return (!) default_resolver;
        }

        public static void set_default (Resolver resolver) {
            default_resolver = resolver;
            AtomicInt.set (ref once_state, 2);
        }

        public void set_dot_server (string? host, uint16 port = 853, TlsCertificateFlags flags = TlsCertificateFlags.VALIDATE_ALL) {
            this.dot_server_host = host;
            this.dot_server_port = port;
            this.dot_tls_flags = flags;
        }

        public void add_host (string hostname, string ip_str) {
            hosts.insert (Str.ascii_down (Str.strip (hostname)), ip_str);
        }

        private static uint16 random_txid () {
            var b = new uint8[2];
            TlsCrypto.random_bytes (b);
            uint16 id = (uint16) (((uint16) b[0] << 8) | (uint16) b[1]);
            return (id == 0) ? 1 : id;
        }

        private void cache_store (string key, GenericArray<InetAddress> addrs, uint32 ttl_sec) {
            if (cache_entries.length >= 256) {
                cache_entries = new GenericArray<DnsCacheEntry> ();
                cache_idx = new HashTable<string, int> (str_hash, str_equal);
            }
            var ce = new DnsCacheEntry ();
            ce.addrs = addrs;
            ce.expires_tick = (int64) Sys.ticks () + (int64) ttl_sec * 100;
            int idx = cache_entries.length;
            cache_entries.add (ce);
            cache_idx.insert (key, idx);
        }

        private DnsMessage query_dot (string qname, uint16 qtype) throws IOError {
            if (dot_server_host == null)
                throw new IOError.HOST_NOT_FOUND (@"No DoT upstream configured for $qname");
            var client = new SocketClient ();
            client.protocol = SocketProtocol.TCP;
            client.tls = true;
            client.tls_validation_flags = dot_tls_flags;
            var tconn = client.connect_to_host_tls (@"$((!) dot_server_host):$dot_server_port", dot_server_port);
            uint16 txid = random_txid ();
            var q = DnsWire.encode_query (txid, qname, qtype);
            var frame = DnsWire.encode_dot_frame (q);
            tconn.get_output_stream ().write (frame);
            tconn.get_output_stream ().flush ();
            var reply_bytes = DnsWire.read_dot_frame (tconn.get_input_stream ());
            tconn.close ();
            var msg = DnsWire.decode_message (reply_bytes);
            if (msg == null || ((!) msg).id != txid || Str.ascii_down (((!) msg).qname) != Str.ascii_down (qname))
                throw new IOError.FAILED ("Invalid DoT DNS reply");
            return (!) msg;
        }

        public GenericArray<InetAddress> lookup_by_name (string hostname, Cancellable? cancellable = null) throws IOError {
            return lookup_by_name_with_flags (hostname, ResolverNameLookupFlags.DEFAULT, cancellable);
        }

        public GenericArray<InetAddress> lookup_by_name_with_flags (string hostname, ResolverNameLookupFlags flags,
                                                                    Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Resolver.lookup_by_name cancelled");
            var res = new GenericArray<InetAddress> ();
            var literal = InetAddress.new_from_string (hostname);
            if (literal != null) {
                res.add ((!) literal);
                return res;
            }
            string key = Str.ascii_down (Str.strip (hostname));
            if (hosts.contains (key)) {
                string? ip_s = hosts.lookup (key);
                if (ip_s != null && ((!) ip_s).length > 0) {
                    var ia = InetAddress.new_from_string ((!) ip_s);
                    if (ia != null) {
                        res.add ((!) ia);
                        return res;
                    }
                }
            }

            if (cache_idx.contains (key)) {
                int idx = cache_idx.lookup (key);
                if (idx >= 0 && idx < cache_entries.length) {
                    var ent = cache_entries[idx];
                    if ((int64) Sys.ticks () < ent.expires_tick)
                        return ent.addrs;
                }
            }

            if (dot_server_host != null) {
                var msg = query_dot (key, DnsRecord.TYPE_A);
                uint32 min_ttl = 60;
                for (int i = 0; i < msg.answers.length; i++) {
                    var rr = msg.answers[i];
                    if (rr.rtype == DnsRecord.TYPE_A && rr.rdata.length == 4) {
                        res.add (new InetAddress.from_bytes (rr.rdata, SocketFamily.IPV4));
                        if (rr.ttl < min_ttl) min_ttl = rr.ttl;
                    } else if (rr.rtype == DnsRecord.TYPE_AAAA && rr.rdata.length == 16
                               && (flags & ResolverNameLookupFlags.IPV4_ONLY) == 0) {
                        res.add (new InetAddress.from_bytes (rr.rdata, SocketFamily.IPV6));
                    }
                }
                if (res.length > 0) {
                    cache_store (key, res, min_ttl);
                    return res;
                }
            } else {
                // Default: query QEMU SLIRP / system UDP DNS (10.0.2.3:53) over VirtioNetStack
                try {
                    uint8[] dns_ip = { 10, 0, 2, 3 };
                    uint16 txid = random_txid ();
                    var q = DnsWire.encode_query (txid, key, DnsRecord.TYPE_A);
                    var rep_bytes = VirtioNetStack.get_default ().udp_query (dns_ip, 53, q);
                    var msg = DnsWire.decode_message (rep_bytes);
                    if (msg != null && ((!) msg).id == txid && Str.ascii_down (((!) msg).qname) == key) {
                        var m = (!) msg;
                        uint32 min_ttl = 60;
                        for (int i = 0; i < m.answers.length; i++) {
                            var rr = m.answers[i];
                            if (rr.rtype == DnsRecord.TYPE_A && rr.rdata.length == 4) {
                                res.add (new InetAddress.from_bytes (rr.rdata, SocketFamily.IPV4));
                                if (rr.ttl < min_ttl) min_ttl = rr.ttl;
                            }
                        }
                        if (res.length > 0) {
                            cache_store (key, res, min_ttl);
                            return res;
                        }
                    }
                } catch (IOError e) {
                }
            }

            throw new IOError.HOST_NOT_FOUND (@"Unknown host: $hostname");
        }

        public string lookup_by_address (InetAddress address, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Resolver.lookup_by_address cancelled");
            string ip = address.to_string ();
            if (ip == "127.0.0.1")
                return "localhost";
            if (ip == "10.0.2.2")
                return "gateway";
            if (dot_server_host != null && address.get_family () == SocketFamily.IPV4) {
                var b = address.to_bytes ();
                string ptr_name = @"$(b[3]).$(b[2]).$(b[1]).$(b[0]).in-addr.arpa";
                var msg = query_dot (ptr_name, DnsRecord.TYPE_PTR);
                for (int i = 0; i < msg.answers.length; i++) {
                    if (msg.answers[i].rtype == DnsRecord.TYPE_PTR && msg.answers[i].target.length > 0)
                        return msg.answers[i].target;
                }
            }
            throw new IOError.HOST_NOT_FOUND (@"PTR not found for $ip");
        }

        public GenericArray<Variant> lookup_records (string rrname, ResolverRecordType record_type,
                                                     Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Resolver.lookup_records cancelled");
            uint16 qtype = DnsRecord.TYPE_SRV;
            if (record_type == ResolverRecordType.MX) qtype = DnsRecord.TYPE_MX;
            else if (record_type == ResolverRecordType.TXT) qtype = DnsRecord.TYPE_TXT;
            else if (record_type == ResolverRecordType.SOA) qtype = DnsRecord.TYPE_SOA;
            else if (record_type == ResolverRecordType.NS) qtype = DnsRecord.TYPE_NS;

            var msg = query_dot (rrname, qtype);
            var out_list = new GenericArray<Variant> ();
            for (int i = 0; i < msg.answers.length; i++) {
                var rr = msg.answers[i];
                if (rr.rtype == DnsRecord.TYPE_TXT) {
                    string[] strs = { rr.target };
                    Variant[] items = { Variant.new_strv (strs) };
                    out_list.add (Variant.new_tuple (items));
                } else if (rr.rtype == DnsRecord.TYPE_SRV) {
                    Variant[] items = {
                        Variant.new_uint16 (rr.priority),
                        Variant.new_uint16 (rr.weight),
                        Variant.new_uint16 (rr.port),
                        Variant.new_string (rr.target)
                    };
                    out_list.add (Variant.new_tuple (items));
                } else if (rr.rtype == DnsRecord.TYPE_MX) {
                    Variant[] items = {
                        Variant.new_uint16 (rr.priority),
                        Variant.new_string (rr.target)
                    };
                    out_list.add (Variant.new_tuple (items));
                } else if (rr.rtype == DnsRecord.TYPE_NS) {
                    Variant[] items = { Variant.new_string (rr.target) };
                    out_list.add (Variant.new_tuple (items));
                }
            }
            return out_list;
        }

        public GenericArray<SrvTarget> lookup_service (string service, string protocol, string domain,
                                                       Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Resolver.lookup_service cancelled");
            string rrname = @"_$(service)._$(protocol).$domain";
            var msg = query_dot (rrname, DnsRecord.TYPE_SRV);
            var list = new GenericArray<SrvTarget> ();
            for (int i = 0; i < msg.answers.length; i++) {
                var rr = msg.answers[i];
                if (rr.rtype == DnsRecord.TYPE_SRV)
                    list.add (new SrvTarget (rr.target, rr.port, rr.priority, rr.weight));
            }
            if (list.length == 0)
                throw new IOError.HOST_NOT_FOUND (@"No SRV records for $rrname");
            return SrvTarget.list_sort (list);
        }
    }
}
