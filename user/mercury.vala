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

    arena.release_lease (tx_lease);
    arena.release_lease (rx_lease);
    arena.close ();
    ring.close ();

    int ok_flag = (arp_ok && icmp_ok) ? 1 : 0;
    print (@"mercury:summary ok=$ok_flag\n");
    return (ok_flag == 1) ? 0 : 1;
}
