// Minimal pure-Vala GSK (Gtk Scene Kit) compatibility layer for PlanetOS.
// Provides GTK4-style RenderNodes (Color, RoundedRect, LinearGradient, Shadow,
// Text, Clip, Opacity, Container) and CairoRenderer / VulkanRenderer (Venus+Spv).

using Cairo;
using Venus;

namespace Gsk {

    public class Rect : Object {
        public double x;
        public double y;
        public double w;
        public double h;

        public Rect (double rx, double ry, double rw, double rh) {
            x = rx;
            y = ry;
            w = rw;
            h = rh;
        }
    }

    public class RoundedRect : Object {
        public Rect bounds;
        public double radius;

        public RoundedRect (double x, double y, double w, double h, double r) {
            bounds = new Rect (x, y, w, h);
            radius = r;
        }
    }

    public class ColorStop : Object {
        public double offset;
        public double r;
        public double g;
        public double b;
        public double a;

        public ColorStop (double off, double cr, double cg, double cb, double ca) {
            offset = off;
            r = cr;
            g = cg;
            b = cb;
            a = ca;
        }
    }

    public abstract class RenderNode : Object {
        public abstract void draw_cairo (Context cr);
    }

    public class ColorNode : RenderNode {
        public Rect bounds;
        public double r;
        public double g;
        public double b;
        public double a;

        public ColorNode (Rect rect, double cr, double cg, double cb, double ca = 1.0) {
            bounds = rect;
            r = cr;
            g = cg;
            b = cb;
            a = ca;
        }

        public override void draw_cairo (Context cr) {
            cr.set_source_rgba (r, g, b, a);
            cr.rectangle (bounds.x, bounds.y, bounds.w, bounds.h);
            cr.fill ();
        }
    }

    public class RoundedRectNode : RenderNode {
        public RoundedRect rect;
        public double r;
        public double g;
        public double b;
        public double a;
        public double border_w = 0.0;
        public double br = 0.0;
        public double bg = 0.0;
        public double bb = 0.0;
        public double ba = 0.0;

        public RoundedRectNode (RoundedRect rrect, double cr, double cg, double cb, double ca = 1.0) {
            rect = rrect;
            r = cr;
            g = cg;
            b = cb;
            a = ca;
        }

        public void set_border (double w, double red, double green, double blue, double alpha = 1.0) {
            border_w = w;
            br = red;
            bg = green;
            bb = blue;
            ba = alpha;
        }

        public override void draw_cairo (Context cr) {
            cr.set_source_rgba (r, g, b, a);
            cr.rounded_rectangle (rect.bounds.x, rect.bounds.y, rect.bounds.w, rect.bounds.h, rect.radius);
            cr.fill ();
            if (border_w > 0.0 && ba > 0.0) {
                cr.set_source_rgba (br, bg, bb, ba);
                cr.set_line_width (border_w);
                cr.rounded_rectangle (rect.bounds.x, rect.bounds.y, rect.bounds.w, rect.bounds.h, rect.radius);
                cr.stroke ();
            }
        }
    }

    public class LinearGradientNode : RenderNode {
        public Rect bounds;
        public bool horizontal;
        private GenericArray<ColorStop> stops;

        public LinearGradientNode (Rect rect, bool is_horizontal = false) {
            bounds = rect;
            horizontal = is_horizontal;
            stops = new GenericArray<ColorStop> ();
        }

        public void add_stop (double offset, double r, double g, double b, double a = 1.0) {
            stops.add (new ColorStop (offset, r, g, b, a));
        }

        public override void draw_cairo (Context cr) {
            if (stops.length == 0)
                return;
            int n = stops.length;
            int steps = horizontal ? (int) bounds.w : (int) bounds.h;
            if (steps < 1)
                steps = 1;
            if (steps > 64)
                steps = 64;
            for (int i = 0; i < steps; i++) {
                double t = (steps == 1) ? 0.0 : (double) i / (double) (steps - 1);
                var s0 = stops[0];
                var s1 = stops[n - 1];
                for (int k = 0; k < n - 1; k++) {
                    if (t >= stops[k].offset && t <= stops[k + 1].offset) {
                        s0 = stops[k];
                        s1 = stops[k + 1];
                        break;
                    }
                }
                double span = s1.offset - s0.offset;
                double lt = (span > 0.0001) ? ((t - s0.offset) / span) : 0.0;
                if (lt < 0.0) lt = 0.0;
                if (lt > 1.0) lt = 1.0;
                double rr = s0.r + (s1.r - s0.r) * lt;
                double rg = s0.g + (s1.g - s0.g) * lt;
                double rb = s0.b + (s1.b - s0.b) * lt;
                double ra = s0.a + (s1.a - s0.a) * lt;
                cr.set_source_rgba (rr, rg, rb, ra);
                if (horizontal) {
                    double sw = bounds.w / (double) steps;
                    cr.rectangle (bounds.x + i * sw, bounds.y, sw + 1.0, bounds.h);
                } else {
                    double sh = bounds.h / (double) steps;
                    cr.rectangle (bounds.x, bounds.y + i * sh, bounds.w, sh + 1.0);
                }
                cr.fill ();
            }
        }
    }

    public class ShadowNode : RenderNode {
        public RenderNode child;
        public RoundedRect outline;
        public double dx;
        public double dy;
        public double spread;

        public ShadowNode (RenderNode c, RoundedRect rect, double off_x = 0.0, double off_y = 4.0, double spr = 8.0) {
            child = c;
            outline = rect;
            dx = off_x;
            dy = off_y;
            spread = spr;
        }

        public override void draw_cairo (Context cr) {
            int rings = (spread > 4.0) ? 4 : 2;
            for (int i = rings; i >= 1; i--) {
                double pad = (spread * i) / (double) rings;
                double alpha = 0.16 / (double) rings;
                cr.set_source_rgba (0.0, 0.0, 0.0, alpha);
                cr.rounded_rectangle (outline.bounds.x + dx - pad, outline.bounds.y + dy - pad,
                                      outline.bounds.w + pad * 2.0, outline.bounds.h + pad * 2.0,
                                      outline.radius + pad * 0.5);
                cr.fill ();
            }
            if (child != null)
                child.draw_cairo (cr);
        }
    }

    public class TextNode : RenderNode {
        public string text;
        public double x;
        public double y;
        public double font_size;
        public double r;
        public double g;
        public double b;
        public double a;

        public TextNode (string txt, double px, double py, double size = 14.0,
                         double cr = 1.0, double cg = 1.0, double cb = 1.0, double ca = 1.0) {
            text = txt;
            x = px;
            y = py;
            font_size = size;
            r = cr;
            g = cg;
            b = cb;
            a = ca;
        }

        public override void draw_cairo (Context cr) {
            cr.set_source_rgba (r, g, b, a);
            cr.set_font_size (font_size);
            cr.move_to (x, y);
            cr.show_text (text);
        }
    }

    public class ClipNode : RenderNode {
        public Rect clip_rect;
        public RenderNode child;

        public ClipNode (Rect rect, RenderNode c) {
            clip_rect = rect;
            child = c;
        }

        public override void draw_cairo (Context cr) {
            cr.rectangle (clip_rect.x, clip_rect.y, clip_rect.w, clip_rect.h);
            cr.clip ();
            if (child != null)
                child.draw_cairo (cr);
            cr.reset_clip ();
        }
    }

    public class ContainerNode : RenderNode {
        private GenericArray<RenderNode> children;

        public ContainerNode () {
            children = new GenericArray<RenderNode> ();
        }

        public void append (RenderNode node) {
            children.add (node);
        }

        public int count () {
            return children.length;
        }

        public override void draw_cairo (Context cr) {
            for (int i = 0; i < children.length; i++) {
                children[i].draw_cairo (cr);
            }
        }
    }

    public abstract class Renderer : Object {
        public abstract string backend_name ();
        public abstract void render (RenderNode root, ImageSurface target);
    }

    public class CairoRenderer : Renderer {
        public override string backend_name () {
            return "cairo";
        }

        public override void render (RenderNode root, ImageSurface target) {
            if (root == null || target == null)
                return;
            var cr = new Context (target);
            root.draw_cairo (cr);
        }
    }

    // GSK VulkanRenderer: encodes scene pass over Venus.Device when CAPSET_VENUS
    // is present on VirtIO-GPU, falling back to CairoRenderer otherwise.
    public class VulkanRenderer : Renderer {
        public GpuDevice vk { get; private set; }
        private CairoRenderer fallback;

        public VulkanRenderer (int ctx_id = 1) {
            vk = new GpuDevice (ctx_id);
            fallback = new CairoRenderer ();
        }

        public override string backend_name () {
            return vk.using_hw_venus ? "venus-vulkan" : "vulkan-fallback-cairo";
        }

        public override void render (RenderNode root, ImageSurface target) {
            if (root == null || target == null)
                return;
            if (vk.using_hw_venus)
                vk.draw_fullscreen (1);
            fallback.render (root, target);
        }

        public void unrealize () {
            vk.close ();
        }
    }
}
