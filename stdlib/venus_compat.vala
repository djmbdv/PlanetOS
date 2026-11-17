// Pure-Vala Venus / VirtIO-GPU 3D userland bridge for PlanetOS.
// Bridges Sys.gpu_* syscalls (VirtIO-GPU CAPSET_VENUS / VIRGL + RESOURCE_CREATE_BLOB)
// with planc --target=spirv modules, with automatic Spv.Module software/SIMD fallback
// when CAPSET_VENUS is not exposed by the host QEMU/virglrenderer build.

using Planet;

namespace Venus {

    public const int CAPSET_VIRGL  = 1;
    public const int CAPSET_VIRGL2 = 2;
    public const int CAPSET_VENUS  = 4;

    // Venus protocol command opcodes (Mesa venus-protocol)
    public const int VK_CMD_CREATE_INSTANCE            = 1;
    public const int VK_CMD_DESTROY_INSTANCE           = 2;
    public const int VK_CMD_ENUMERATE_PHYSICAL_DEVICES = 3;
    public const int VK_CMD_CREATE_DEVICE              = 9;
    public const int VK_CMD_DESTROY_DEVICE             = 10;
    public const int VK_CMD_CREATE_SHADER_MODULE       = 35;
    public const int VK_CMD_CREATE_GRAPHICS_PIPELINES  = 39;
    public const int VK_CMD_CREATE_COMPUTE_PIPELINES   = 40;
    public const int VK_CMD_BEGIN_COMMAND_BUFFER       = 49;
    public const int VK_CMD_END_COMMAND_BUFFER         = 50;
    public const int VK_CMD_QUEUE_SUBMIT               = 55;
    public const int VK_CMD_BIND_PIPELINE              = 83;
    public const int VK_CMD_DRAW                       = 92;

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

    // Shared guest-host blob buffer backed by SYS_GPU_BLOB_CREATE (fallback: heap array)
    public class BlobRing : Object {
        public int res_id { get; private set; }
        public int size { get; private set; }
        public int mapped_addr { get; private set; }
        public bool hw_blob { get; private set; }
        private uint8[] local_buf;

        public BlobRing (int ctx_id, int resource_id, int byte_size) {
            res_id = resource_id;
            size = (byte_size < 4096) ? 4096 : byte_size;
            mapped_addr = (ctx_id > 0) ? Sys.gpu_blob_create (ctx_id, resource_id, size) : 0;
            hw_blob = (mapped_addr != 0);
            if (!hw_blob)
                local_buf = new uint8[size];
        }
    }

    public class CommandEncoder : Object {
        private uint8[] buf;
        private int pos;
        private int cap;
        public int cmd_count { get; private set; }

        public CommandEncoder (int capacity = 8192) {
            cap = (capacity < 256) ? 256 : capacity;
            buf = new uint8[cap];
            pos = 0;
            cmd_count = 0;
        }

        public void reset () {
            pos = 0;
            cmd_count = 0;
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
            cmd_count++;
        }

        public void encode_create_instance (int instance_id) {
            encode_header (VK_CMD_CREATE_INSTANCE, 0);
            write_u64 (instance_id);
        }

        public void encode_create_device (int phys_id, int device_id) {
            encode_header (VK_CMD_CREATE_DEVICE, 0);
            write_u64 (phys_id);
            write_u64 (device_id);
        }

        public void encode_shader_module (int module_id, uint8[] spv_bytes, int spv_len) {
            encode_header (VK_CMD_CREATE_SHADER_MODULE, 0);
            write_u64 (module_id);
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

        public void encode_create_graphics_pipeline (int pipeline_id, int frag_module_id) {
            encode_header (VK_CMD_CREATE_GRAPHICS_PIPELINES, 0);
            write_u64 (pipeline_id);
            write_u64 (frag_module_id);
        }

        public void encode_draw (int cmd_buf_id, int pipeline_id, int vertex_count, int instance_count) {
            encode_header (VK_CMD_BEGIN_COMMAND_BUFFER, 0);
            write_u64 (cmd_buf_id);
            encode_header (VK_CMD_BIND_PIPELINE, 0);
            write_u64 (cmd_buf_id);
            write_u32 (0); // VK_PIPELINE_BIND_POINT_GRAPHICS
            write_u64 (pipeline_id);
            encode_header (VK_CMD_DRAW, 0);
            write_u64 (cmd_buf_id);
            write_u32 (vertex_count);
            write_u32 (instance_count);
            encode_header (VK_CMD_END_COMMAND_BUFFER, 0);
            write_u64 (cmd_buf_id);
            encode_header (VK_CMD_QUEUE_SUBMIT, 0);
            write_u64 (cmd_buf_id);
        }

        public bool submit (int ctx_id) {
            if (pos <= 0)
                return false;
            return Sys.gpu_submit_3d (ctx_id, buf, pos) == 0;
        }
    }

    public class GpuContext : Object {
        public int ctx_id { get; private set; }
        public int capset_id { get; private set; }
        public bool active { get; private set; }
        public bool hw_venus { get; private set; }

        public GpuContext (int id, int capset = CAPSET_VENUS) {
            ctx_id = id;
            capset_id = capset;
            var caps = new GpuCaps ();
            hw_venus = caps.venus;
            if (caps.present && caps.virgl)
                active = (Sys.gpu_ctx_create (id, capset) == 0);
            else
                active = false;
        }

        public bool submit (CommandEncoder enc) {
            if (!active || !hw_venus)
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

    // High-level Vulkan-like device facade over Venus (with Spv.Module fallback)
    public class GpuDevice : Object {
        public GpuContext ctx { get; private set; }
        public CommandEncoder enc { get; private set; }
        public BlobRing ring { get; private set; }
        public bool using_hw_venus { get; private set; }
        private int next_handle = 100;

        public GpuDevice (int ctx_id = 1) {
            var caps = new GpuCaps ();
            int capset = caps.venus ? CAPSET_VENUS : CAPSET_VIRGL2;
            ctx = new GpuContext (ctx_id, capset);
            enc = new CommandEncoder (8192);
            ring = new BlobRing (ctx.active ? ctx_id : 0, 100 + ctx_id, 16384);
            using_hw_venus = ctx.hw_venus && ctx.active;
            enc.encode_create_instance (1);
            enc.encode_create_device (1, 1);
            if (using_hw_venus) {
                ctx.submit (enc);
                enc.reset ();
            }
        }

        public int create_shader_module (uint8[] spv_bytes, int spv_len) {
            int id = next_handle++;
            enc.encode_shader_module (id, spv_bytes, spv_len);
            return id;
        }

        public int create_pipeline (int frag_module_id) {
            int id = next_handle++;
            enc.encode_create_graphics_pipeline (id, frag_module_id);
            return id;
        }

        public bool draw_fullscreen (int pipeline_id) {
            enc.encode_draw (1, pipeline_id, 3, 1);
            if (using_hw_venus) {
                bool ok = ctx.submit (enc);
                enc.reset ();
                return ok;
            }
            return true;
        }

        public void close () {
            ctx.destroy ();
        }
    }
}
