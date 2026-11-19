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
            return vk.using_hw_venus ? "venus-vulkan" : "vulkan-fallback-cairo";
        }

        public override void render (RenderNode root, ImageSurface target) {
            if (root == null || target == null || target.buf_addr == 0)
                return;
            if (realized && vk != null && vk.using_hw_venus)
                vk.draw_fullscreen (1);
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
