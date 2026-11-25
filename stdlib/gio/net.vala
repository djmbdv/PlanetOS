// Pure-Vala gio-2.0 networking: InetAddress, SocketAddress, Socket, SocketListener, SocketService, SocketClient.
using GLib;
using Planet;

namespace Gio {

    public enum SocketFamily {
        INVALID = 0,
        UNIX = 1,
        IPV4 = 2,
        IPV6 = 10
    }

    public enum SocketType {
        INVALID = 0,
        STREAM = 1,
        DATAGRAM = 2,
        SEQPACKET = 3
    }

    public enum SocketProtocol {
        UNKNOWN = -1,
        DEFAULT = 0,
        TCP = 6,
        UDP = 17,
        SCTP = 132
    }

    public class InetAddress : Object {
        private SocketFamily family;
        private uint8[] bytes;

        public InetAddress.from_bytes (uint8[] bytes, SocketFamily family) {
            this.family = family;
            int n = bytes.length;
            this.bytes = new uint8[n];
            for (int i = 0; i < n; i++)
                this.bytes[i] = bytes[i];
        }

        public InetAddress.loopback (SocketFamily family) {
            this.family = family;
            if (family == SocketFamily.IPV4) {
                this.bytes = new uint8[4];
                this.bytes[0] = 127;
                this.bytes[1] = 0;
                this.bytes[2] = 0;
                this.bytes[3] = 1;
            } else {
                this.bytes = new uint8[16];
                this.bytes[15] = 1;
            }
        }

        public InetAddress.any (SocketFamily family) {
            this.family = family;
            int n = (family == SocketFamily.IPV4) ? 4 : 16;
            this.bytes = new uint8[n];
        }

        public static InetAddress? new_from_string (string str) {
            var b = new uint8[4];
            int octet = 0;
            int val = 0;
            int digits = 0;
            for (int i = 0; i < str.length; i++) {
                uint8 c = str[i];
                if (c >= '0' && c <= '9') {
                    val = val * 10 + (int) (c - '0');
                    if (val > 255)
                        return null;
                    digits++;
                } else if (c == '.') {
                    if (digits == 0 || octet >= 3)
                        return null;
                    b[octet] = (uint8) val;
                    octet++;
                    val = 0;
                    digits = 0;
                } else {
                    return null;
                }
            }
            if (digits == 0 || octet != 3)
                return null;
            b[3] = (uint8) val;
            return new InetAddress.from_bytes (b, SocketFamily.IPV4);
        }

        public SocketFamily get_family () {
            return family;
        }

        public uint8[] to_bytes () {
            var copy = new uint8[bytes.length];
            for (int i = 0; i < bytes.length; i++)
                copy[i] = bytes[i];
            return copy;
        }

        public int get_native_size () {
            return bytes.length;
        }

        public string to_string () {
            if (family == SocketFamily.IPV4 && bytes.length == 4) {
                int a = (int) bytes[0] & 0xFF;
                int b = (int) bytes[1] & 0xFF;
                int c = (int) bytes[2] & 0xFF;
                int d = (int) bytes[3] & 0xFF;
                return @"$a.$b.$c.$d";
            }
            return "::";
        }

        public bool get_is_any () {
            for (int i = 0; i < bytes.length; i++) {
                if (bytes[i] != 0)
                    return false;
            }
            return true;
        }

        public bool get_is_loopback () {
            if (family == SocketFamily.IPV4 && bytes.length == 4)
                return bytes[0] == 127;
            return false;
        }

        public bool equal (InetAddress other) {
            if (family != other.family || bytes.length != other.bytes.length)
                return false;
            for (int i = 0; i < bytes.length; i++) {
                if (bytes[i] != other.bytes[i])
                    return false;
            }
            return true;
        }
    }

    public abstract class SocketAddress : Object {
        public abstract SocketFamily get_family ();
        public virtual uint16 get_port () { return 0; }
        public virtual InetAddress? get_inet_address () { return null; }
    }

    public class InetSocketAddress : SocketAddress {
        private InetAddress address;
        private uint16 port;

        public InetSocketAddress (InetAddress address, uint16 port) {
            this.address = address;
            this.port = port;
        }

        public InetSocketAddress.from_string (string address_str, uint16 port) throws IOError {
            var parsed = InetAddress.new_from_string (address_str);
            if (parsed == null)
                throw new IOError.INVALID_ARGUMENT (@"Invalid IPv4 address: $address_str");
            this.address = (!) parsed;
            this.port = port;
        }

        public override SocketFamily get_family () {
            return address.get_family ();
        }

        public InetAddress get_address () {
            return address;
        }

        public override InetAddress? get_inet_address () {
            return address;
        }

        public override uint16 get_port () {
            return port;
        }

        public string to_string () {
            int p = (int) port & 0xFFFF;
            return @"$(address.to_string ()):$p";
        }
    }

    public interface SocketConnectable : Object {
        public abstract SocketAddress? resolve_first () throws IOError;
    }

    public class NetworkAddress : Object, SocketConnectable {
        private string hostname;
        private uint16 port;

        public NetworkAddress (string hostname, uint16 port) {
            this.hostname = hostname;
            this.port = port;
        }

        public static NetworkAddress parse (string host_and_port, uint16 default_port) throws IOError {
            int colon = host_and_port.last_index_of (":");
            if (colon > 0) {
                string h = host_and_port.substring (0, colon);
                string ps = host_and_port.substring (colon + 1);
                int p = int.parse (ps);
                if (p <= 0 || p > 65535)
                    throw new IOError.INVALID_ARGUMENT (@"Invalid port in $host_and_port");
                return new NetworkAddress (h, (uint16) p);
            }
            return new NetworkAddress (host_and_port, default_port);
        }

        public string get_hostname () { return hostname; }
        public uint16 get_port () { return port; }

        public SocketAddress? resolve_first () throws IOError {
            var addrs = Resolver.get_default ().lookup_by_name (hostname, null);
            if (addrs.length == 0)
                throw new IOError.HOST_NOT_FOUND (@"Cannot resolve $hostname");
            return new InetSocketAddress (addrs[0], port);
        }
    }

    public class NetworkService : Object, SocketConnectable {
        private string service;
        private string protocol;
        private string domain;
        private string scheme;

        public NetworkService (string service, string protocol, string domain) {
            this.service = service;
            this.protocol = protocol;
            this.domain = domain;
            this.scheme = protocol;
        }

        public string get_service () { return service; }
        public string get_protocol () { return protocol; }
        public string get_domain () { return domain; }
        public string get_scheme () { return scheme; }
        public void set_scheme (string scheme) { this.scheme = scheme; }

        public SocketAddress? resolve_first () throws IOError {
            uint16 port = 0;
            if (service == "http") port = 80;
            else if (service == "https") port = 443;
            else if (service == "dns") port = 53;
            else if (service == "mercury") port = 5000;
            var addrs = Resolver.get_default ().lookup_by_name (domain, null);
            if (addrs.length == 0)
                throw new IOError.HOST_NOT_FOUND (@"Cannot resolve service $service.$protocol.$domain");
            return new InetSocketAddress (addrs[0], port);
        }
    }

    public interface DatagramBased : Object {
        public abstract int condition_check (int condition);
    }

    // Internal thread-safe byte-ring pipe used to connect loopback Socket pairs.
    private class SocketPipe : Object {
        private uint8[] buf = new uint8[4096];
        private int head = 0;
        private int tail = 0;
        private int[] _lock = new int[1];
        public bool write_closed = false;

        public void close_write () {
            __planc_host_spin_lock (_lock);
            write_closed = true;
            __planc_host_spin_unlock (_lock);
        }

        public bool is_eof () {
            __planc_host_spin_lock (_lock);
            bool eof = write_closed && (head == tail);
            __planc_host_spin_unlock (_lock);
            return eof;
        }

        public int available () {
            __planc_host_spin_lock (_lock);
            int n = (tail - head) & 4095;
            __planc_host_spin_unlock (_lock);
            return n;
        }

        public int write_bytes (uint8[] data) {
            __planc_host_spin_lock (_lock);
            int wrote = 0;
            for (int i = 0; i < data.length; i++) {
                int next = (tail + 1) & 4095;
                if (next == head)
                    break;
                buf[tail] = data[i];
                tail = next;
                wrote++;
            }
            __planc_host_spin_unlock (_lock);
            return wrote;
        }

        public int read_bytes (uint8[] out_buf) {
            __planc_host_spin_lock (_lock);
            int got = 0;
            for (int i = 0; i < out_buf.length; i++) {
                if (head == tail)
                    break;
                out_buf[i] = buf[head];
                head = (head + 1) & 4095;
                got++;
            }
            __planc_host_spin_unlock (_lock);
            return got;
        }
    }

    private class PipeInputStream : InputStream {
        private SocketPipe pipe;
        public PipeInputStream (SocketPipe pipe) { this.pipe = pipe; }
        public override int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            return pipe.read_bytes (buffer);
        }
    }

    private class PipeOutputStream : OutputStream {
        private SocketPipe pipe;
        public PipeOutputStream (SocketPipe pipe) { this.pipe = pipe; }
        public override int write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (closed)
                throw new IOError.CLOSED ("Stream is closed");
            return pipe.write_bytes (buffer);
        }
    }

    private class SocketSourceState : Object {
        public Socket socket;
        public int condition;
        public SourceFunc callback;
        public SocketSourceState (Socket socket, int condition, SourceFunc callback) {
            this.socket = socket;
            this.condition = condition;
            this.callback = callback;
        }
    }

    public class Socket : Object, FileDescriptorBased, DatagramBased {
        private static GenericArray<Socket>? loopback_listeners;
        private static GenericArray<Socket>? datagram_sockets;
        private static uint16 next_ephemeral_port = 49152;

        private SocketFamily family;
        private SocketType socket_type;
        private SocketProtocol protocol;
        private int handle = -1;
        private bool closed = false;
        private bool blocking = true;
        private bool listening = false;
        private int listen_backlog = 10;
        private SocketAddress? local_addr = null;
        private SocketAddress? remote_addr = null;
        private GenericArray<Socket>? accept_queue = null;
        private SocketPipe? rx_pipe = null;
        private SocketPipe? tx_pipe = null;
        private VirtioTcpSession? tcp_session = null;

        public Socket (SocketFamily family, SocketType type, SocketProtocol protocol) throws IOError {
            if (family == SocketFamily.INVALID || type == SocketType.INVALID)
                throw new IOError.INVALID_ARGUMENT ("Invalid socket family or type");
            this.family = family;
            this.socket_type = type;
            this.protocol = protocol;
        }

        private static GenericArray<Socket> get_dgram_sockets () {
            if (datagram_sockets == null)
                datagram_sockets = new GenericArray<Socket> ();
            return (!) datagram_sockets;
        }

        private static Socket? find_dgram_socket (int port) {
            var list = get_dgram_sockets ();
            for (int i = 0; i < list.length; i++) {
                var s = list[i];
                if (s.closed)
                    continue;
                var la = s.local_addr;
                if (la != null && (int) ((!) la).get_port () == port)
                    return s;
            }
            return null;
        }

        private static GenericArray<Socket> get_listeners () {
            if (loopback_listeners == null)
                loopback_listeners = new GenericArray<Socket> ();
            return (!) loopback_listeners;
        }

        private static Socket? find_listener (int port) {
            var list = get_listeners ();
            for (int i = 0; i < list.length; i++) {
                var s = list[i];
                if (s.closed || !s.listening)
                    continue;
                var la = s.local_addr;
                if (la != null && (int) ((!) la).get_port () == port)
                    return s;
            }
            return null;
        }

        public SocketFamily get_family () { return family; }
        public SocketType get_socket_type () { return socket_type; }
        public SocketProtocol get_protocol () { return protocol; }
        public int get_fd () { return handle; }
        public bool is_closed () { return closed; }
        public bool is_connected () { return remote_addr != null && !closed; }
        public bool get_blocking () { return blocking; }
        public void set_blocking (bool blocking) { this.blocking = blocking; }
        public int get_listen_backlog () { return listen_backlog; }
        public void set_listen_backlog (int backlog) { this.listen_backlog = backlog; }
        public SocketAddress? get_local_address () { return local_addr; }
        public SocketAddress? get_remote_address () { return remote_addr; }

        public void attach_handle (int h) {
            this.handle = h;
        }

        public bool bind (SocketAddress address, bool allow_reuse = true) throws IOError {
            if (closed)
                throw new IOError.CLOSED ("Socket is closed");
            var ia = address.get_inet_address ();
            if (ia != null) {
                uint16 p = address.get_port ();
                if (p == 0) {
                    p = next_ephemeral_port;
                    next_ephemeral_port++;
                    local_addr = new InetSocketAddress ((!) ia, p);
                } else {
                    local_addr = address;
                }
            } else {
                local_addr = address;
            }
            if (socket_type == SocketType.DATAGRAM) {
                if (rx_pipe == null)
                    rx_pipe = new SocketPipe ();
                get_dgram_sockets ().add (this);
            }
            return true;
        }

        public bool listen () throws IOError {
            if (closed)
                throw new IOError.CLOSED ("Socket is closed");
            if (local_addr == null)
                throw new IOError.INVALID_ARGUMENT ("Socket must be bound before listen()");
            listening = true;
            if (accept_queue == null)
                accept_queue = new GenericArray<Socket> ();
            get_listeners ().add (this);
            return true;
        }

        public bool has_pending_accept () {
            return accept_queue != null && ((!) accept_queue).length > 0;
        }

        public Socket accept (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Socket.accept cancelled");
            if (closed)
                throw new IOError.CLOSED ("Socket is closed");
            if (!listening || accept_queue == null)
                throw new IOError.INVALID_ARGUMENT ("Socket is not listening");
            var q = (!) accept_queue;
            if (q.length == 0)
                throw new IOError.WOULD_BLOCK ("No pending connection");
            var client = q[0];
            var rest = new GenericArray<Socket> ();
            for (int i = 1; i < q.length; i++)
                rest.add (q[i]);
            accept_queue = rest;
            return client;
        }

        public bool connect (SocketAddress address, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Socket.connect cancelled");
            if (closed)
                throw new IOError.CLOSED ("Socket is closed");
            remote_addr = address;
            if (address is InetSocketAddress) {
                var isa = (InetSocketAddress) address;
                var ia = isa.get_inet_address ();
                var ip_b = (ia != null) ? ((!) ia).to_bytes () : new uint8[0];
                if (ip_b.length == 4 && ip_b[0] != 127) {
                    tcp_session = VirtioNetStack.get_default ().open_tcp (ip_b, isa.get_port ());
                    return true;
                }
                var listener = find_listener ((int) isa.get_port ());
                if (listener != null && ((!) listener).accept_queue != null) {
                    var c_to_s = new SocketPipe ();
                    var s_to_c = new SocketPipe ();
                    this.tx_pipe = c_to_s;
                    this.rx_pipe = s_to_c;

                    var peer = new Socket (family, socket_type, protocol);
                    peer.local_addr = ((!) listener).local_addr;
                    peer.remote_addr = this.local_addr ?? address;
                    peer.rx_pipe = c_to_s;
                    peer.tx_pipe = s_to_c;
                    ((!) ((!) listener).accept_queue).add (peer);
                }
            }
            return true;
        }

        public int send (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Socket.send cancelled");
            if (closed)
                throw new IOError.CLOSED ("Socket is closed");
            if (tcp_session != null)
                return ((!) tcp_session).send (buffer);
            if (tx_pipe == null)
                throw new IOError.FAILED ("Socket has no connected peer");
            return ((!) tx_pipe).write_bytes (buffer);
        }

        public int receive (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Socket.receive cancelled");
            if (closed)
                throw new IOError.CLOSED ("Socket is closed");
            if (tcp_session != null)
                return ((!) tcp_session).receive (buffer);
            if (rx_pipe == null)
                throw new IOError.FAILED ("Socket has no connected peer");
            int got = ((!) rx_pipe).read_bytes (buffer);
            if (got == 0 && !blocking)
                throw new IOError.WOULD_BLOCK ("No data available");
            return got;
        }

        public int send_to (SocketAddress? address, uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Socket.send_to cancelled");
            if (closed)
                throw new IOError.CLOSED ("Socket is closed");
            SocketAddress? target = address ?? remote_addr;
            if (target == null)
                throw new IOError.INVALID_ARGUMENT ("Socket.send_to: no destination address");
            SocketAddress dst = (!) target;
            int dst_port = (int) dst.get_port ();
            if (dst_port > 0) {
                var peer = find_dgram_socket (dst_port);
                if (peer != null && ((!) peer).rx_pipe != null)
                    return ((!) ((!) peer).rx_pipe).write_bytes (buffer);
            }
            if (tx_pipe != null)
                return ((!) tx_pipe).write_bytes (buffer);
            throw new IOError.HOST_NOT_FOUND ("No datagram receiver on target port");
        }

        public int receive_from (out SocketAddress? address, uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            address = remote_addr ?? local_addr;
            return receive (buffer, cancellable);
        }

        public int condition_check (int condition) {
            if (closed)
                return 0;
            int ready = 0;
            if ((condition & 1) != 0) {
                if (has_pending_accept () || (rx_pipe != null && ((!) rx_pipe).available () > 0))
                    ready = ready | 1;
            }
            if ((condition & 2) != 0) {
                if (tx_pipe != null)
                    ready = ready | 2;
            }
            return ready;
        }

        public Source create_source (int condition, SourceFunc callback) {
            var state = new SocketSourceState (this, condition, callback);
            var src = new Source (0, Source.KIND_CUSTOM, 0, 0, null);
            src.check_func = () => {
                return state.socket.condition_check (state.condition) != 0;
            };
            src.func = () => {
                return state.callback ();
            };
            return src;
        }

        public InputStream get_input_stream () {
            if (tcp_session != null)
                return new VirtioSocketInputStream (this);
            if (rx_pipe != null)
                return new PipeInputStream ((!) rx_pipe);
            return new MemoryInputStream ();
        }

        public OutputStream get_output_stream () {
            if (tcp_session != null)
                return new VirtioSocketOutputStream (this);
            if (tx_pipe != null)
                return new PipeOutputStream ((!) tx_pipe);
            return new MemoryOutputStream ();
        }

        public bool shutdown (bool shutdown_read, bool shutdown_write) throws IOError {
            if (closed)
                throw new IOError.CLOSED ("Socket is closed");
            if (shutdown_write && tx_pipe != null)
                ((!) tx_pipe).close_write ();
            if (shutdown_read && rx_pipe != null)
                ((!) rx_pipe).close_write ();
            return true;
        }

        public bool is_rx_eof () {
            if (closed)
                return true;
            if (tcp_session != null)
                return ((!) tcp_session).peer_fin;
            return (rx_pipe != null) ? ((!) rx_pipe).is_eof () : true;
        }

        public bool close () throws IOError {
            if (closed)
                return true;
            closed = true;
            listening = false;
            if (tcp_session != null)
                ((!) tcp_session).close ();
            if (handle >= 3) {
                Sys.close (handle);
                handle = -1;
            }
            return true;
        }
    }

    private class VirtioSocketInputStream : InputStream {
        private Socket sock;
        public VirtioSocketInputStream (Socket s) { this.sock = s; }
        public override int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (closed) throw new IOError.CLOSED ("Stream closed");
            int n = sock.receive (buffer, cancellable);
            if (n == 0 && sock.is_rx_eof ())
                return -1;
            return n;
        }
    }

    private class VirtioSocketOutputStream : OutputStream {
        private Socket sock;
        public VirtioSocketOutputStream (Socket s) { this.sock = s; }
        public override int write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (closed) throw new IOError.CLOSED ("Stream closed");
            return sock.send (buffer, cancellable);
        }
    }

    public class SocketConnection : IOStream {
        private Socket socket;

        public SocketConnection (Socket socket, InputStream? ins = null, OutputStream? outs = null)
            : base (ins ?? socket.get_input_stream (), outs ?? socket.get_output_stream ()) {
            this.socket = socket;
        }

        public Socket get_socket () { return socket; }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            bool ok = base.close (cancellable);
            socket.close ();
            return ok;
        }
    }

    /**
     * TCP socket connection (GLib.TcpConnection) with graceful-disconnect (FIN/half-close).
     */
    public class TcpConnection : SocketConnection {
        public bool graceful_disconnect { get; set; default = false; }

        public TcpConnection (Socket socket, InputStream? ins = null, OutputStream? outs = null)
            : base (socket, ins, outs) {
        }

        public bool get_graceful_disconnect () {
            return graceful_disconnect;
        }

        public void set_graceful_disconnect (bool graceful_disconnect) {
            this.graceful_disconnect = graceful_disconnect;
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            var sock = get_socket ();
            if (graceful_disconnect && !sock.is_closed ()) {
                sock.shutdown (false, true);
                var drain = new uint8[256];
                for (int w = 0; w < 100; w++) {
                    if (cancellable != null && cancellable.is_cancelled ())
                        throw new IOError.CANCELLED ("TcpConnection.close cancelled");
                    if (sock.is_rx_eof ())
                        break;
                    int avail = sock.condition_check (1);
                    if ((avail & 1) != 0)
                        sock.receive (drain, cancellable);
                    else
                        Sys.sleep_ms (5);
                }
            }
            return base.close (cancellable);
        }
    }

    public class SocketClient : Object {
        public SocketFamily family { get; set; default = SocketFamily.IPV4; }
        public SocketType socket_type { get; set; default = SocketType.STREAM; }
        public SocketProtocol protocol { get; set; default = SocketProtocol.DEFAULT; }
        public bool tls { get; set; default = false; }
        public TlsCertificateFlags tls_validation_flags { get; set; default = TlsCertificateFlags.VALIDATE_ALL; }

        public SocketConnection connect (SocketAddress address, Cancellable? cancellable = null) throws IOError {
            var sock = new Socket (address.get_family (), socket_type, protocol);
            sock.connect (address, cancellable);
            if (protocol == SocketProtocol.TCP
                || (socket_type == SocketType.STREAM && protocol == SocketProtocol.DEFAULT
                    && (address.get_family () == SocketFamily.IPV4 || address.get_family () == SocketFamily.IPV6))) {
                return new TcpConnection (sock);
            }
            return new SocketConnection (sock);
        }

        public SocketConnection connect_to_host (string host_and_port, uint16 default_port, Cancellable? cancellable = null) throws IOError {
            var na = NetworkAddress.parse (host_and_port, default_port);
            var addrs = Resolver.get_default ().lookup_by_name (na.get_hostname (), cancellable);
            if (addrs.length == 0)
                throw new IOError.HOST_NOT_FOUND (@"Cannot resolve $(na.get_hostname ())");
            var isa = new InetSocketAddress (addrs[0], na.get_port ());
            return connect (isa, cancellable);
        }

        public TlsClientConnection connect_to_host_tls (string host_and_port, uint16 default_port, Cancellable? cancellable = null) throws IOError {
            var na = NetworkAddress.parse (host_and_port, default_port);
            var addrs = Resolver.get_default ().lookup_by_name (na.get_hostname (), cancellable);
            if (addrs.length == 0)
                throw new IOError.HOST_NOT_FOUND (@"Cannot resolve $(na.get_hostname ())");
            var isa = new InetSocketAddress (addrs[0], na.get_port ());
            var conn = connect (isa, cancellable);
            try {
                var tconn = TlsClientConnection.create (conn, na);
                tconn.set_validation_flags (tls_validation_flags);
                tconn.handshake (cancellable);
                return tconn;
            } catch (Error e) {
                throw new IOError.FAILED (@"TLS handshake failed: $(e.message)");
            }
        }
    }

    public class SocketListener : Object {
        protected GenericArray<Socket> sockets = new GenericArray<Socket> ();
        protected GenericArray<Object?> source_objects = new GenericArray<Object?> ();
        private int backlog = 10;

        public void set_backlog (int listen_backlog) {
            this.backlog = listen_backlog;
        }

        public bool add_socket (Socket socket, Object? source_object = null) throws IOError {
            socket.set_listen_backlog (backlog);
            socket.listen ();
            sockets.add (socket);
            source_objects.add (source_object);
            return true;
        }

        public bool add_address (SocketAddress address, SocketType type, SocketProtocol protocol,
                                 Object? source_object, out SocketAddress? effective_address) throws IOError {
            var sock = new Socket (address.get_family (), type, protocol);
            sock.bind (address, true);
            effective_address = sock.get_local_address ();
            return add_socket (sock, source_object);
        }

        public uint16 add_any_inet_port (Object? source_object = null) throws IOError {
            var addr = new InetSocketAddress (new InetAddress.loopback (SocketFamily.IPV4), 0);
            SocketAddress? eff = null;
            add_address (addr, SocketType.STREAM, SocketProtocol.TCP, source_object, out eff);
            if (eff != null && eff is InetSocketAddress)
                return ((InetSocketAddress) eff).get_port ();
            return 0;
        }

        public bool add_inet_port (uint16 port, Object? source_object = null) throws IOError {
            var addr = new InetSocketAddress (new InetAddress.loopback (SocketFamily.IPV4), port);
            SocketAddress? eff = null;
            return add_address (addr, SocketType.STREAM, SocketProtocol.TCP, source_object, out eff);
        }

        public Socket accept_socket (out Object? source_object, Cancellable? cancellable = null) throws IOError {
            source_object = null;
            for (int i = 0; i < sockets.length; i++) {
                if (sockets[i].has_pending_accept ()) {
                    source_object = source_objects[i];
                    return sockets[i].accept (cancellable);
                }
            }
            throw new IOError.WOULD_BLOCK ("No pending connection");
        }

        public SocketConnection accept (out Object? source_object, Cancellable? cancellable = null) throws IOError {
            var sock = accept_socket (out source_object, cancellable);
            if (sock.get_protocol () == SocketProtocol.TCP
                || (sock.get_socket_type () == SocketType.STREAM && sock.get_protocol () == SocketProtocol.DEFAULT
                    && (sock.get_family () == SocketFamily.IPV4 || sock.get_family () == SocketFamily.IPV6))) {
                return new TcpConnection (sock);
            }
            return new SocketConnection (sock);
        }

        public void close () {
            for (int i = 0; i < sockets.length; i++) {
                try {
                    sockets[i].close ();
                } catch (IOError e) {
                }
            }
            sockets = new GenericArray<Socket> ();
            source_objects = new GenericArray<Object?> ();
        }
    }

    private class ServiceWatchState : Object {
        public SocketService service;
        public Socket sock;
        public Object? src_obj;
        public ServiceWatchState (SocketService service, Socket sock, Object? src_obj) {
            this.service = service;
            this.sock = sock;
            this.src_obj = src_obj;
        }
    }

    public class SocketService : SocketListener {
        private bool active = false;
        private GenericArray<Source> watch_sources = new GenericArray<Source> ();

        public signal bool incoming (SocketConnection connection, Object? source_object);

        public bool is_active () {
            return active;
        }

        public virtual void start () {
            if (active)
                return;
            active = true;
            for (int i = 0; i < sockets.length; i++) {
                var st = new ServiceWatchState (this, sockets[i], source_objects[i]);
                var src = st.sock.create_source (1, () => {
                    if (!st.service.active)
                        return false;
                    while (st.sock.has_pending_accept ()) {
                        try {
                            var peer = st.sock.accept (null);
                            var conn = new SocketConnection (peer);
                            st.service.incoming (conn, st.src_obj);
                        } catch (IOError e) {
                            break;
                        }
                    }
                    return st.service.active;
                });
                src.attach (MainContext.default_ ());
                watch_sources.add (src);
            }
        }

        public virtual void stop () {
            active = false;
            for (int i = 0; i < watch_sources.length; i++) {
                watch_sources[i].removed = true;
                watch_sources[i].destroyed = true;
            }
            watch_sources = new GenericArray<Source> ();
        }
    }

    private class ThreadedConnJob : Object {
        public SocketConnection? connection;
        public Object? source_object;
        public ThreadedConnJob (SocketConnection? connection, Object? source_object) {
            this.connection = connection;
            this.source_object = source_object;
        }
    }

    /**
     * SocketService that dispatches each incoming SocketConnection onto a
     * fixed-size pool of real kernel worker threads (GLib.Thread + AsyncQueue).
     */
    public class ThreadedSocketService : SocketService {
        private int max_threads;
        private AsyncQueue<ThreadedConnJob> queue = new AsyncQueue<ThreadedConnJob> ();
        private GenericArray<Thread> workers = new GenericArray<Thread> ();
        private bool workers_started = false;
        private bool stopping = false;

        public signal bool run (SocketConnection connection, Object? source_object);

        public ThreadedSocketService (int max_threads = 4) {
            this.max_threads = (max_threads <= 0) ? 1 : max_threads;
            this.incoming.connect ((sender, conn, obj) => {
                queue.push (new ThreadedConnJob (conn, obj));
                return true;
            });
        }

        private void worker_loop () {
            while (true) {
                var job = queue.pop ();
                if (stopping || job.connection == null)
                    return;
                run ((!) job.connection, job.source_object);
            }
        }

        public override void start () {
            if (!workers_started) {
                workers_started = true;
                stopping = false;
                for (int i = 0; i < max_threads; i++) {
                    ThreadFunc body = () => {
                        worker_loop ();
                        return null;
                    };
                    workers.add (new Thread ("gio-sock-worker", body));
                }
            }
            base.start ();
        }

        public override void stop () {
            base.stop ();
            if (workers_started) {
                stopping = true;
                for (int i = 0; i < workers.length; i++)
                    queue.push (new ThreadedConnJob (null, null));
                for (int i = 0; i < workers.length; i++)
                    workers[i].join ();
                workers = new GenericArray<Thread> ();
                workers_started = false;
            }
        }
    }
}
