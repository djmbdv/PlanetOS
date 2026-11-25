// Pure-Vala Gio.Planet (gio-planet-1.0): PlanetOS handles, grants, and rings.
using GLib;
using Planet;

namespace Gio {

    /**
     * InputStream backed by a PlanetOS handle, analogous to UnixInputStream.
     */
    public class PlanetInputStream : InputStream, PollableInputStream, FileDescriptorBased {
        private int handle;
        private bool close_handle;

        public PlanetInputStream (int handle, bool close_handle = true) {
            this.handle = handle;
            this.close_handle = close_handle;
        }

        ~PlanetInputStream () {
            if (close_handle && !closed && handle >= 3) {
                Sys.close (handle);
                handle = -1;
                closed = true;
            }
        }

        public int get_handle () {
            return handle;
        }

        public bool get_close_handle () {
            return close_handle;
        }

        public void set_close_handle (bool close_handle) {
            this.close_handle = close_handle;
        }

        public int get_fd () {
            return handle;
        }

        public bool is_readable () {
            return !closed && handle >= 0;
        }

        public Source create_source (Cancellable? cancellable = null) {
            if (cancellable != null && cancellable.is_cancelled ()) {
                SourceFunc noop = () => { return false; };
                return cancellable.create_source (noop);
            }
            var src = new Source (0, Source.KIND_WATCH, 0, 0, null);
            src.fd = handle;
            src.condition = 1;
            return src;
        }

        public override int read (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed || handle < 0)
                throw new IOError.CLOSED ("Stream is already closed");
            if (buffer.length == 0)
                return 0;
            int n = Sys.read (handle, buffer, buffer.length);
            if (n < 0)
                throw_io_error ("PlanetInputStream.read");
            return n;
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                return true;
            closed = true;
            if (close_handle && handle >= 3) {
                int r = Sys.close (handle);
                handle = -1;
                if (r < 0)
                    throw_io_error ("PlanetInputStream.close");
            }
            return true;
        }
    }

    /**
     * OutputStream backed by a PlanetOS handle, analogous to UnixOutputStream.
     */
    public class PlanetOutputStream : OutputStream, PollableOutputStream, FileDescriptorBased {
        private int handle;
        private bool close_handle;

        public PlanetOutputStream (int handle, bool close_handle = true) {
            this.handle = handle;
            this.close_handle = close_handle;
        }

        ~PlanetOutputStream () {
            if (close_handle && !closed && handle >= 3) {
                Sys.close (handle);
                handle = -1;
                closed = true;
            }
        }

        public int get_handle () {
            return handle;
        }

        public bool get_close_handle () {
            return close_handle;
        }

        public void set_close_handle (bool close_handle) {
            this.close_handle = close_handle;
        }

        public int get_fd () {
            return handle;
        }

        public bool is_writable () {
            return !closed && handle >= 0;
        }

        public Source create_source (Cancellable? cancellable = null) {
            if (cancellable != null && cancellable.is_cancelled ()) {
                SourceFunc noop = () => { return false; };
                return cancellable.create_source (noop);
            }
            var src = new Source (0, Source.KIND_WATCH, 0, 0, null);
            src.fd = handle;
            src.condition = 2;
            return src;
        }

        public override int write (uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed || handle < 0)
                throw new IOError.CLOSED ("Stream is already closed");
            if (buffer.length == 0)
                return 0;
            int n = Sys.write (handle, buffer, buffer.length);
            if (n < 0)
                throw_io_error ("PlanetOutputStream.write");
            return n;
        }

        public override bool close (Cancellable? cancellable = null) throws IOError {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Operation was cancelled");
            if (closed)
                return true;
            closed = true;
            if (close_handle && handle >= 3) {
                int r = Sys.close (handle);
                handle = -1;
                if (r < 0)
                    throw_io_error ("PlanetOutputStream.close");
            }
            return true;
        }
    }

    /**
     * Zero-copy page-owned memory capability (SYS_ALLOC_PAGE + SYS_GRANT).
     */
    public class PlanetGrant : Object {
        public int base_addr { get; private set; default = 0; }
        public int byte_len { get; private set; default = 0; }
        public int handle { get; private set; default = -1; }
        private bool owns_pages = false;

        private PlanetGrant (int addr, int len, int grant_handle, bool owns_pages) {
            this.base_addr = addr;
            this.byte_len = len;
            this.handle = grant_handle;
            this.owns_pages = owns_pages;
        }

        ~PlanetGrant () {
            release ();
        }

        public static PlanetGrant allocate (int pages) throws IOError {
            if (pages <= 0)
                throw new IOError.INVALID_ARGUMENT ("PlanetGrant.allocate: pages must be > 0");
            int addr = Sys.alloc_pages (pages);
            if (addr <= 0)
                throw_io_error ("PlanetGrant.allocate(alloc_pages)");
            int len = pages * 4096;
            int gh = Sys.grant (addr, len);
            if (gh < 0) {
                Sys.free_page (addr);
                throw_io_error ("PlanetGrant.allocate(grant)");
            }
            return new PlanetGrant (addr, len, gh, true);
        }

        public static PlanetGrant from_received (int handle) throws IOError {
            if (handle < 0)
                throw new IOError.INVALID_ARGUMENT ("PlanetGrant.from_received: invalid handle");
            int addr = 0;
            int len = 0;
            int kind = Sys.handle_info (handle, out addr, out len);
            if (kind <= 0 || addr <= 0 || len <= 0)
                throw_io_error ("PlanetGrant.from_received(handle_info)");
            if (Sys.map_user_at (addr, len) < 0)
                throw_io_error ("PlanetGrant.from_received(map_user_at)");
            return new PlanetGrant (addr, len, handle, false);
        }

        public void share_with (int tid) throws IOError {
            if (handle < 0)
                throw new IOError.CLOSED ("PlanetGrant is closed");
            if (Sys.grant_share (handle, tid) < 0)
                throw_io_error ("PlanetGrant.share_with");
        }

        /**
         * Bounds-checked copy out of the granted pages (1 peek32 per 4 bytes).
         */
        public int read_bytes (int offset, uint8[] out_buf, int count) throws IOError {
            if (base_addr <= 0)
                throw new IOError.CLOSED ("PlanetGrant is closed");
            if (offset < 0 || count < 0 || offset + count > byte_len || count > out_buf.length)
                throw new IOError.INVALID_ARGUMENT ("PlanetGrant.read_bytes: out of bounds");
            int i = 0;
            if ((offset & 3) == 0) {
                while (i + 4 <= count) {
                    int w = Unsafe.peek32 (base_addr + offset + i);
                    out_buf[i + 0] = (uint8) (w & 0xFF);
                    out_buf[i + 1] = (uint8) ((w >> 8) & 0xFF);
                    out_buf[i + 2] = (uint8) ((w >> 16) & 0xFF);
                    out_buf[i + 3] = (uint8) ((w >> 24) & 0xFF);
                    i += 4;
                }
            }
            while (i < count) {
                int addr = base_addr + offset + i;
                int w = Unsafe.peek32 (addr & ~3);
                out_buf[i] = (uint8) ((w >> ((addr & 3) * 8)) & 0xFF);
                i++;
            }
            return count;
        }

        public int get_u8 (int offset) throws IOError {
            if (base_addr <= 0)
                throw new IOError.CLOSED ("PlanetGrant is closed");
            if (offset < 0 || offset >= byte_len)
                throw new IOError.INVALID_ARGUMENT ("PlanetGrant.get_u8: out of bounds");
            int addr = base_addr + offset;
            int w = Unsafe.peek32 (addr & ~3);
            return (w >> ((addr & 3) * 8)) & 0xFF;
        }

        public void put_u8 (int offset, int val) throws IOError {
            if (base_addr <= 0)
                throw new IOError.CLOSED ("PlanetGrant is closed");
            if (offset < 0 || offset >= byte_len)
                throw new IOError.INVALID_ARGUMENT ("PlanetGrant.put_u8: out of bounds");
            int addr = base_addr + offset;
            int aligned = addr & ~3;
            int shift = (addr & 3) * 8;
            int w = Unsafe.peek32 (aligned);
            Unsafe.poke32 (aligned, (w & ~(0xFF << shift)) | ((val & 0xFF) << shift));
        }

        public int get_be16 (int offset) throws IOError {
            return (get_u8 (offset) << 8) | get_u8 (offset + 1);
        }

        public void put_be16 (int offset, int val) throws IOError {
            put_u8 (offset, (val >> 8) & 0xFF);
            put_u8 (offset + 1, val & 0xFF);
        }

        public int write_bytes (int offset, uint8[] data, int count) throws IOError {
            if (base_addr <= 0)
                throw new IOError.CLOSED ("PlanetGrant is closed");
            if (offset < 0 || count < 0 || offset + count > byte_len || count > data.length)
                throw new IOError.INVALID_ARGUMENT ("PlanetGrant.write_bytes: out of bounds");
            int i = 0;
            if ((offset & 3) == 0) {
                while (i + 4 <= count) {
                    int w = ((int) data[i + 0] & 0xFF)
                            | (((int) data[i + 1] & 0xFF) << 8)
                            | (((int) data[i + 2] & 0xFF) << 16)
                            | (((int) data[i + 3] & 0xFF) << 24);
                    Unsafe.poke32 (base_addr + offset + i, w);
                    i += 4;
                }
            }
            while (i < count) {
                put_u8 (offset + i, (int) data[i]);
                i++;
            }
            return count;
        }

        public void release () {
            if (handle >= 0) {
                Sys.close (handle);
                handle = -1;
            }
            if (owns_pages && base_addr > 0) {
                Sys.free_page (base_addr);
                base_addr = 0;
                owns_pages = false;
            }
        }
    }

    /**
     * Shared PLNR descriptor ring over a PlanetGrant (Contract B).
     */
    public class PlanetRing : Object, FileDescriptorBased {
        public const int MAGIC = 0x524E4C50; // "PLNR"
        public const int VERSION = 1;
        public const int ENTRY_SIZE = 32;
        public const int HEADER_SIZE = 64;

        public const int OP_READ = 1;
        public const int OP_WRITE = 2;
        public const int OP_FENCE = 4;
        public const int OP_MORE = 8;

        public const int ST_FREE = 0;
        public const int ST_READY = 1;
        public const int ST_DONE = 2;
        public const int ST_ERROR = 3;

        public const int DEV_ECHO = 0;
        public const int DEV_BLK = 1;
        public const int DEV_NET = 2;

        public PlanetGrant grant { get; private set; }
        public int entries { get; private set; }
        public int ring_handle { get; private set; default = -1; }
        public int data_offset { get; private set; }
        private int next_slot = 0;

        private PlanetRing (PlanetGrant grant, int entries, int ring_handle) {
            this.grant = grant;
            this.entries = entries;
            this.ring_handle = ring_handle;
            this.data_offset = HEADER_SIZE + entries * ENTRY_SIZE;
        }

        ~PlanetRing () {
            close ();
        }

        public static PlanetRing create (int pages, int entries, int dev_kind = 0) throws IOError {
            if (entries <= 0 || (entries & (entries - 1)) != 0)
                throw new IOError.INVALID_ARGUMENT ("PlanetRing.create: entries must be a power of two");
            var g = PlanetGrant.allocate (pages);
            int base_addr = g.base_addr;
            if (HEADER_SIZE + entries * ENTRY_SIZE > g.byte_len) {
                g.release ();
                throw new IOError.INVALID_ARGUMENT ("PlanetRing.create: ring exceeds grant size");
            }
            Unsafe.poke32 (base_addr + 0x00, MAGIC);
            Unsafe.poke32 (base_addr + 0x04, VERSION);
            Unsafe.poke32 (base_addr + 0x08, entries);
            Unsafe.poke32 (base_addr + 0x0C, ENTRY_SIZE);
            Unsafe.poke32 (base_addr + 0x10, 0); // head
            Unsafe.poke32 (base_addr + 0x14, 0); // tail
            Unsafe.poke32 (base_addr + 0x18, 0); // seq
            Unsafe.poke32 (base_addr + 0x1C, 0); // wake_word
            int rh = Sys.ring_attach_dev (g.handle, entries, dev_kind);
            if (rh < 0) {
                g.release ();
                throw_io_error ("PlanetRing.create(ring_attach)");
            }
            return new PlanetRing (g, entries, rh);
        }

        public int get_fd () {
            return ring_handle;
        }

        public int head () {
            return Unsafe.peek32 (grant.base_addr + 0x10);
        }

        public int tail () {
            return Unsafe.peek32 (grant.base_addr + 0x14);
        }

        public int seq () {
            return Unsafe.peek32 (grant.base_addr + 0x18);
        }

        public bool has_pending () {
            return head () != tail ();
        }

        public int slot_addr (int index) {
            int idx = index & (entries - 1);
            return grant.base_addr + HEADER_SIZE + idx * ENTRY_SIZE;
        }

        public int submit (int buf_addr, int length, int flags, int lease_id = 0) throws IOError {
            if (ring_handle < 0)
                throw new IOError.CLOSED ("PlanetRing is closed");
            int idx = next_slot;
            int d = slot_addr (idx);
            Unsafe.poke32 (d + 0x00, buf_addr);
            Unsafe.poke32 (d + 0x04, 0);
            Unsafe.poke32 (d + 0x08, length);
            Unsafe.poke32 (d + 0x0C, flags);
            Unsafe.poke32 (d + 0x10, lease_id);
            Unsafe.poke32 (d + 0x14, ST_READY);
            Unsafe.poke32 (d + 0x18, 0);
            Unsafe.poke32 (d + 0x1C, 0);
            next_slot = (idx + 1) & (entries - 1);
            Unsafe.poke32 (grant.base_addr + 0x14, next_slot);
            return idx;
        }

        public int submit_blk (int buf_addr, int lba, int sectors, int lease_id = 0) throws IOError {
            if (ring_handle < 0)
                throw new IOError.CLOSED ("PlanetRing is closed");
            int idx = next_slot;
            int d = slot_addr (idx);
            Unsafe.poke32 (d + 0x00, buf_addr);
            Unsafe.poke32 (d + 0x04, 0);
            Unsafe.poke32 (d + 0x08, sectors * 512);
            Unsafe.poke32 (d + 0x0C, OP_READ);
            Unsafe.poke32 (d + 0x10, lease_id);
            Unsafe.poke32 (d + 0x14, ST_READY);
            Unsafe.poke32 (d + 0x18, lba);
            Unsafe.poke32 (d + 0x1C, 0);
            next_slot = (idx + 1) & (entries - 1);
            Unsafe.poke32 (grant.base_addr + 0x14, next_slot);
            return idx;
        }

        public int slot_status (int index) {
            return Unsafe.peek32 (slot_addr (index) + 0x14);
        }

        public int slot_result (int index) {
            return Unsafe.peek32 (slot_addr (index) + 0x18);
        }

        public int submit_net_tx (int buf_addr, int length, int lease_id = 0) throws IOError {
            return submit (buf_addr, length, OP_WRITE, lease_id);
        }

        public int submit_net_rx (int buf_addr, int max_length, int lease_id = 0) throws IOError {
            return submit (buf_addr, max_length, OP_READ, lease_id);
        }

        public void kick () throws IOError {
            if (ring_handle < 0)
                throw new IOError.CLOSED ("PlanetRing is closed");
            if (Sys.ring_kick (ring_handle) < 0)
                throw_io_error ("PlanetRing.kick");
        }

        /**
         * Returns a GLib.Source that checks ring completion in shared memory
         * with zero syscalls before dispatching `callback`.
         */
        public Source create_source (SourceFunc callback) {
            var state = new RingWatchState (this, seq (), callback);
            var src = new Source (0, Source.KIND_CUSTOM, 0, 0, null);
            src.check_func = () => {
                return state.ring.seq () != state.seen_seq || state.ring.has_pending ();
            };
            src.func = () => {
                state.seen_seq = state.ring.seq ();
                return state.callback ();
            };
            return src;
        }

        public void close () {
            if (ring_handle >= 0) {
                Sys.close (ring_handle);
                ring_handle = -1;
            }
            grant.release ();
        }
    }

    private class RingWatchState : Object {
        public PlanetRing ring;
        public int seen_seq;
        public SourceFunc callback;

        public RingWatchState (PlanetRing ring, int seen_seq, SourceFunc callback) {
            this.ring = ring;
            this.seen_seq = seen_seq;
            this.callback = callback;
        }
    }

    /**
     * Pre-mapped zero-copy buffer pool with Phase-D lease state tracking
     * (FREE -> APP -> DEVICE -> APP -> FREE).
     */
    public class PlanetIoArena : Object {
        public const int LEASE_FREE = 0;
        public const int LEASE_APP = 1;
        public const int LEASE_DEVICE = 2;

        public PlanetGrant grant { get; private set; }
        public int slot_size { get; private set; }
        public int slot_count { get; private set; }
        public bool quarantined { get; private set; default = false; }
        private int[] states;

        private PlanetIoArena (PlanetGrant grant, int slot_size, int slot_count) {
            this.grant = grant;
            this.slot_size = slot_size;
            this.slot_count = slot_count;
            this.states = new int[slot_count];
            for (int i = 0; i < slot_count; i++)
                this.states[i] = LEASE_FREE;
        }

        ~PlanetIoArena () {
            close ();
        }

        public static PlanetIoArena create (int pages, int slot_size) throws IOError {
            if (slot_size <= 0 || (slot_size & 63) != 0)
                throw new IOError.INVALID_ARGUMENT ("PlanetIoArena.create: slot_size must be a positive multiple of 64");
            var g = PlanetGrant.allocate (pages);
            int count = g.byte_len / slot_size;
            if (count <= 0) {
                g.release ();
                throw new IOError.INVALID_ARGUMENT ("PlanetIoArena.create: arena too small for slot_size");
            }
            return new PlanetIoArena (g, slot_size, count);
        }

        public int acquire_lease () {
            if (quarantined)
                return -1;
            for (int i = 0; i < slot_count; i++) {
                if (states[i] == LEASE_FREE) {
                    states[i] = LEASE_APP;
                    return i;
                }
            }
            return -1;
        }

        public int lease_state (int lease_id) {
            if (lease_id < 0 || lease_id >= slot_count)
                return -1;
            return states[lease_id];
        }

        public int lease_addr (int lease_id) {
            if (lease_id < 0 || lease_id >= slot_count)
                return 0;
            return grant.base_addr + lease_id * slot_size;
        }

        public bool mark_device (int lease_id) {
            if (lease_id < 0 || lease_id >= slot_count)
                return false;
            if (states[lease_id] != LEASE_APP)
                return false;
            states[lease_id] = LEASE_DEVICE;
            return true;
        }

        public bool mark_app (int lease_id) {
            if (lease_id < 0 || lease_id >= slot_count)
                return false;
            if (states[lease_id] != LEASE_DEVICE)
                return false;
            states[lease_id] = LEASE_APP;
            return true;
        }

        public bool release_lease (int lease_id) {
            if (lease_id < 0 || lease_id >= slot_count)
                return false;
            if (states[lease_id] != LEASE_APP)
                return false;
            states[lease_id] = LEASE_FREE;
            return true;
        }

        public int active_device_leases () {
            int n = 0;
            for (int i = 0; i < slot_count; i++) {
                if (states[i] == LEASE_DEVICE)
                    n++;
            }
            return n;
        }

        public bool close () {
            if (active_device_leases () > 0) {
                quarantined = true;
                return false;
            }
            grant.release ();
            return true;
        }
    }

    /**
     * Block device client backed by a kernel-validated PlanetRing (DEV_BLK).
     */
    public class PlanetBlockDevice : Object {
        public PlanetRing ring { get; private set; }
        public int data_addr { get; private set; }
        public int max_sectors { get; private set; }

        private PlanetBlockDevice (PlanetRing ring) {
            this.ring = ring;
            this.data_addr = ring.grant.base_addr + ring.data_offset;
            this.max_sectors = (ring.grant.byte_len - ring.data_offset) / 512;
        }

        ~PlanetBlockDevice () {
            close ();
        }

        public static PlanetBlockDevice open (int pages = 2, int entries = 4) throws IOError {
            var r = PlanetRing.create (pages, entries, PlanetRing.DEV_BLK);
            return new PlanetBlockDevice (r);
        }

        public int read_sectors (int lba, int sectors, uint8[] out_buf) throws IOError {
            if (ring.ring_handle < 0)
                throw new IOError.CLOSED ("PlanetBlockDevice is closed");
            if (sectors <= 0 || sectors > max_sectors || out_buf.length < sectors * 512)
                throw new IOError.INVALID_ARGUMENT ("PlanetBlockDevice.read_sectors: invalid sector count or buffer");
            int slot = ring.submit_blk (data_addr, lba, sectors, 0);
            ring.kick ();
            if (ring.slot_status (slot) != PlanetRing.ST_DONE)
                throw new IOError.FAILED ("PlanetBlockDevice.read_sectors: I/O error");
            int bytes = sectors * 512;
            ring.grant.read_bytes (ring.data_offset, out_buf, bytes);
            return bytes;
        }

        public void close () {
            ring.close ();
        }
    }

    /**
     * Zero-copy IPC channel backed by a shared PlanetGrant transferred via SYS_HANDLE_SEND.
     * Header (64 bytes):
     *   +0x00: req_seq (int32), +0x04: req_len (int32)
     *   +0x08: resp_seq (int32), +0x0C: resp_len (int32)
     * Payload slots: [64 .. 64 + max_payload) for request, [64 + max_payload ..) for response.
     */
    public class PlanetConnection : Object {
        public PlanetGrant grant { get; private set; }
        public int max_payload { get; private set; }
        private int req_seen = 0;
        private int resp_seen = 0;

        private PlanetConnection (PlanetGrant grant) {
            this.grant = grant;
            int half = (grant.byte_len - 64) / 2;
            this.max_payload = (half > 0) ? half : 0;
        }

        ~PlanetConnection () {
            close ();
        }

        public static PlanetConnection create (int pages = 1) throws IOError {
            var g = PlanetGrant.allocate (pages);
            for (int i = 0; i < 64; i += 4)
                Unsafe.poke32 (g.base_addr + i, 0);
            Unsafe.mfence ();
            return new PlanetConnection (g);
        }

        public static PlanetConnection? accept_from_inbox () throws IOError {
            int h = Sys.handle_recv ();
            if (h < 0)
                return null;
            var g = PlanetGrant.from_received (h);
            return new PlanetConnection (g);
        }

        public int send_to (int target_tid) throws IOError {
            if (grant.handle < 0)
                throw new IOError.CLOSED ("PlanetConnection is closed");
            int nh = Sys.handle_send (target_tid, grant.handle);
            if (nh < 0)
                throw_io_error ("PlanetConnection.send_to");
            return nh;
        }

        private void write_slot (int seq_off, int len_off, int data_off, uint8[] data) throws IOError {
            if (grant.base_addr <= 0)
                throw new IOError.CLOSED ("PlanetConnection is closed");
            if (data.length > max_payload)
                throw new IOError.INVALID_ARGUMENT ("PlanetConnection: payload too large");
            grant.write_bytes (data_off, data, data.length);
            Unsafe.poke32 (grant.base_addr + len_off, data.length);
            int next_seq = Unsafe.peek32 (grant.base_addr + seq_off) + 1;
            Unsafe.mfence ();
            Unsafe.poke32 (grant.base_addr + seq_off, next_seq);
        }

        private uint8[]? read_slot (int seq_off, int len_off, int data_off, ref int seen) throws IOError {
            if (grant.base_addr <= 0)
                throw new IOError.CLOSED ("PlanetConnection is closed");
            int seq = Unsafe.peek32 (grant.base_addr + seq_off);
            if (seq == seen)
                return null;
            Unsafe.mfence ();
            seen = seq;
            int len = Unsafe.peek32 (grant.base_addr + len_off);
            if (len < 0 || len > max_payload)
                throw new IOError.FAILED ("PlanetConnection: corrupt length");
            var buf = new uint8[len];
            if (len > 0)
                grant.read_bytes (data_off, buf, len);
            return buf;
        }

        public void write_request (uint8[] data) throws IOError {
            write_slot (0x00, 0x04, 64, data);
        }

        public uint8[]? read_request () throws IOError {
            return read_slot (0x00, 0x04, 64, ref req_seen);
        }

        public void write_response (uint8[] data) throws IOError {
            write_slot (0x08, 0x0C, 64 + max_payload, data);
        }

        public uint8[]? read_response () throws IOError {
            return read_slot (0x08, 0x0C, 64 + max_payload, ref resp_seen);
        }

        public void close () {
            grant.release ();
        }
    }
}
