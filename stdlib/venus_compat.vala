// Pure-Vala Venus / VirtIO-GPU 3D userland bridge for PlanetOS.
// Bridges Sys.gpu_* syscalls (VirtIO-GPU CAPSET_VENUS / VIRGL + RESOURCE_CREATE_BLOB)
// with planc --target=spirv modules, with automatic Spv.Module software/SIMD fallback
// when CAPSET_VENUS is not exposed by the host QEMU/virglrenderer build.

using Planet;

namespace Venus {

    [AsmBody(@"
        mov (%rdi), %eax
        ret
    ")]
    private extern int __v_peek32 (int addr);

    [AsmBody(@"
        mov %esi, (%rdi)
        ret
    ")]
    private extern void __v_poke32 (int addr, int val);

    public const int CAPSET_VIRGL  = 1;
    public const int CAPSET_VIRGL2 = 2;
    public const int CAPSET_VENUS  = 4;

    // VirGL2 command opcodes (virgl_protocol.h)
    public const int VIRGL_CCMD_CREATE_OBJECT         = 1;
    public const int VIRGL_CCMD_DESTROY_OBJECT        = 3;
    public const int VIRGL_CCMD_SET_FRAMEBUFFER_STATE = 5;
    public const int VIRGL_CCMD_CLEAR                 = 7;
    public const int VIRGL_OBJECT_SURFACE             = 8;
    public const int VIRGL_FORMAT_B8G8R8A8_UNORM      = 1;
    public const int PIPE_CLEAR_COLOR0                = 4;

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

        public static int f32_bits (double v) {
            if (v == 0.0)
                return 0;
            int sign = 0;
            if (v < 0.0) {
                sign = 1;
                v = -v;
            }
            int exp = 127;
            while (v >= 2.0 && exp < 254) {
                v = v * 0.5;
                exp++;
            }
            while (v < 1.0 && exp > 1) {
                v = v * 2.0;
                exp--;
            }
            if (v < 1.0)
                return 0;
            int mant = (int) ((v - 1.0) * 8388608.0 + 0.5);
            if (mant >= 8388608) {
                mant = 0;
                exp++;
            }
            return (sign << 31) | ((exp & 0xFF) << 23) | (mant & 0x7FFFFF);
        }

        public void virgl_hdr (int cmd, int obj, int len) {
            write_u32 ((cmd & 0xFF) | ((obj & 0xFF) << 8) | ((len & 0xFFFF) << 16));
            cmd_count++;
        }

        public void encode_virgl_create_surface (int handle, int res_id, int format = VIRGL_FORMAT_B8G8R8A8_UNORM) {
            virgl_hdr (VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, 5);
            write_u32 (handle);
            write_u32 (res_id);
            write_u32 (format);
            write_u32 (0); // level / first_element
            write_u32 (0); // first_layer | (last_layer << 16)
        }

        public void encode_virgl_set_framebuffer (int cbuf_handle) {
            virgl_hdr (VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, 3);
            write_u32 (1); // nr_cbufs
            write_u32 (0); // zsbuf_handle
            write_u32 (cbuf_handle);
        }

        public void encode_virgl_clear (double r, double g, double b, double a) {
            virgl_hdr (VIRGL_CCMD_CLEAR, 0, 8);
            write_u32 (PIPE_CLEAR_COLOR0);
            write_u32 (f32_bits (r));
            write_u32 (f32_bits (g));
            write_u32 (f32_bits (b));
            write_u32 (f32_bits (a));
            write_u32 (0); // depth lo
            write_u32 (0); // depth hi
            write_u32 (0); // stencil
        }

        public void encode_virgl_destroy_object (int handle, int obj = VIRGL_OBJECT_SURFACE) {
            virgl_hdr (VIRGL_CCMD_DESTROY_OBJECT, obj, 1);
            write_u32 (handle);
        }

        public bool submit (int ctx_id) {
            if (pos <= 0)
                return false;
            return Sys.gpu_submit_3d (ctx_id, buf, pos) == 0;
        }
    }

    // Phase-3 probe: creates a VirGL2 context, submits a one-dword NOP,
    // creates/attaches/destroys a GUEST blob when the device advertises one,
    // and finally destroys the context. It goes through the same syscalls the
    // compositor will use, so a green probe means the lifetime rules and the
    // wire format agree with the host.
    public class ProbeResult : Object {
        public bool present { get; private set; }
        public bool virgl { get; private set; }
        public bool context { get; private set; }
        public bool submit { get; private set; }
        public bool res3d { get; private set; }
        public bool virgl_draw { get; private set; }
        public bool blob { get; private set; }
        public bool venus_ctx { get; private set; }
        public bool cleanup { get; private set; }

        public ProbeResult () {
            var caps = new GpuCaps ();
            present = caps.present;
            virgl = caps.virgl;
            if (!present || !virgl)
                return;
            cleanup = true;

            int ctx_id = 1;
            if (Sys.gpu_ctx_create (ctx_id, CAPSET_VIRGL2) != 0)
                return;
            context = true;

            var nop = new uint8[4]; // VIRGL_CCMD_NOP: hdr 0, length 0
            if (Sys.gpu_submit_3d (ctx_id, nop, 4) == 0)
                submit = true;

            int res3d_id = 0x101;
            int res3d_bytes = 16 * 16 * 4;
            int res3d_pa = Sys.gpu_3d_create (ctx_id, res3d_id, 16, 16);
            if (res3d_pa != 0) {
                res3d = true;
                var venc = new CommandEncoder (256);
                venc.encode_virgl_create_surface (1, res3d_id);
                venc.encode_virgl_set_framebuffer (1);
                venc.encode_virgl_clear (0.125, 0.25, 0.5, 1.0);
                venc.encode_virgl_destroy_object (1);
                if (venc.submit (ctx_id) && Sys.gpu_3d_readback (ctx_id, res3d_id, 16, 16) == 0) {
                    int px = __v_peek32 (res3d_pa);
                    if ((px & 0xFFFFFF) != 0)
                        virgl_draw = true;
                }
                if (Sys.gpu_resource_destroy (ctx_id, res3d_id, res3d_pa, res3d_bytes) != 0)
                    cleanup = false;
            }

            if (caps.blob) {
                int res_id = 0x100;
                int size = 4096;
                int pa = Sys.gpu_blob_create (ctx_id, res_id, size);
                if (pa != 0) {
                    blob = true;
                    if (Sys.gpu_resource_destroy (ctx_id, res_id, pa, size) != 0)
                        cleanup = false;
                }
            }

            if (caps.venus) {
                int venus_id = 2;
                if (Sys.gpu_ctx_create (venus_id, CAPSET_VENUS) == 0) {
                    venus_ctx = true;
                    if (Sys.gpu_ctx_destroy (venus_id) != 0)
                        cleanup = false;
                }
            }

            if (Sys.gpu_ctx_destroy (ctx_id) != 0)
                cleanup = false;
        }

        public string summary () {
            if (!present)
                return "skipped (no virtio-gpu)";
            if (!virgl)
                return "skipped (no virgl)";
            return @"ctx=$(context ? 1 : 0) submit=$(submit ? 1 : 0) res3d=$(res3d ? 1 : 0) draw=$(virgl_draw ? 1 : 0) blob=$(blob ? 1 : 0) venus=$(venus_ctx ? 1 : 0) cleanup=$(cleanup ? 1 : 0)";
        }

        // A device without VirGL has nothing to probe, so skipping is success.
        public bool ok () {
            if (!present || !virgl)
                return true;
            return context && submit && res3d && cleanup;
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

    // High-level Vulkan-like device facade over Venus (with Spv.Module fallback)
    public class GpuDevice : Object {
        public GpuContext ctx { get; private set; }
        public CommandEncoder enc { get; private set; }
        public BlobRing ring { get; private set; }
        public bool using_hw_venus { get; private set; }
        public bool using_hw_virgl { get; private set; }
        private int next_handle = 100;

        public GpuDevice (int ctx_id = 1) {
            var caps = new GpuCaps ();
            int capset = caps.venus ? CAPSET_VENUS : CAPSET_VIRGL2;
            ctx = new GpuContext (ctx_id, capset);
            enc = new CommandEncoder (8192);
            ring = new BlobRing (0, 100 + ctx_id, 16384);
            using_hw_venus = ctx.hw_venus && ctx.active;
            using_hw_virgl = ctx.active && !using_hw_venus;
            if (using_hw_venus) {
                enc.encode_create_instance (1);
                enc.encode_create_device (1, 1);
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
            return true;
        }

        // Executes a real VirGL2 clear pass on a 3D render target, reads the
        // rendered BGRA pixels back from the host GPU, and optionally copies
        // them to dst_buf_addr.
        public bool virgl_clear_target (int width, int height, double r, double g, double b, double a, int dst_buf_addr = 0) {
            if (!using_hw_virgl || width <= 0 || height <= 0)
                return false;
            int bytes = width * height * 4;
            if (bytes > 256 * 4096)
                return false;
            int res_id = next_handle++;
            int surf_id = next_handle++;
            int pa = Sys.gpu_3d_create (ctx.ctx_id, res_id, width, height);
            if (pa == 0)
                return false;
            enc.reset ();
            enc.encode_virgl_create_surface (surf_id, res_id);
            enc.encode_virgl_set_framebuffer (surf_id);
            enc.encode_virgl_clear (r, g, b, a);
            enc.encode_virgl_destroy_object (surf_id);
            bool ok = ctx.submit (enc) && Sys.gpu_3d_readback (ctx.ctx_id, res_id, width, height) == 0;
            if (ok && dst_buf_addr != 0) {
                int nwords = width * height;
                for (int i = 0; i < nwords; i++)
                    __v_poke32 (dst_buf_addr + i * 4, __v_peek32 (pa + i * 4));
            }
            Sys.gpu_resource_destroy (ctx.ctx_id, res_id, pa, bytes);
            return ok;
        }

        public void close () {
            ctx.destroy ();
        }
    }
}
