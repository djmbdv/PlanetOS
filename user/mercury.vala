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
                            uint8[] src_ip, uint8[] dst_ip, int proto, int l4_len, int ip_id) throws IOError {
    for (int i = 0; i < 6; i++) g.put_u8 (off + i, dst_mac[i]);
    for (int i = 0; i < 6; i++) g.put_u8 (off + 6 + i, src_mac[i]);
    g.put_be16 (off + 12, 0x0800);

    int ip_off = off + 14;
    g.put_u8 (ip_off + 0, 0x45);
    g.put_u8 (ip_off + 1, 0);
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

static int main (string[] args) {
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

    arena.release_lease (tx_lease);
    arena.release_lease (rx_lease);
    arena.close ();
    ring.close ();

    int ok_flag = (arp_ok && icmp_ok && udp_ok) ? 1 : 0;
    print (@"mercury:summary ok=$ok_flag\n");
    return (ok_flag == 1) ? 0 : 1;
}
