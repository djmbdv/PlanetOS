// Pure-Vala userspace L2/L3/L4 (Ethernet + ARP + IPv4 + UDP + TCP) stack over VirtIO-NET + PlanetRing.
// Bridges Gio.Socket and GLib.Resolver to real QEMU SLIRP / network hardware for non-loopback IPv4.
using GLib;
using Planet;

namespace Gio {

    internal class VirtioTcpSession : Object {
        private VirtioNetStack stack;
        public uint8[] dst_ip;
        public uint16 dst_port;
        public uint16 src_port;
        public uint32 snd_nxt;
        public uint32 rcv_nxt;
        public bool connected = false;
        public bool peer_fin = false;
        public bool closed = false;
        private ByteArray rx_q = new ByteArray.sized (4096);
        private int rx_q_pos = 0;

        public VirtioTcpSession (VirtioNetStack stack, uint8[] dst_ip, uint16 dst_port, uint16 src_port) {
            this.stack = stack;
            this.dst_ip = new uint8[4];
            for (int i = 0; i < 4; i++) this.dst_ip[i] = dst_ip[i];
            this.dst_port = dst_port;
            this.src_port = src_port;
            var rb = new uint8[4];
            TlsCrypto.random_bytes (rb);
            this.snd_nxt = VirtioNetStack.read_be32 (rb, 0);
            this.rcv_nxt = 0;
        }

        public bool connect_handshake () throws IOError {
            stack.ensure_gateway_mac ();
            uint8[] syn_opts = { 0x02, 0x04, 0x05, 0xB4 }; // MSS=1460
            stack.send_tcp_segment (dst_ip, src_port, dst_port, snd_nxt, 0, 0x02, syn_opts, new uint8[0]);
            snd_nxt++;

            for (int tries = 0; tries < 300; tries++) {
                uint8[]? pkt = stack.poll_ipv4 (6, 10);
                if (pkt == null)
                    continue;
                var p = (!) pkt;
                if (!matches_tuple (p))
                    continue;
                int ihl = (p[14] & 0x0F) * 4;
                int toff = 14 + ihl;
                uint8 fl = p[toff + 13];
                if ((fl & 0x12) == 0x12) { // SYN|ACK
                    uint32 srv_seq = VirtioNetStack.read_be32 (p, toff + 4);
                    uint32 ack = VirtioNetStack.read_be32 (p, toff + 8);
                    if (ack == snd_nxt) {
                        rcv_nxt = srv_seq + 1;
                        stack.send_tcp_segment (dst_ip, src_port, dst_port, snd_nxt, rcv_nxt, 0x10, new uint8[0], new uint8[0]);
                        connected = true;
                        return true;
                    }
                } else if ((fl & 0x04) != 0) { // RST
                    throw new IOError.CONNECTION_REFUSED ("TCP connection refused (RST)");
                }
            }
            throw new IOError.TIMED_OUT ("TCP connect timeout");
        }

        private bool matches_tuple (uint8[] p) {
            if (p.length < 54)
                return false;
            int ihl = (p[14] & 0x0F) * 4;
            if (ihl < 20 || p.length < 14 + ihl + 20)
                return false;
            for (int i = 0; i < 4; i++) {
                if (p[14 + 12 + i] != dst_ip[i] || p[14 + 16 + i] != stack.local_ip[i])
                    return false;
            }
            int toff = 14 + ihl;
            uint16 sp = VirtioNetStack.read_be16 (p, toff + 0);
            uint16 dp = VirtioNetStack.read_be16 (p, toff + 2);
            return sp == dst_port && dp == src_port;
        }

        private void process_incoming (uint8[] p) throws IOError {
            if (!matches_tuple (p))
                return;
            int ihl = (p[14] & 0x0F) * 4;
            int ip_len = (int) VirtioNetStack.read_be16 (p, 16);
            int toff = 14 + ihl;
            int doff = ((p[toff + 12] >> 4) & 0x0F) * 4;
            int hdr_total = ihl + doff;
            if (doff < 20 || ip_len < hdr_total || 14 + hdr_total > p.length)
                return;
            int pay_len = ip_len - hdr_total;
            int pay_off = 14 + hdr_total;
            if (pay_off + pay_len > p.length)
                pay_len = p.length - pay_off;

            uint32 seq = VirtioNetStack.read_be32 (p, toff + 4);
            uint8 fl = p[toff + 13];
            if ((fl & 0x04) != 0) { // RST
                peer_fin = true;
                return;
            }
            bool need_ack = false;
            if (pay_len > 0 && seq == rcv_nxt) {
                for (int i = 0; i < pay_len; i++)
                    rx_q.append_byte (p[pay_off + i]);
                rcv_nxt += (uint32) pay_len;
                need_ack = true;
            } else if (pay_len > 0 && seq < rcv_nxt) {
                need_ack = true;
            }
            if ((fl & 0x01) != 0) { // FIN
                if (seq + (uint32) pay_len == rcv_nxt)
                    rcv_nxt++;
                peer_fin = true;
                need_ack = true;
            }
            if (need_ack)
                stack.send_tcp_segment (dst_ip, src_port, dst_port, snd_nxt, rcv_nxt, 0x10, new uint8[0], new uint8[0]);
        }

        public int send (uint8[] buf) throws IOError {
            if (closed || !connected)
                throw new IOError.CLOSED ("TCP session closed");
            int off = 0;
            while (off < buf.length) {
                int chunk = buf.length - off;
                if (chunk > 1400)
                    chunk = 1400;
                var seg = new uint8[chunk];
                Memory.copy (Sys.byte_arr_addr (seg), Sys.byte_arr_addr (buf) + off, (size_t) chunk);
                stack.send_tcp_segment (dst_ip, src_port, dst_port, snd_nxt, rcv_nxt, 0x18, new uint8[0], seg);
                uint32 exp_ack = snd_nxt + (uint32) chunk;
                snd_nxt = exp_ack;

                // Wait briefly for ACK (and buffer any piggybacked data)
                for (int w = 0; w < 50; w++) {
                    uint8[]? pkt = stack.poll_ipv4 (6, 10);
                    if (pkt == null)
                        continue;
                    var p = (!) pkt;
                    if (!matches_tuple (p))
                        continue;
                    process_incoming (p);
                    int ihl = (p[14] & 0x0F) * 4;
                    uint32 ack = VirtioNetStack.read_be32 (p, 14 + ihl + 8);
                    if ((p[14 + ihl + 13] & 0x10) != 0 && ack >= exp_ack)
                        break;
                }
                off += chunk;
            }
            return buf.length;
        }

        public int receive (uint8[] buf) throws IOError {
            if (closed)
                throw new IOError.CLOSED ("TCP session closed");
            if (rx_q_pos >= rx_q.len) {
                if (peer_fin)
                    return 0;
                for (int w = 0; w < 100 && rx_q_pos >= rx_q.len && !peer_fin; w++) {
                    uint8[]? pkt = stack.poll_ipv4 (6, 20);
                    if (pkt != null)
                        process_incoming ((!) pkt);
                }
            }
            int avail = rx_q.len - rx_q_pos;
            if (avail <= 0)
                return 0;
            int take = rx_q.copy_to (rx_q_pos, buf, 0, avail);
            rx_q_pos += take;
            if (rx_q_pos >= 4096) {
                rx_q.remove_range (0, rx_q_pos);
                rx_q_pos = 0;
            }
            return take;
        }

        public void close () {
            if (!closed && connected) {
                try {
                    stack.send_tcp_segment (dst_ip, src_port, dst_port, snd_nxt, rcv_nxt, 0x11, new uint8[0], new uint8[0]);
                } catch (IOError e) {
                }
            }
            closed = true;
            connected = false;
        }
    }

    internal class VirtioNetStack : Object {
        private static int once_state = 0;
        private static VirtioNetStack? default_stack;

        private int[] io_lock = new int[1];
        private PlanetRing? ring = null;
        private PlanetIoArena? arena = null;
        private int tx_lease = 0;
        private int rx_lease = 0;
        private int tx_off = 0;
        private int rx_off = 0;
        private int tx_buf = 0;
        private int rx_buf = 0;
        private uint8[] mac = new uint8[6];
        public uint8[] local_ip = { 10, 0, 2, 15 };
        private uint8[] gw_ip = { 10, 0, 2, 2 };
        private uint8[] gw_mac = new uint8[6];
        private bool gw_mac_ok = false;
        private int ip_id = 1;
        private uint16 next_port = 51000;

        public static VirtioNetStack get_default () {
            while (AtomicInt.get (ref once_state) != 2) {
                if (AtomicInt.compare_and_exchange (ref once_state, 0, 1)) {
                    default_stack = new VirtioNetStack ();
                    AtomicInt.set (ref once_state, 2);
                    break;
                }
                Sys.yield_cpu ();
            }
            return (!) default_stack;
        }

        public static uint16 read_be16 (uint8[] b, int off) {
            return (uint16) (((uint16) b[off] << 8) | (uint16) b[off + 1]);
        }

        public static uint32 read_be32 (uint8[] b, int off) {
            return ((uint32) b[off] << 24) | ((uint32) b[off + 1] << 16)
                 | ((uint32) b[off + 2] << 8) | (uint32) b[off + 3];
        }

        private void ensure_init () throws IOError {
            if (ring != null)
                return;
            if (Sys.net_mac (mac) < 0)
                throw new IOError.FAILED ("No virtio-net device");
            var r = PlanetRing.create (2, 8, PlanetRing.DEV_NET);
            var a = PlanetIoArena.create (2, 2048);
            tx_lease = a.acquire_lease ();
            rx_lease = a.acquire_lease ();
            tx_off = r.data_offset;
            rx_off = tx_off + 2048;
            tx_buf = r.grant.base_addr + tx_off;
            rx_buf = r.grant.base_addr + rx_off;
            ring = r;
            arena = a;
        }

        private static int inet_checksum (PlanetGrant g, int off, int len) throws IOError {
            int sum = 0;
            int i = 0;
            while (i + 1 < len) {
                sum += g.get_be16 (off + i);
                i += 2;
            }
            if (i < len)
                sum += (g.get_u8 (off + i) << 8);
            while ((sum >> 16) != 0)
                sum = (sum & 0xFFFF) + (sum >> 16);
            return (~sum) & 0xFFFF;
        }

        private static int l4_checksum (PlanetGrant g, uint8[] src_ip, uint8[] dst_ip, int proto, int l4_off, int l4_len) throws IOError {
            int sum = 0;
            sum += ((int) src_ip[0] << 8) | (int) src_ip[1];
            sum += ((int) src_ip[2] << 8) | (int) src_ip[3];
            sum += ((int) dst_ip[0] << 8) | (int) dst_ip[1];
            sum += ((int) dst_ip[2] << 8) | (int) dst_ip[3];
            sum += proto;
            sum += l4_len;
            int i = 0;
            while (i + 1 < l4_len) {
                sum += g.get_be16 (l4_off + i);
                i += 2;
            }
            if (i < l4_len)
                sum += (g.get_u8 (l4_off + i) << 8);
            while ((sum >> 16) != 0)
                sum = (sum & 0xFFFF) + (sum >> 16);
            int csum = (~sum) & 0xFFFF;
            return (csum == 0 && proto == 17) ? 0xFFFF : csum;
        }

        private void write_eth_ipv4 (PlanetGrant g, int off, uint8[] dst_ip, int proto, int l4_len) throws IOError {
            for (int i = 0; i < 6; i++) g.put_u8 (off + i, gw_mac[i]);
            for (int i = 0; i < 6; i++) g.put_u8 (off + 6 + i, mac[i]);
            g.put_be16 (off + 12, 0x0800);

            int ip_off = off + 14;
            g.put_u8 (ip_off + 0, 0x45);
            g.put_u8 (ip_off + 1, 0);
            g.put_be16 (ip_off + 2, 20 + l4_len);
            g.put_be16 (ip_off + 4, ip_id++);
            g.put_be16 (ip_off + 6, 0x4000);
            g.put_u8 (ip_off + 8, 64);
            g.put_u8 (ip_off + 9, proto);
            g.put_be16 (ip_off + 10, 0);
            for (int i = 0; i < 4; i++) g.put_u8 (ip_off + 12 + i, local_ip[i]);
            for (int i = 0; i < 4; i++) g.put_u8 (ip_off + 16 + i, dst_ip[i]);
            g.put_be16 (ip_off + 10, inet_checksum (g, ip_off, 20));
        }

        public void ensure_gateway_mac () throws IOError {
            ensure_init ();
            if (gw_mac_ok)
                return;
            var r = (!) ring;
            var g = r.grant;
            for (int i = 0; i < 6; i++) g.put_u8 (tx_off + i, 0xFF);
            for (int i = 0; i < 6; i++) g.put_u8 (tx_off + 6 + i, mac[i]);
            g.put_be16 (tx_off + 12, 0x0806);
            g.put_be16 (tx_off + 14, 1);
            g.put_be16 (tx_off + 16, 0x0800);
            g.put_u8 (tx_off + 18, 6);
            g.put_u8 (tx_off + 19, 4);
            g.put_be16 (tx_off + 20, 1);
            for (int i = 0; i < 6; i++) g.put_u8 (tx_off + 22 + i, mac[i]);
            for (int i = 0; i < 4; i++) g.put_u8 (tx_off + 28 + i, local_ip[i]);
            for (int i = 0; i < 6; i++) g.put_u8 (tx_off + 32 + i, 0);
            for (int i = 0; i < 4; i++) g.put_u8 (tx_off + 38 + i, gw_ip[i]);
            r.submit_net_tx (tx_buf, 42, tx_lease);
            r.kick ();

            int[] pfd = { r.get_fd () };
            for (int tries = 0; tries < 50; tries++) {
                Sys.poll_n (pfd, 1, 20);
                int rslot = r.submit_net_rx (rx_buf, 1514, rx_lease);
                r.kick ();
                int rlen = r.slot_result (rslot);
                if (rlen >= 42 && g.get_be16 (rx_off + 12) == 0x0806 && g.get_be16 (rx_off + 20) == 2) {
                    if (g.get_u8 (rx_off + 28) == gw_ip[0] && g.get_u8 (rx_off + 29) == gw_ip[1]
                        && g.get_u8 (rx_off + 30) == gw_ip[2] && g.get_u8 (rx_off + 31) == gw_ip[3]) {
                        for (int i = 0; i < 6; i++)
                            gw_mac[i] = (uint8) g.get_u8 (rx_off + 22 + i);
                        gw_mac_ok = true;
                        return;
                    }
                }
            }
            throw new IOError.FAILED ("ARP timeout for gateway 10.0.2.2");
        }

        public uint8[]? poll_ipv4 (int want_proto, int timeout_ms) throws IOError {
            var r = (!) ring;
            var g = r.grant;
            for (int pass = 0; pass < 2; pass++) {
                // Drain any already-queued RX frames before sleeping
                for (int d = 0; d < 8; d++) {
                    int rslot = r.submit_net_rx (rx_buf, 1514, rx_lease);
                    r.kick ();
                    int rlen = r.slot_result (rslot);
                    if (rlen <= 0)
                        break;
                    if (rlen >= 34 && g.get_be16 (rx_off + 12) == 0x0800 && g.get_u8 (rx_off + 23) == want_proto) {
                        var pkt = new uint8[rlen];
                        g.read_bytes (rx_off, pkt, rlen);
                        return pkt;
                    }
                }
                if (pass == 0 && timeout_ms > 0)
                    Sys.sleep_ms (timeout_ms);
            }
            return null;
        }

        public void send_tcp_segment (uint8[] dst_ip, uint16 src_port, uint16 dst_port,
                                      uint32 seq, uint32 ack, uint8 flags,
                                      uint8[] opts, uint8[] payload) throws IOError {
            var r = (!) ring;
            var g = r.grant;
            int hdr_len = 20 + opts.length;
            int tcp_len = hdr_len + payload.length;
            write_eth_ipv4 (g, tx_off, dst_ip, 6, tcp_len);
            int toff = tx_off + 34;
            g.put_be16 (toff + 0, src_port);
            g.put_be16 (toff + 2, dst_port);
            g.put_be16 (toff + 4, (int) ((seq >> 16) & 0xFFFF));
            g.put_be16 (toff + 6, (int) (seq & 0xFFFF));
            g.put_be16 (toff + 8, (int) ((ack >> 16) & 0xFFFF));
            g.put_be16 (toff + 10, (int) (ack & 0xFFFF));
            g.put_u8 (toff + 12, ((hdr_len / 4) << 4) & 0xF0);
            g.put_u8 (toff + 13, flags);
            g.put_be16 (toff + 14, 32768); // window
            g.put_be16 (toff + 16, 0);
            g.put_be16 (toff + 18, 0);
            for (int i = 0; i < opts.length; i++)
                g.put_u8 (toff + 20 + i, opts[i]);
            for (int i = 0; i < payload.length; i++)
                g.put_u8 (toff + hdr_len + i, payload[i]);
            g.put_be16 (toff + 16, l4_checksum (g, local_ip, dst_ip, 6, toff, tcp_len));
            r.submit_net_tx (tx_buf, 14 + 20 + tcp_len, tx_lease);
            r.kick ();
        }

        public uint8[] udp_query (uint8[] dst_ip, uint16 dst_port, uint8[] payload) throws IOError {
            __planc_host_spin_lock (io_lock);
            try {
                ensure_gateway_mac ();
                var r = (!) ring;
                var g = r.grant;
                uint16 src_port = (uint16) (49152 + ((int) (next_port++) & 0x3FFF));
                int udp_len = 8 + payload.length;
                write_eth_ipv4 (g, tx_off, dst_ip, 17, udp_len);
                int uoff = tx_off + 34;
                g.put_be16 (uoff + 0, src_port);
                g.put_be16 (uoff + 2, dst_port);
                g.put_be16 (uoff + 4, udp_len);
                g.put_be16 (uoff + 6, 0);
                for (int i = 0; i < payload.length; i++)
                    g.put_u8 (uoff + 8 + i, payload[i]);
                g.put_be16 (uoff + 6, l4_checksum (g, local_ip, dst_ip, 17, uoff, udp_len));
                r.submit_net_tx (tx_buf, 14 + 20 + udp_len, tx_lease);
                r.kick ();

                for (int tries = 0; tries < 50; tries++) {
                    uint8[]? pkt = poll_ipv4 (17, 20);
                    if (pkt == null)
                        continue;
                    var p = (!) pkt;
                    int ihl = (p[14] & 0x0F) * 4;
                    int ruoff = 14 + ihl;
                    if (ihl >= 20 && p.length >= ruoff + 8
                        && p[26] == dst_ip[0] && p[27] == dst_ip[1] && p[28] == dst_ip[2] && p[29] == dst_ip[3]) {
                        uint16 sp = read_be16 (p, ruoff + 0);
                        uint16 dp = read_be16 (p, ruoff + 2);
                        int rlen = (int) read_be16 (p, ruoff + 4) - 8;
                        if (sp == dst_port && dp == src_port && rlen > 0 && ruoff + 8 + rlen <= p.length) {
                            var rep = new uint8[rlen];
                            Memory.copy (Sys.byte_arr_addr (rep), Sys.byte_arr_addr (p) + ruoff + 8, (size_t) rlen);
                            __planc_host_spin_unlock (io_lock);
                            return rep;
                        }
                    }
                }
                __planc_host_spin_unlock (io_lock);
                throw new IOError.TIMED_OUT ("UDP DNS query timeout");
            } catch (IOError e) {
                __planc_host_spin_unlock (io_lock);
                throw new IOError.FAILED (e.message);
            }
        }

        public VirtioTcpSession open_tcp (uint8[] dst_ip, uint16 dst_port) throws IOError {
            uint16 sp = next_port++;
            var sess = new VirtioTcpSession (this, dst_ip, dst_port, sp);
            sess.connect_handshake ();
            return sess;
        }
    }
}
