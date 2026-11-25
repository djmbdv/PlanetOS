// mercury: pure-Vala network service over VirtIO-NET + PlanetRing (Contract B).
using GLib;
using Gio;
using Planet;

static int inet_checksum (PlanetGrant g, int off, int len) throws IOError {
    int sum = 0;
    int i = 0;
    while (i + 1 < len) {
        sum = sum + g.get_be16 (off + i);
        i = i + 2;
    }
    if (i < len)
        sum = sum + (g.get_u8 (off + i) << 8);
    while ((sum >> 16) != 0)
        sum = (sum & 0xFFFF) + (sum >> 16);
    return (~sum) & 0xFFFF;
}

static int udp_checksum (PlanetGrant g, uint8[] src_ip, uint8[] dst_ip, int udp_off, int udp_len) throws IOError {
    int sum = 0;
    // IPv4 pseudo-header: src_ip (4), dst_ip (4), zero + proto (17), udp_len
    sum += ((int) src_ip[0] << 8) | (int) src_ip[1];
    sum += ((int) src_ip[2] << 8) | (int) src_ip[3];
    sum += ((int) dst_ip[0] << 8) | (int) dst_ip[1];
    sum += ((int) dst_ip[2] << 8) | (int) dst_ip[3];
    sum += 17;
    sum += udp_len;
    int i = 0;
    while (i + 1 < udp_len) {
        sum += g.get_be16 (udp_off + i);
        i += 2;
    }
    if (i < udp_len)
        sum += g.get_u8 (udp_off + i) << 8;
    while ((sum >> 16) != 0)
        sum = (sum & 0xFFFF) + (sum >> 16);
    int csum = (~sum) & 0xFFFF;
    return (csum == 0) ? 0xFFFF : csum;
}

static void write_eth_ipv4 (PlanetGrant g, int off, uint8[] dst_mac, uint8[] src_mac,
                            uint8[] src_ip, uint8[] dst_ip, int proto, int l4_len, int ip_id, int tos = 0) throws IOError {
    for (int i = 0; i < 6; i++) g.put_u8 (off + i, dst_mac[i]);
    for (int i = 0; i < 6; i++) g.put_u8 (off + 6 + i, src_mac[i]);
    g.put_be16 (off + 12, 0x0800);

    int ip_off = off + 14;
    g.put_u8 (ip_off + 0, 0x45);
    g.put_u8 (ip_off + 1, tos & 0xFF);
    g.put_be16 (ip_off + 2, 20 + l4_len);
    g.put_be16 (ip_off + 4, ip_id);
    g.put_be16 (ip_off + 6, 0x4000);
    g.put_u8 (ip_off + 8, 64);
    g.put_u8 (ip_off + 9, proto);
    g.put_be16 (ip_off + 10, 0);
    for (int i = 0; i < 4; i++) g.put_u8 (ip_off + 12 + i, src_ip[i]);
    for (int i = 0; i < 4; i++) g.put_u8 (ip_off + 16 + i, dst_ip[i]);
    g.put_be16 (ip_off + 10, inet_checksum (g, ip_off, 20));
}

static void udp_send (PlanetRing ring, PlanetGrant g, int tx_off, int tx_buf, int tx_lease,
                      uint8[] dst_mac, uint8[] src_mac, uint8[] src_ip, uint8[] dst_ip,
                      int src_port, int dst_port, uint8[] payload, int ip_id) throws IOError {
    int udp_len = 8 + payload.length;
    write_eth_ipv4 (g, tx_off, dst_mac, src_mac, src_ip, dst_ip, 17, udp_len, ip_id);
    int uoff = tx_off + 34;
    g.put_be16 (uoff + 0, src_port);
    g.put_be16 (uoff + 2, dst_port);
    g.put_be16 (uoff + 4, udp_len);
    g.put_be16 (uoff + 6, 0);
    for (int i = 0; i < payload.length; i++)
        g.put_u8 (uoff + 8 + i, payload[i]);
    g.put_be16 (uoff + 6, udp_checksum (g, src_ip, dst_ip, uoff, udp_len));
    ring.submit_net_tx (tx_buf, 14 + 20 + udp_len, tx_lease);
    ring.kick ();
}

static uint8[] dhcp_encode_discover (uint8[] mac, int xid) {
    var pkt = new uint8[300];
    pkt[0] = 1; // BOOTREQUEST
    pkt[1] = 1; // Ethernet
    pkt[2] = 6; // HLEN
    pkt[3] = 0; // HOPS
    pkt[4] = (uint8) ((xid >> 24) & 0xFF);
    pkt[5] = (uint8) ((xid >> 16) & 0xFF);
    pkt[6] = (uint8) ((xid >> 8) & 0xFF);
    pkt[7] = (uint8) (xid & 0xFF);
    pkt[10] = 0x80; // Broadcast flag
    for (int i = 0; i < 6; i++)
        pkt[28 + i] = mac[i];
    // Magic cookie: 99.130.83.99
    pkt[236] = 99; pkt[237] = 130; pkt[238] = 83; pkt[239] = 99;
    // Option 53: DHCP Message Type = 1 (DISCOVER)
    pkt[240] = 53; pkt[241] = 1; pkt[242] = 1;
    // Option 55: Parameter Request List (1=subnet, 3=router, 6=dns)
    pkt[243] = 55; pkt[244] = 3; pkt[245] = 1; pkt[246] = 3; pkt[247] = 6;
    pkt[248] = 255; // End
    return pkt;
}

static bool udp_recv_wait (PlanetRing ring, PlanetGrant g, int rx_off, int rx_buf, int rx_lease,
                           int expect_dst_port, int expect_src_port, int max_tries,
                           out int out_payload_off, out int out_payload_len) throws IOError {
    out_payload_off = 0;
    out_payload_len = 0;
    int[] pfd = new int[1];
    pfd[0] = ring.get_fd ();
    for (int tries = 0; tries < max_tries; tries++) {
        Sys.poll_n (pfd, 1, 20);
        int rslot = ring.submit_net_rx (rx_buf, 1514, rx_lease);
        ring.kick ();
        int rlen = ring.slot_result (rslot);
        if (rlen >= 42 && g.get_be16 (rx_off + 12) == 0x0800) {
            int proto = g.get_u8 (rx_off + 23);
            if (proto == 17) {
                int ihl = (g.get_u8 (rx_off + 14) & 0x0F) * 4;
                int uoff = rx_off + 14 + ihl;
                if (rlen >= 14 + ihl + 8) {
                    int sp = g.get_be16 (uoff + 0);
                    int dp = g.get_be16 (uoff + 2);
                    int ulen = g.get_be16 (uoff + 4);
                    if (dp == expect_dst_port && (expect_src_port == 0 || sp == expect_src_port) && ulen >= 8) {
                        out_payload_off = uoff + 8;
                        out_payload_len = ulen - 8;
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

static uint8[] dns_encode_query (string name, int txid) {
    var tmp = new uint8[256];
    int p = 0;
    // Header: ID, Flags (RD=0x0100), QDCOUNT=1, AN/NS/AR=0
    tmp[p++] = (uint8) ((txid >> 8) & 0xFF);
    tmp[p++] = (uint8) (txid & 0xFF);
    tmp[p++] = 0x01;
    tmp[p++] = 0x00;
    tmp[p++] = 0x00;
    tmp[p++] = 0x01;
    for (int i = 0; i < 6; i++)
        tmp[p++] = 0x00;
    // QNAME labels (scan '.' without string.split)
    int start = 0;
    int nlen = name.length;
    while (start < nlen) {
        int end = start;
        while (end < nlen && (uint8) name[end] != '.')
            end++;
        int llen = end - start;
        if (llen > 0 && llen < 64 && p + 1 + llen < 250) {
            tmp[p++] = (uint8) llen;
            for (int i = start; i < end; i++)
                tmp[p++] = (uint8) name[i];
        }
        start = end + 1;
    }
    tmp[p++] = 0x00;
    // QTYPE = A (1), QCLASS = IN (1)
    tmp[p++] = 0x00;
    tmp[p++] = 0x01;
    tmp[p++] = 0x00;
    tmp[p++] = 0x01;
    var out_b = new uint8[p];
    for (int i = 0; i < p; i++)
        out_b[i] = tmp[i];
    return out_b;
}

static bool dns_parse_reply (PlanetGrant g, int off, int len, int expect_txid,
                             out int rcode, out string? first_a) throws IOError {
    rcode = -1;
    first_a = null;
    if (len < 12)
        return false;
    int id = g.get_be16 (off + 0);
    int flags = g.get_be16 (off + 2);
    if (id != expect_txid || (flags & 0x8000) == 0)
        return false;
    rcode = flags & 0x0F;
    int qd = g.get_be16 (off + 4);
    int an = g.get_be16 (off + 6);
    int pos = 12;
    for (int q = 0; q < qd && pos < len; q++) {
        while (pos < len) {
            int l = g.get_u8 (off + pos);
            if (l == 0) { pos++; break; }
            if ((l & 0xC0) == 0xC0) { pos += 2; break; }
            pos += 1 + l;
        }
        pos += 4;
    }
    for (int a = 0; a < an && pos + 12 <= len; a++) {
        if ((g.get_u8 (off + pos) & 0xC0) == 0xC0) {
            pos += 2;
        } else {
            while (pos < len) {
                int l = g.get_u8 (off + pos);
                if (l == 0) { pos++; break; }
                pos += 1 + l;
            }
        }
        if (pos + 10 > len)
            break;
        int rtype = g.get_be16 (off + pos);
        int rdlen = g.get_be16 (off + pos + 8);
        pos += 10;
        if (rtype == 1 && rdlen == 4 && pos + 4 <= len && first_a == null) {
            int b0 = g.get_u8 (off + pos + 0);
            int b1 = g.get_u8 (off + pos + 1);
            int b2 = g.get_u8 (off + pos + 2);
            int b3 = g.get_u8 (off + pos + 3);
            first_a = @"$b0.$b1.$b2.$b3";
        }
        pos += rdlen;
    }
    return true;
}

// --- Plan 9 tcp.c-inspired TCP engine (RACK-TLP + BBR/Copa pacing + ECN) ---
const int TCP_CLOSED      = 0;
const int TCP_LISTEN      = 1;
const int TCP_SYN_SENT    = 2;
const int TCP_SYN_RCVD    = 3;
const int TCP_ESTABLISHED = 4;
const int TCP_FIN_WAIT_1  = 5;
const int TCP_FIN_WAIT_2  = 6;
const int TCP_CLOSING     = 7;
const int TCP_TIME_WAIT   = 8;
const int TCP_CLOSE_WAIT  = 9;
const int TCP_LAST_ACK    = 10;

const int TCP_F_FIN = 0x01;
const int TCP_F_SYN = 0x02;
const int TCP_F_RST = 0x04;
const int TCP_F_PSH = 0x08;
const int TCP_F_ACK = 0x10;
const int TCP_F_ECE = 0x40;
const int TCP_F_CWR = 0x80;

const int TCP_MSS = 1460;
const int TCP_MAX_FLIGHT = 16;

static uint32 seq_u32 (int v) {
    return (uint32) v;
}

static bool seq_lt (uint32 a, uint32 b) {
    return ((a - b) & 0x80000000U) != 0;
}

static bool seq_leq (uint32 a, uint32 b) {
    return a == b || seq_lt (a, b);
}

static int tcp_checksum (PlanetGrant g, uint8[] src_ip, uint8[] dst_ip, int tcp_off, int tcp_len) throws IOError {
    int sum = 0;
    sum += ((int) src_ip[0] << 8) | (int) src_ip[1];
    sum += ((int) src_ip[2] << 8) | (int) src_ip[3];
    sum += ((int) dst_ip[0] << 8) | (int) dst_ip[1];
    sum += ((int) dst_ip[2] << 8) | (int) dst_ip[3];
    sum += 6; // IPPROTO_TCP
    sum += tcp_len;
    int i = 0;
    while (i + 1 < tcp_len) {
        sum += g.get_be16 (tcp_off + i);
        i += 2;
    }
    if (i < tcp_len)
        sum += g.get_u8 (tcp_off + i) << 8;
    while ((sum >> 16) != 0)
        sum = (sum & 0xFFFF) + (sum >> 16);
    return (~sum) & 0xFFFF;
}

class TcpConn : Object {
    public int state = TCP_CLOSED;
    public int local_port = 0;
    public int remote_port = 0;
    public uint8[] local_ip;
    public uint8[] remote_ip;
    public uint8[] local_mac;
    public uint8[] remote_mac;

    // Sequence space (RFC 793 / Plan 9 tcp.c)
    public uint32 snd_una = 0;
    public uint32 snd_nxt = 0;
    public uint32 snd_wnd = 65535;
    public uint32 rcv_nxt = 0;
    public uint32 rcv_wnd = 16384;
    public int mss = TCP_MSS;

    // Karn/Jacobson RTT + BBR/Copa-style latency/bw model (ticks + sub-ms rdtsc)
    public int srtt_ticks = 2;
    public int rttvar_ticks = 1;
    public int min_rtt_ticks = 999999;
    public uint64 min_rtt_tsc = 0;
    public int delivered_bytes = 0;
    public int bw_bytes_per_tick = 1460;
    public int cwnd = TCP_MSS * 4;
    public int last_xmit_tick = 0;

    // ECN (L4S-ready)
    public bool ecn_enabled = true;
    public bool ece_echo = false;
    public bool cwr_pending = false;
    public int ecn_reductions = 0;

    // RACK-TLP in-flight segment table (fixed size, 0 heap alloc per packet)
    private uint32[] seg_seq = new uint32[TCP_MAX_FLIGHT];
    private int[] seg_len = new int[TCP_MAX_FLIGHT];
    private int[] seg_xmit_tick = new int[TCP_MAX_FLIGHT];
    private uint64[] seg_xmit_tsc = new uint64[TCP_MAX_FLIGHT];
    private bool[] seg_retrans = new bool[TCP_MAX_FLIGHT];
    private bool[] seg_active = new bool[TCP_MAX_FLIGHT];
    private uint8[] rx_buf = new uint8[4096];
    public int rx_len = 0;
    public int rack_retrans_count = 0;
    public int tlp_probes = 0;
    private int ip_id = 0x2000;

    public TcpConn (uint8[] lip, uint8[] lmac, int lport) {
        this.local_ip = lip;
        this.local_mac = lmac;
        this.local_port = lport;
        this.remote_ip = new uint8[4];
        this.remote_mac = new uint8[6];
    }

    private void record_flight (uint32 seq, int len, int now_tick, bool is_retrans) {
        for (int i = 0; i < TCP_MAX_FLIGHT; i++) {
            if (!seg_active[i]) {
                seg_seq[i] = seq;
                seg_len[i] = len;
                seg_xmit_tick[i] = now_tick;
                seg_xmit_tsc[i] = Sys.rdtsc ();
                seg_retrans[i] = is_retrans;
                seg_active[i] = true;
                return;
            }
        }
    }

    private void update_rtt_and_bw (int sample_ticks, uint64 sample_tsc, int acked_bytes) {
        if (sample_ticks < 0)
            sample_ticks = 0;
        if (sample_ticks < min_rtt_ticks)
            min_rtt_ticks = sample_ticks;
        if (sample_tsc > 0 && (min_rtt_tsc == 0 || sample_tsc < min_rtt_tsc))
            min_rtt_tsc = sample_tsc;
        int err = sample_ticks - srtt_ticks;
        if (err < 0) err = -err;
        rttvar_ticks = (3 * rttvar_ticks + err) / 4;
        srtt_ticks = (7 * srtt_ticks + sample_ticks) / 8;
        if (srtt_ticks < 1)
            srtt_ticks = 1;
        delivered_bytes += acked_bytes;
        int denom = (sample_ticks > 0) ? sample_ticks : 1;
        int inst_bw = acked_bytes / denom;
        if (inst_bw > bw_bytes_per_tick)
            bw_bytes_per_tick = inst_bw;
        // BBR-inspired target cwnd = max(2*MSS, BDP * 5/4)
        int bdp = bw_bytes_per_tick * ((min_rtt_ticks < 999999 && min_rtt_ticks > 0) ? min_rtt_ticks : 1);
        int target = (bdp * 5) / 4;
        if (target < mss * 2)
            target = mss * 2;
        if (!ece_echo && cwnd < target)
            cwnd = target;
    }

    public int emit_segment (PlanetGrant g, int tx_off, int flags, uint8[]? payload, int now_tick, bool is_retrans = false) throws IOError {
        int opt_len = ((flags & TCP_F_SYN) != 0) ? 4 : 0;
        int hdr_len = 20 + opt_len;
        int plen = (payload != null) ? ((!) payload).length : 0;
        int tcp_len = hdr_len + plen;

        int f = flags;
        if (ece_echo && (f & TCP_F_ACK) != 0)
            f |= TCP_F_ECE;
        if (cwr_pending && plen > 0) {
            f |= TCP_F_CWR;
            cwr_pending = false;
        }
        int tos = (ecn_enabled && plen > 0) ? 0x02 : 0x00; // ECT(0)
        write_eth_ipv4 (g, tx_off, remote_mac, local_mac, local_ip, remote_ip, 6, tcp_len, ip_id++, tos);

        int toff = tx_off + 34;
        g.put_be16 (toff + 0, local_port);
        g.put_be16 (toff + 2, remote_port);
        g.put_be16 (toff + 4, (int) ((snd_nxt >> 16) & 0xFFFF));
        g.put_be16 (toff + 6, (int) (snd_nxt & 0xFFFF));
        g.put_be16 (toff + 8, (int) ((rcv_nxt >> 16) & 0xFFFF));
        g.put_be16 (toff + 10, (int) (rcv_nxt & 0xFFFF));
        g.put_u8 (toff + 12, (hdr_len / 4) << 4);
        g.put_u8 (toff + 13, f & 0xFF);
        g.put_be16 (toff + 14, (int) (rcv_wnd & 0xFFFF));
        g.put_be16 (toff + 16, 0);
        g.put_be16 (toff + 18, 0);
        if (opt_len == 4) {
            // MSS option (Kind=2, Len=4, MSS=1460)
            g.put_u8 (toff + 20, 2);
            g.put_u8 (toff + 21, 4);
            g.put_be16 (toff + 22, mss);
        }
        if (payload != null) {
            var p = (!) payload;
            for (int i = 0; i < plen; i++)
                g.put_u8 (toff + hdr_len + i, p[i]);
        }
        g.put_be16 (toff + 16, tcp_checksum (g, local_ip, remote_ip, toff, tcp_len));

        int seq_advance = plen;
        if ((flags & TCP_F_SYN) != 0) seq_advance++;
        if ((flags & TCP_F_FIN) != 0) seq_advance++;
        if (!is_retrans && seq_advance > 0) {
            record_flight (snd_nxt, plen, now_tick, false);
            snd_nxt = snd_nxt + (uint32) seq_advance;
        }
        last_xmit_tick = now_tick;
        return 14 + 20 + tcp_len;
    }

    public int connect_syn (PlanetGrant g, int tx_off, uint8[] rip, uint8[] rmac, int rport, int now_tick) throws IOError {
        for (int i = 0; i < 4; i++) remote_ip[i] = rip[i];
        for (int i = 0; i < 6; i++) remote_mac[i] = rmac[i];
        remote_port = rport;
        snd_una = 0x10001000U;
        snd_nxt = snd_una;
        state = TCP_SYN_SENT;
        return emit_segment (g, tx_off, TCP_F_SYN, null, now_tick);
    }

    public void listen () {
        state = TCP_LISTEN;
    }

    public int input (PlanetGrant g, int rx_off, int rx_len_frame, int tx_off, int now_tick) throws IOError {
        if (rx_len_frame < 54 || g.get_be16 (rx_off + 12) != 0x0800 || g.get_u8 (rx_off + 23) != 6)
            return 0;
        int ip_tos = g.get_u8 (rx_off + 15);
        int ip_tot = g.get_be16 (rx_off + 16);
        int ihl = (g.get_u8 (rx_off + 14) & 0x0F) * 4;
        int toff = rx_off + 14 + ihl;
        int tcp_len = ip_tot - ihl;
        if (tcp_len < 20 || 14 + ihl + tcp_len > rx_len_frame)
            return 0;

        int sp = g.get_be16 (toff + 0);
        int dp = g.get_be16 (toff + 2);
        if (dp != local_port)
            return 0;

        // ECN Congestion Experienced (CE = 0b11) on incoming IPv4 packet
        if ((ip_tos & 0x03) == 0x03)
            ece_echo = true;

        uint32 seg_seq_num = ((uint32) g.get_be16 (toff + 4) << 16) | (uint32) g.get_be16 (toff + 6);
        uint32 seg_ack_num = ((uint32) g.get_be16 (toff + 8) << 16) | (uint32) g.get_be16 (toff + 10);
        int data_off = ((g.get_u8 (toff + 12) >> 4) & 0x0F) * 4;
        int flags = g.get_u8 (toff + 13);
        int plen = tcp_len - data_off;
        if (data_off < 20 || plen < 0)
            return 0;

        if (state == TCP_LISTEN && (flags & TCP_F_SYN) != 0) {
            for (int i = 0; i < 4; i++) remote_ip[i] = (uint8) g.get_u8 (rx_off + 26 + i);
            for (int i = 0; i < 6; i++) remote_mac[i] = (uint8) g.get_u8 (rx_off + 6 + i);
            remote_port = sp;
            rcv_nxt = seg_seq_num + 1U;
            snd_una = 0x20002000U;
            snd_nxt = snd_una;
            state = TCP_SYN_RCVD;
            return emit_segment (g, tx_off, TCP_F_SYN | TCP_F_ACK, null, now_tick);
        }

        if (state == TCP_SYN_SENT && (flags & (TCP_F_SYN | TCP_F_ACK)) == (TCP_F_SYN | TCP_F_ACK)) {
            if (seg_ack_num == snd_nxt) {
                snd_una = seg_ack_num;
                rcv_nxt = seg_seq_num + 1U;
                state = TCP_ESTABLISHED;
                return emit_segment (g, tx_off, TCP_F_ACK, null, now_tick);
            }
            return 0;
        }

        if ((flags & TCP_F_ACK) != 0) {
            if (seq_lt (snd_una, seg_ack_num) && seq_leq (seg_ack_num, snd_nxt)) {
                int acked = (int) (seg_ack_num - snd_una);
                snd_una = seg_ack_num;
                for (int i = 0; i < TCP_MAX_FLIGHT; i++) {
                    if (seg_active[i] && seq_leq (seg_seq[i] + (uint32) seg_len[i], seg_ack_num)) {
                        if (!seg_retrans[i]) {
                            uint64 now_tsc = Sys.rdtsc ();
                            uint64 dtsc = (now_tsc > seg_xmit_tsc[i]) ? (now_tsc - seg_xmit_tsc[i]) : 0;
                            update_rtt_and_bw (now_tick - seg_xmit_tick[i], dtsc, acked);
                        }
                        seg_active[i] = false;
                    }
                }
            }
            if ((flags & TCP_F_ECE) != 0) {
                // ECN-Echo received: smooth multiplicative decrease + arm CWR
                int reduced = (cwnd * 3) / 4;
                cwnd = (reduced > mss * 2) ? reduced : (mss * 2);
                cwr_pending = true;
                ecn_reductions++;
            }
            if ((flags & TCP_F_CWR) != 0)
                ece_echo = false;
        }

        if (state == TCP_SYN_RCVD && (flags & TCP_F_ACK) != 0 && snd_una == snd_nxt) {
            state = TCP_ESTABLISHED;
        }

        bool need_ack = false;
        if (plen > 0 && seg_seq_num == rcv_nxt) {
            for (int i = 0; i < plen && rx_len < rx_buf.length; i++)
                rx_buf[rx_len++] = (uint8) g.get_u8 (toff + data_off + i);
            rcv_nxt = rcv_nxt + (uint32) plen;
            need_ack = true;
        }

        if ((flags & TCP_F_FIN) != 0) {
            rcv_nxt = rcv_nxt + 1U;
            if (state == TCP_ESTABLISHED) {
                state = TCP_CLOSE_WAIT;
                return emit_segment (g, tx_off, TCP_F_ACK, null, now_tick);
            } else if (state == TCP_FIN_WAIT_1) {
                state = (snd_una == snd_nxt) ? TCP_TIME_WAIT : TCP_CLOSING;
                return emit_segment (g, tx_off, TCP_F_ACK, null, now_tick);
            } else if (state == TCP_FIN_WAIT_2) {
                state = TCP_TIME_WAIT;
                return emit_segment (g, tx_off, TCP_F_ACK, null, now_tick);
            }
        }

        if (state == TCP_FIN_WAIT_1 && snd_una == snd_nxt)
            state = TCP_FIN_WAIT_2;
        if (state == TCP_LAST_ACK && snd_una == snd_nxt)
            state = TCP_CLOSED;

        if (need_ack)
            return emit_segment (g, tx_off, TCP_F_ACK, null, now_tick);
        return 0;
    }

    // RACK-TLP (RFC 8985): time-based loss detection + Tail Loss Probe
    public int check_rack_tlp (PlanetGrant g, int tx_off, uint8[]? retrans_payload, int now_tick) throws IOError {
        int reorder_win = (srtt_ticks > 1) ? srtt_ticks : 1;
        for (int i = 0; i < TCP_MAX_FLIGHT; i++) {
            if (seg_active[i] && !seg_retrans[i] && (now_tick - seg_xmit_tick[i]) >= (srtt_ticks + reorder_win)) {
                seg_retrans[i] = true;
                seg_xmit_tick[i] = now_tick;
                rack_retrans_count++;
                uint32 saved_nxt = snd_nxt;
                snd_nxt = seg_seq[i];
                int fl = emit_segment (g, tx_off, TCP_F_ACK | TCP_F_PSH, retrans_payload, now_tick, true);
                snd_nxt = saved_nxt;
                return fl;
            }
        }
        int pto = (srtt_ticks * 2 > 2) ? (srtt_ticks * 2) : 2;
        if (seq_lt (snd_una, snd_nxt) && (now_tick - last_xmit_tick) >= pto) {
            tlp_probes++;
            last_xmit_tick = now_tick;
            return emit_segment (g, tx_off, TCP_F_ACK, null, now_tick, true);
        }
        return 0;
    }

    public int close_fin (PlanetGrant g, int tx_off, int now_tick) throws IOError {
        if (state == TCP_ESTABLISHED)
            state = TCP_FIN_WAIT_1;
        else if (state == TCP_CLOSE_WAIT)
            state = TCP_LAST_ACK;
        return emit_segment (g, tx_off, TCP_F_FIN | TCP_F_ACK, null, now_tick);
    }
}

static string fmt_mac (uint8[] mac) {
    string hex = "0123456789abcdef";
    string s = "";
    for (int i = 0; i < 6; i++) {
        if (i > 0) s = s + ":";
        int b = (int) mac[i] & 0xFF;
        s = s + hex.substring ((b >> 4) & 0xF, 1) + hex.substring (b & 0xF, 1);
    }
    return s;
}

static int mercury_serve_loop () {
    print ("mercury:daemon ready\n");
    var conns = new GenericArray<PlanetConnection> ();
    while (true) {
        try {
            var c = PlanetConnection.accept_from_inbox ();
            if (c != null)
                conns.add ((!) c);
            for (int i = 0; i < conns.length; i++) {
                uint8[]? req = conns[i].read_request ();
                if (req != null) {
                    var r = (!) req;
                    if (r.length == 4 && r[0] == (uint8) 'Q' && r[1] == (uint8) 'U' && r[2] == (uint8) 'I' && r[3] == (uint8) 'T') {
                        uint8[] bye = { (uint8) 'B', (uint8) 'Y', (uint8) 'E' };
                        conns[i].write_response (bye);
                        return 0;
                    }
                    uint8[] pong = { (uint8) 'P', (uint8) 'O', (uint8) 'N', (uint8) 'G' };
                    conns[i].write_response (pong);
                }
            }
        } catch (IOError e) {
        }
        Sys.sleep_ms (5);
    }
}

static int main (string[] args) {
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--serve")
            return mercury_serve_loop ();
    }
    var mac = new uint8[6];
    if (Sys.net_mac (mac) < 0) {
        print ("mercury:no-device\n");
        return 1;
    }
    print (@"mercury:mac=$(fmt_mac (mac))\n");

    PlanetRing ring;
    PlanetIoArena arena;
    try {
        ring = PlanetRing.create (2, 8, PlanetRing.DEV_NET);
        arena = PlanetIoArena.create (2, 2048);
    } catch (IOError e) {
        print (@"mercury:init-fail $(e.message)\n");
        return 1;
    }

    int tx_lease = arena.acquire_lease ();
    int rx_lease = arena.acquire_lease ();
    int tx_off = ring.data_offset;
    int rx_off = tx_off + 2048;
    int tx_buf = ring.grant.base_addr + tx_off;
    int rx_buf = ring.grant.base_addr + rx_off;
    var g = ring.grant;

    // Our IP: 10.0.2.15, QEMU SLIRP gateway: 10.0.2.2
    var local_ip = InetAddress.new_from_string ("10.0.2.15");
    var gw_ip = InetAddress.new_from_string ("10.0.2.2");
    uint8[] lip = (local_ip != null) ? ((!) local_ip).to_bytes () : new uint8[4];
    uint8[] gip = (gw_ip != null) ? ((!) gw_ip).to_bytes () : new uint8[4];

    var gw_mac = new uint8[6];
    bool arp_ok = false;
    bool icmp_ok = false;

    try {
        // 1. Build Ethernet + ARP Request (42 bytes) for 10.0.2.2
        for (int i = 0; i < 6; i++) g.put_u8 (tx_off + i, 0xFF);
        for (int i = 0; i < 6; i++) g.put_u8 (tx_off + 6 + i, mac[i]);
        g.put_be16 (tx_off + 12, 0x0806);
        g.put_be16 (tx_off + 14, 1);
        g.put_be16 (tx_off + 16, 0x0800);
        g.put_u8 (tx_off + 18, 6);
        g.put_u8 (tx_off + 19, 4);
        g.put_be16 (tx_off + 20, 1);
        for (int i = 0; i < 6; i++) g.put_u8 (tx_off + 22 + i, mac[i]);
        for (int i = 0; i < 4; i++) g.put_u8 (tx_off + 28 + i, lip[i]);
        for (int i = 0; i < 6; i++) g.put_u8 (tx_off + 32 + i, 0);
        for (int i = 0; i < 4; i++) g.put_u8 (tx_off + 38 + i, gip[i]);

        ring.submit_net_tx (tx_buf, 42, tx_lease);
        ring.kick ();

        int[] pfd = new int[1];
        pfd[0] = ring.get_fd ();
        for (int tries = 0; tries < 50 && !arp_ok; tries++) {
            Sys.poll_n (pfd, 1, 20);
            int rslot = ring.submit_net_rx (rx_buf, 1514, rx_lease);
            ring.kick ();
            int rlen = ring.slot_result (rslot);
            if (rlen >= 42 && g.get_be16 (rx_off + 12) == 0x0806 && g.get_be16 (rx_off + 20) == 2) {
                if (g.get_u8 (rx_off + 28) == gip[0] && g.get_u8 (rx_off + 29) == gip[1]
                    && g.get_u8 (rx_off + 30) == gip[2] && g.get_u8 (rx_off + 31) == gip[3]) {
                    for (int i = 0; i < 6; i++)
                        gw_mac[i] = (uint8) g.get_u8 (rx_off + 22 + i);
                    arp_ok = true;
                }
            }
        }
    } catch (IOError e) {
        arp_ok = false;
    }

    if (arp_ok)
        print (@"mercury:arp=ok gw=$(fmt_mac (gw_mac))\n");
    else
        print ("mercury:arp=FAIL\n");

    // 2. Send ICMP Echo Request (ping 10.0.2.2)
    if (arp_ok) {
        try {
            for (int i = 0; i < 6; i++) g.put_u8 (tx_off + i, gw_mac[i]);
            for (int i = 0; i < 6; i++) g.put_u8 (tx_off + 6 + i, mac[i]);
            g.put_be16 (tx_off + 12, 0x0800);

            g.put_u8 (tx_off + 14, 0x45);
            g.put_u8 (tx_off + 15, 0);
            g.put_be16 (tx_off + 16, 36);
            g.put_be16 (tx_off + 18, 0x1234);
            g.put_be16 (tx_off + 20, 0x4000);
            g.put_u8 (tx_off + 22, 64);
            g.put_u8 (tx_off + 23, 1);
            g.put_be16 (tx_off + 24, 0);
            for (int i = 0; i < 4; i++) g.put_u8 (tx_off + 26 + i, lip[i]);
            for (int i = 0; i < 4; i++) g.put_u8 (tx_off + 30 + i, gip[i]);
            g.put_be16 (tx_off + 24, inet_checksum (g, tx_off + 14, 20));

            g.put_u8 (tx_off + 34, 8);
            g.put_u8 (tx_off + 35, 0);
            g.put_be16 (tx_off + 36, 0);
            g.put_be16 (tx_off + 38, 0x0001);
            g.put_be16 (tx_off + 40, 0x0001);
            for (int i = 0; i < 8; i++) g.put_u8 (tx_off + 42 + i, 0x41 + i);
            g.put_be16 (tx_off + 36, inet_checksum (g, tx_off + 34, 16));

            ring.submit_net_tx (tx_buf, 50, tx_lease);
            ring.kick ();

            int[] pfd = new int[1];
            pfd[0] = ring.get_fd ();
            for (int tries = 0; tries < 50 && !icmp_ok; tries++) {
                Sys.poll_n (pfd, 1, 20);
                int rslot = ring.submit_net_rx (rx_buf, 1514, rx_lease);
                ring.kick ();
                int rlen = ring.slot_result (rslot);
                if (rlen >= 42 && g.get_be16 (rx_off + 12) == 0x0800
                    && g.get_u8 (rx_off + 23) == 1 && g.get_u8 (rx_off + 34) == 0) {
                    icmp_ok = true;
                }
            }
        } catch (IOError e) {
            icmp_ok = false;
        }
    }

    if (icmp_ok)
        print ("mercury:icmp=ok\n");
    else
        print ("mercury:icmp=FAIL\n");

    // 3. Real UDP round-trip via QEMU SLIRP DHCP (0.0.0.0:68 -> 255.255.255.255:67)
    bool udp_ok = false;
    try {
        uint8[] bmac = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
        uint8[] z_ip = { 0, 0, 0, 0 };
        uint8[] b_ip = { 255, 255, 255, 255 };
        int xid = 0x4D524331;
        uint8[] disc = dhcp_encode_discover (mac, xid);
        udp_send (ring, g, tx_off, tx_buf, tx_lease,
                  bmac, mac, z_ip, b_ip, 68, 67, disc, 0x1235);
        int poff = 0;
        int plen = 0;
        if (udp_recv_wait (ring, g, rx_off, rx_buf, rx_lease, 68, 67, 50, out poff, out plen)) {
            int rx_xid = (g.get_be16 (poff + 4) << 16) | g.get_be16 (poff + 6);
            if (plen >= 240 && g.get_u8 (poff) == 2 && rx_xid == xid) {
                int y0 = g.get_u8 (poff + 16);
                int y1 = g.get_u8 (poff + 17);
                int y2 = g.get_u8 (poff + 18);
                int y3 = g.get_u8 (poff + 19);
                udp_ok = (y0 == 10 && y1 == 0 && y2 == 2);
                print (@"mercury:udp=ok yiaddr=$y0.$y1.$y2.$y3\n");
            }
        }
    } catch (IOError e) {
        udp_ok = false;
    }
    if (!udp_ok)
        print ("mercury:udp=FAIL\n");

    // 4. Optional DNS query over UDP (10.0.2.3:53) when host DNS is reachable
    if (arp_ok) {
        try {
            var dns_ip_addr = InetAddress.new_from_string ("10.0.2.3");
            uint8[] dns_ip = (dns_ip_addr != null) ? ((!) dns_ip_addr).to_bytes () : new uint8[4];
            int txid = 0x4D51;
            uint8[] q = dns_encode_query ("example.com", txid);
            udp_send (ring, g, tx_off, tx_buf, tx_lease,
                      gw_mac, mac, lip, dns_ip, 53001, 53, q, 0x1236);
            int poff = 0;
            int plen = 0;
            if (udp_recv_wait (ring, g, rx_off, rx_buf, rx_lease, 53001, 53, 5, out poff, out plen)) {
                int rcode = -1;
                string? ip_a = null;
                if (dns_parse_reply (g, poff, plen, txid, out rcode, out ip_a)) {
                    string ip_str = ip_a ?? "none";
                    print (@"mercury:dns=ok rcode=$rcode a=$ip_str\n");
                }
            }
        } catch (IOError e) {
        }
    }

    // 5. C3.3 TCP engine verification (Plan 9 state machine + RACK-TLP + BBR pacing + ECN)
    bool tcp_ok = false;
    try {
        var tcp_g = PlanetGrant.allocate (1);
        int buf_a = 0;
        int buf_b = 2048;
        var cli = new TcpConn (lip, mac, 41000);
        var srv = new TcpConn (lip, mac, 8080);
        srv.listen ();
        int t0 = Sys.ticks ();

        // 3-way handshake: SYN -> SYN|ACK -> ACK
        int l1 = cli.connect_syn (tcp_g, buf_a, lip, mac, 8080, t0);
        int l2 = srv.input (tcp_g, buf_a, l1, buf_b, t0);
        int l3 = cli.input (tcp_g, buf_b, l2, buf_a, t0 + 1);
        srv.input (tcp_g, buf_a, l3, buf_b, t0 + 1);
        bool hs_ok = (cli.state == TCP_ESTABLISHED && srv.state == TCP_ESTABLISHED);

        // Data transfer with ECN CE simulation -> ECE -> CWR
        uint8[] payload = { (uint8) 't', (uint8) 'c', (uint8) 'p', (uint8) '!' };
        int ld = cli.emit_segment (tcp_g, buf_a, TCP_F_ACK | TCP_F_PSH, payload, t0 + 1);
        // Simulate router marking CE (0b11) in IPv4 ToS byte
        tcp_g.put_u8 (buf_a + 15, tcp_g.get_u8 (buf_a + 15) | 0x03);
        int lack = srv.input (tcp_g, buf_a, ld, buf_b, t0 + 2);
        cli.input (tcp_g, buf_b, lack, buf_a, t0 + 2);
        bool ecn_ok = (cli.ecn_reductions == 1 && cli.cwr_pending);

        // Simulated packet drop -> RACK-TLP time-based retransmission
        uint8[] lost_seg = { (uint8) 'r', (uint8) 'a', (uint8) 'c', (uint8) 'k' };
        cli.emit_segment (tcp_g, buf_a, TCP_F_ACK | TCP_F_PSH, lost_seg, t0 + 2);
        int lrack = cli.check_rack_tlp (tcp_g, buf_a, lost_seg, t0 + 20);
        if (lrack > 0) {
            int lack2 = srv.input (tcp_g, buf_a, lrack, buf_b, t0 + 20);
            cli.input (tcp_g, buf_b, lack2, buf_a, t0 + 21);
        }
        bool rack_ok = (cli.rack_retrans_count == 1 && srv.rx_len == 8);

        // Graceful FIN teardown
        int lf1 = cli.close_fin (tcp_g, buf_a, t0 + 22);
        int lf2 = srv.input (tcp_g, buf_a, lf1, buf_b, t0 + 22);
        cli.input (tcp_g, buf_b, lf2, buf_a, t0 + 22);
        int lf3 = srv.close_fin (tcp_g, buf_b, t0 + 23);
        int lf4 = cli.input (tcp_g, buf_b, lf3, buf_a, t0 + 23);
        srv.input (tcp_g, buf_a, lf4, buf_b, t0 + 23);
        bool fin_ok = (cli.state == TCP_TIME_WAIT && srv.state == TCP_CLOSED);

        tcp_ok = hs_ok && ecn_ok && rack_ok && fin_ok && cli.min_rtt_tsc > 0;
        if (tcp_ok)
            print (@"mercury:tcp=ok mss=$(cli.mss) rack=$(cli.rack_retrans_count) ecn=$(cli.ecn_reductions) rdtsc=$(cli.min_rtt_tsc)\n");
        tcp_g.release ();
    } catch (IOError e) {
        tcp_ok = false;
    }
    if (!tcp_ok)
        print ("mercury:tcp=FAIL\n");

    // 6. C3.2/C3.3 PlanetConnection IPC service check
    bool ipc_ok = false;
    try {
        var iconn = PlanetConnection.create (1);
        iconn.send_to (Sys.tid ());
        var srv_c = PlanetConnection.accept_from_inbox ();
        if (srv_c != null) {
            uint8[] req = { (uint8) 'P', (uint8) 'I', (uint8) 'N', (uint8) 'G' };
            iconn.write_request (req);
            uint8[]? got = ((!) srv_c).read_request ();
            if (got != null && ((!) got).length == 4 && ((!) got)[0] == (uint8) 'P') {
                uint8[] resp = { (uint8) 'P', (uint8) 'O', (uint8) 'N', (uint8) 'G' };
                ((!) srv_c).write_response (resp);
                uint8[]? r2 = iconn.read_response ();
                ipc_ok = r2 != null && ((!) r2).length == 4 && ((!) r2)[0] == (uint8) 'P' && ((!) r2)[1] == (uint8) 'O';
            }
            ((!) srv_c).close ();
        }
        iconn.close ();
    } catch (IOError e) {
        ipc_ok = false;
    }
    print (ipc_ok ? "mercury:ipc=ok\n" : "mercury:ipc=FAIL\n");

    arena.release_lease (tx_lease);
    arena.release_lease (rx_lease);
    arena.close ();
    ring.close ();

    int ok_flag = (arp_ok && icmp_ok && udp_ok && tcp_ok && ipc_ok) ? 1 : 0;
    print (@"mercury:summary ok=$ok_flag\n");
    return (ok_flag == 1) ? 0 : 1;
}
