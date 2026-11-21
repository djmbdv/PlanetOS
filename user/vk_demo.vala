// Vulkan (Venus) + GSK Scene Graph demo for PlanetOS.
// Usage: exec vk_demo.elf [--once]

using Planet;
using Spv;
using Cairo;
using Gdk;
using Venus;
using Gsk;

int main (string[] args) {
    bool once = false;
    bool probe = false;
    for (int i = 1; i < args.length; i++) {
        if (args[i] == "--once")
            once = true;
        else if (args[i] == "--probe")
            probe = true;
    }

    var caps = new GpuCaps ();
    print (@"gpu: present=$(caps.present ? 1 : 0) virgl=$(caps.virgl ? 1 : 0) blob=$(caps.blob ? 1 : 0) ctx=$(caps.ctx_init ? 1 : 0) venus=$(caps.venus ? 1 : 0) display=$(caps.width)x$(caps.height)\n");

    if (probe) {
        var pr = new ProbeResult ();
        print (@"gpu: probe $(pr.summary ())\n");
        return pr.ok () ? 0 : 1;
    }

    var renderer = new VulkanRenderer (1);
    print (@"vk_demo: gsk_backend=$(renderer.backend_name ()) blob_ring=$(renderer.vk.ring.hw_blob ? 1 : 0) cmds=$(renderer.vk.enc.cmd_count)\n");

    // Load SPIR-V shader compiled by planc --target=spirv
    var mod = Module.load ("frag.spv");
    int mod_id = 0;
    int pipe_id = 0;
    if (mod != null && mod.valid) {
        mod_id = renderer.vk.create_shader_module (mod.raw_bytes (), mod.raw_size ());
        pipe_id = renderer.vk.create_pipeline (mod_id);
        print (@"vk_demo: spv=frag.spv words=$(mod.words) mod_id=$mod_id pipe_id=$pipe_id\n");
    }

    // Build GSK scene graph. The background is painted by the same SPIR-V
    // fragment shader the compositor bakes (Gsk.ShaderNode + Spv.Module);
    // a gradient is kept as the fallback when the module is unavailable.
    var root = new ContainerNode ();
    var pattern = Module.load ("frag_pattern.spv");
    if (pattern.valid) {
        var shader_bg = new ShaderNode (new Rect (0, 0, 800, 600), pattern, 8);
        shader_bg.set_params (1.0, 1.0, 0.0, 0.0);
        shader_bg.bake ();
        print (@"vk_demo: gsk_shader=frag_pattern.spv ok=1 blocks=$(shader_bg.baked_blocks ())\n");
        root.append (shader_bg);
    } else {
        var bg = new LinearGradientNode (new Rect (0, 0, 800, 600), false);
        bg.add_stop (0.0, 0.04, 0.06, 0.12, 1.0);
        bg.add_stop (1.0, 0.10, 0.14, 0.26, 1.0);
        print ("vk_demo: gsk_shader=frag_pattern.spv ok=0\n");
        root.append (bg);
    }

    var card_rr = new RoundedRect (120, 100, 560, 380, 14);
    var card = new RoundedRectNode (card_rr, 0.12, 0.16, 0.25, 0.95);
    card.set_border (2.0, 0.22, 0.74, 0.97, 0.85);
    root.append (new ShadowNode (card, card_rr, 0, 8, 16));

    var hdr = new ColorNode (new Rect (140, 120, 520, 44), 0.18, 0.25, 0.38, 1.0);
    root.append (hdr);
    root.append (new TextNode ("PlanetOS GSK + Venus / SPIR-V", 160, 134, 16.0, 0.95, 0.98, 1.0, 1.0));
    root.append (new TextNode (@"Backend: $(renderer.backend_name ())", 160, 190, 16.0, 0.49, 0.83, 0.99, 1.0));

    var win = Display.open_window (800, 600);
    if (win != null) {
        renderer.render (root, win.surface);
        if (pipe_id > 0)
            renderer.vk.draw_fullscreen (pipe_id);
        win.present ();
        if (!once) {
            while (true) {
                var ev = win.poll_event ();
                if (ev.type == EventType.KEY_PRESS && (ev.keyval == 'q' || ev.keyval == 27))
                    break;
                Sys.yield_cpu ();
            }
        }
        win.close ();
    } else {
        var surf = new ImageSurface (Format.ARGB32, 320, 200);
        renderer.render (root, surf);
    }

    renderer.unrealize ();
    print ("vk_demo: done\n");
    return 0;
}
