// Pure-Vala Venus / VirtIO-GPU 3D userland bridge for PlanetOS.
// Bridges Sys.gpu_* syscalls (VirtIO-GPU CAPSET_VENUS / VIRGL) with
// planc --target=spirv modules.

using Planet;

namespace Venus {

    public const int CAPSET_VIRGL  = 1;
    public const int CAPSET_VIRGL2 = 2;
    public const int CAPSET_VENUS  = 4;

    // Minimal Venus protocol command opcodes (Mesa virtio_vulkan / venus-protocol)
    public const int VK_CMD_CREATE_INSTANCE      = 1;
    public const int VK_CMD_DESTROY_INSTANCE     = 2;
    public const int VK_CMD_CREATE_DEVICE        = 9;
    public const int VK_CMD_CREATE_SHADER_MODULE = 35;
    public const int VK_CMD_QUEUE_SUBMIT         = 55;

    public class GpuCaps : Object {
        public bool present { get; private set; }
        public bool virgl { get; private set; }
        public bool blob { get; private set; }
        public bool ctx_init { get; private set; }
        public bool venus { get; private set; }
        public int width { get; private set; }
        public int height { get; private set; }

        public GpuCaps () {
            int raw = Sys.gpu_info ();
            present  = (raw & 1) != 0;
            virgl    = (raw & 2) != 0;
            blob     = (raw & 4) != 0;
            ctx_init = (raw & 8) != 0;
            venus    = (raw & 16) != 0;
            width    = (raw >> 16) & 0xFFFF;
            height   = (raw >> 32) & 0xFFFF;
        }
    }

    public class CommandEncoder : Object {
        private uint8[] buf;
        private int pos;
        private int cap;

        public CommandEncoder (int capacity = 4096) {
            cap = (capacity < 256) ? 256 : capacity;
            buf = new uint8[cap];
            pos = 0;
        }

        public void reset () {
            pos = 0;
        }

        public int length () {
            return pos;
        }

        public void write_u32 (int v) {
            if (pos + 4 > cap)
                return;
            buf[pos + 0] = (uint8) (v & 0xFF);
            buf[pos + 1] = (uint8) ((v >> 8) & 0xFF);
            buf[pos + 2] = (uint8) ((v >> 16) & 0xFF);
            buf[pos + 3] = (uint8) ((v >> 24) & 0xFF);
            pos += 4;
        }

        public void write_u64 (int v) {
            write_u32 (v & 0xFFFFFFFF);
            write_u32 ((v >> 32) & 0xFFFFFFFF);
        }

        public void encode_header (int cmd_type, int cmd_flags) {
            write_u32 (cmd_type);
            write_u32 (cmd_flags);
        }

        public void encode_shader_module (uint8[] spv_bytes, int spv_len) {
            encode_header (VK_CMD_CREATE_SHADER_MODULE, 0);
            write_u32 (spv_len);
            int n = (spv_len < spv_bytes.length) ? spv_len : spv_bytes.length;
            for (int i = 0; i < n && pos < cap; i++) {
                buf[pos] = spv_bytes[i];
                pos++;
            }
            while ((pos & 3) != 0 && pos < cap) {
                buf[pos] = 0;
                pos++;
            }
        }

        public bool submit (int ctx_id) {
            if (pos <= 0)
                return false;
            return Sys.gpu_submit_3d (ctx_id, buf, pos) == 0;
        }
    }

    public class Context : Object {
        public int ctx_id { get; private set; }
        public int capset_id { get; private set; }
        public bool active { get; private set; }

        public Context (int id, int capset = CAPSET_VENUS) {
            ctx_id = id;
            capset_id = capset;
            active = (Sys.gpu_ctx_create (id, capset) == 0);
        }

        public bool submit (CommandEncoder enc) {
            if (!active)
                return false;
            return enc.submit (ctx_id);
        }

        public void destroy () {
            if (active) {
                Sys.gpu_ctx_destroy (ctx_id);
                active = false;
            }
        }
    }
}
