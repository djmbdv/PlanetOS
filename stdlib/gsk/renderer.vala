// Pure-Vala GSK Renderers (CairoRenderer and Venus VulkanRenderer) for PlanetOS.

using Cairo;
using Venus;

namespace Gsk {

    public abstract class Renderer : Object {
        public abstract string backend_name ();
        public abstract void render (RenderNode root, ImageSurface target);
    }

    public class CairoRenderer : Renderer {
        public override string backend_name () {
            return "cairo";
        }

        public override void render (RenderNode root, ImageSurface target) {
            if (root == null || target == null || target.buf_addr == 0)
                return;
            var cr = new Context (target);
            root.draw_cairo (cr);
        }
    }

    /**
     * GSK VulkanRenderer: encodes scene pass over Venus.Device when CAPSET_VENUS
     * is present on VirtIO-GPU, falling back to CairoRenderer otherwise.
     */
    public class VulkanRenderer : Renderer {
        public GpuDevice vk { get; private set; }
        private CairoRenderer fallback;
        private bool realized = true;
        private Spv.Module? cached_mod = null;
        private int cached_pipe_id = 0;

        public VulkanRenderer (int ctx_id = 1) {
            vk = new GpuDevice (ctx_id);
            fallback = new CairoRenderer ();
        }

        ~VulkanRenderer () {
            unrealize ();
        }

        public override string backend_name () {
            if (!realized || vk == null)
                return "unrealized";
            if (vk.using_hw_venus)
                return "venus-vulkan";
            if (vk.using_hw_virgl)
                return "virgl-3d-cairo";
            return "vulkan-fallback-cairo";
        }

        private void encode_venus_shaders (RenderNode node) {
            if (node is ShaderNode) {
                var sn = (ShaderNode) node;
                if (sn.valid () && sn.shader.raw_size () > 0) {
                    if (cached_mod != sn.shader || cached_pipe_id <= 0) {
                        int mod_id = vk.create_shader_module (sn.shader.raw_bytes (), sn.shader.raw_size ());
                        cached_pipe_id = vk.create_pipeline (mod_id);
                        cached_mod = sn.shader;
                    }
                    vk.draw_fullscreen (cached_pipe_id);
                    vk.ctx.submit (vk.enc);
                    vk.enc.reset ();
                }
                return;
            }
            if (node is ContainerNode) {
                var cn = (ContainerNode) node;
                int n = cn.count ();
                for (int i = 0; i < n; i++) {
                    var ch = cn.get_child (i);
                    if (ch != null)
                        encode_venus_shaders (ch);
                }
                return;
            }
            if (node is ClipNode) {
                var cl = (ClipNode) node;
                if (cl.child != null)
                    encode_venus_shaders (cl.child);
                return;
            }
            if (node is OpacityNode) {
                var op = (OpacityNode) node;
                if (op.child != null)
                    encode_venus_shaders (op.child);
                return;
            }
            if (node is ShadowNode) {
                var sh = (ShadowNode) node;
                if (sh.child != null)
                    encode_venus_shaders (sh.child);
            }
        }

        public override void render (RenderNode root, ImageSurface target) {
            if (root == null || target == null || target.buf_addr == 0)
                return;
            if (realized && vk != null) {
                if (vk.using_hw_venus) {
                    encode_venus_shaders (root);
                } else if (vk.using_hw_virgl && root is ColorNode) {
                    var cn = (ColorNode) root;
                    if (cn.bounds != null && cn.bounds.x <= 0.0 && cn.bounds.y <= 0.0
                        && cn.bounds.w >= (double) target.width && cn.bounds.h >= (double) target.height
                        && vk.virgl_clear_target (target.width, target.height, cn.r, cn.g, cn.b, cn.a, target.buf_addr)) {
                        return;
                    }
                }
            }
            fallback.render (root, target);
        }

        public void unrealize () {
            if (!realized)
                return;
            realized = false;
            if (vk != null)
                vk.close ();
        }
    }
}
