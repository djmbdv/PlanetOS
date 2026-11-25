// Pure-Vala GSK RenderNode hierarchy for PlanetOS.

using Planet;
using Cairo;
using Spv;

namespace Gsk {

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
            if (bounds == null || bounds.is_empty () || a <= 0.0)
                return;
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
            border_w = (w > 0.0) ? w : 0.0;
            br = red;
            bg = green;
            bb = blue;
            ba = alpha;
        }

        public override void draw_cairo (Context cr) {
            if (rect == null || rect.bounds == null || rect.bounds.is_empty ())
                return;
            double rad = rect.clamped_radius ();
            if (a > 0.0) {
                cr.set_source_rgba (r, g, b, a);
                cr.rounded_rectangle (rect.bounds.x, rect.bounds.y, rect.bounds.w, rect.bounds.h, rad);
                cr.fill ();
            }
            if (border_w > 0.0 && ba > 0.0) {
                cr.set_source_rgba (br, bg, bb, ba);
                cr.set_line_width (border_w);
                cr.rounded_rectangle (rect.bounds.x, rect.bounds.y, rect.bounds.w, rect.bounds.h, rad);
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

        /**
         * Adds a color stop, keeping stops sorted by ascending offset.
         */
        public void add_stop (double offset, double r, double g, double b, double a = 1.0) {
            var stop = new ColorStop (offset, r, g, b, a);
            stops.add (stop);
            // Insertion-sort the new stop into place so draw_cairo() can scan linearly.
            int i = stops.length - 1;
            while (i > 0 && stops[i - 1].offset > stop.offset) {
                stops[i] = stops[i - 1];
                i--;
            }
            stops[i] = stop;
        }

        public override void draw_cairo (Context cr) {
            if (bounds == null || bounds.is_empty () || stops.length == 0)
                return;
            int n = stops.length;
            if (n == 1) {
                var s = stops[0];
                if (s.a > 0.0) {
                    cr.set_source_rgba (s.r, s.g, s.b, s.a);
                    cr.rectangle (bounds.x, bounds.y, bounds.w, bounds.h);
                    cr.fill ();
                }
                return;
            }
            int steps = horizontal ? (int) bounds.w : (int) bounds.h;
            if (steps < 1)
                steps = 1;
            if (steps > 64)
                steps = 64;
            for (int i = 0; i < steps; i++) {
                double t = (steps == 1) ? 0.0 : (double) i / (double) (steps - 1);
                var s0 = stops[0];
                var s1 = stops[n - 1];
                if (t <= s0.offset) {
                    s1 = s0;
                } else if (t >= s1.offset) {
                    s0 = s1;
                } else {
                    for (int k = 0; k < n - 1; k++) {
                        if (t >= stops[k].offset && t <= stops[k + 1].offset) {
                            s0 = stops[k];
                            s1 = stops[k + 1];
                            break;
                        }
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
                if (ra <= 0.0)
                    continue;
                cr.set_source_rgba (rr, rg, rb, ra);
                if (horizontal) {
                    double sw = bounds.w / (double) steps;
                    double rx = bounds.x + i * sw;
                    double rw = (i + 1 < steps) ? (sw + 1.0) : (bounds.x + bounds.w - rx);
                    if (rw > 0.0) {
                        cr.rectangle (rx, bounds.y, rw, bounds.h);
                        cr.fill ();
                    }
                } else {
                    double sh = bounds.h / (double) steps;
                    double ry = bounds.y + i * sh;
                    double rh = (i + 1 < steps) ? (sh + 1.0) : (bounds.y + bounds.h - ry);
                    if (rh > 0.0) {
                        cr.rectangle (bounds.x, ry, bounds.w, rh);
                        cr.fill ();
                    }
                }
            }
        }
    }

    // Uses a module compiled by `planc --target=spirv` as the paint source.
    // The module is evaluated with the same CPU reference implementation the
    // compositor uses (Spv.Module), so GSK gets shader effects without a
    // Vulkan driver: the node bakes the fragment stage into `step`x`step`
    // blocks and draws those blocks with Cairo.
    public class ShaderNode : RenderNode {
        public Rect bounds;
        public Module? shader;
        public int step = 8;
        private int[] cells = new int[0];
        private uint8[] rgba_buf = new uint8[0];
        private int cols = 0;
        private int rows = 0;
        private bool baked = false;
        private double utime = 0.0;
        private double pa = 1.0;
        private double pb = 1.0;
        private double pc = 0.0;
        private double pd = 0.0;

        public ShaderNode (Rect rect, Module? m, int block = 8) {
            bounds = rect;
            shader = m;
            step = (block > 0) ? block : 8;
        }

        public bool valid () {
            return shader != null && shader.valid;
        }

        public bool per_pixel () {
            if (shader == null || !shader.valid)
                return false;
            return shader.has_input ();
        }

        public void set_step (int block) {
            int next = (block > 0) ? block : 8;
            if (next != step) {
                step = next;
                baked = false;
            }
        }

        public void set_time (double t) {
            utime = t;
            baked = false;
        }

        public void set_params (double p0, double p1, double p2, double p3) {
            pa = p0;
            pb = p1;
            pc = p2;
            pd = p3;
            baked = false;
        }

        public int baked_blocks () {
            return cols * rows;
        }

        public int color_at_pixel (int x, int y) {
            if (!valid () || bounds == null || bounds.is_empty ())
                return 0;
            if (!shader.has_input ()) {
                shader.set_uniforms (utime, bounds.w, bounds.h);
                shader.set_params (pa, pb, pc, pd);
                shader.pixel (0, 0);
                return (shader.ir () << 16) | (shader.ig () << 8) | shader.ib ();
            }
            if (!baked)
                bake ();
            int st = (step > 0) ? step : 8;
            int bx = (x - (int) bounds.x) / st;
            int by = (y - (int) bounds.y) / st;
            if (bx < 0 || by < 0 || bx >= cols || by >= rows)
                return 0;
            return cells[by * cols + bx] & 0xFFFFFF;
        }

        public void bake () {
            if (bounds == null || bounds.is_empty ())
                return;
            if (shader == null || !shader.valid)
                return;
            int st = (step > 0) ? step : 8;
            cols = ((int) bounds.w + st - 1) / st;
            rows = ((int) bounds.h + st - 1) / st;
            if (cols <= 0 || rows <= 0)
                return;
            int need = cols * rows;
            if (cells.length != need)
                cells = new int[need];
            shader.set_uniforms (utime, bounds.w, bounds.h);
            shader.set_params (pa, pb, pc, pd);
            shader.set_origin (bounds.x, bounds.y);
            for (int by = 0; by < rows; by++) {
                for (int bx = 0; bx < cols; bx++) {
                    int px = (int) bounds.x + bx * st + st / 2;
                    int py = (int) bounds.y + by * st + st / 2;
                    shader.pixel (px, py);
                    cells[by * cols + bx] = (shader.ia () << 24) | (shader.ir () << 16)
                        | (shader.ig () << 8) | shader.ib ();
                }
            }
            baked = true;
        }

        public override void draw_cairo (Context cr) {
            if (bounds == null || bounds.is_empty ())
                return;
            cr.save ();
            cr.rectangle (bounds.x, bounds.y, bounds.w, bounds.h);
            cr.clip ();
            if (shader == null || !shader.valid) {
                // Missing/invalid module: paint the panel background flat
                // instead of leaving whatever was underneath.
                cr.set_source_rgba (0.05, 0.07, 0.12, 1.0);
                cr.rectangle (bounds.x, bounds.y, bounds.w, bounds.h);
                cr.fill ();
                cr.restore ();
                return;
            }
            if (!shader.has_input ()) {
                shader.set_uniforms (utime, bounds.w, bounds.h);
                shader.set_params (pa, pb, pc, pd);
                shader.pixel (0, 0);
                double sa = (double) shader.ia () / 255.0;
                if (sa > 0.0) {
                    cr.set_source_rgba ((double) shader.ir () / 255.0,
                                        (double) shader.ig () / 255.0,
                                        (double) shader.ib () / 255.0, sa);
                    cr.rectangle (bounds.x, bounds.y, bounds.w, bounds.h);
                    cr.fill ();
                }
                cr.restore ();
                return;
            }
            if (!baked)
                bake ();
            int st = (step > 0) ? step : 8;
            if (st == 1 && cols > 0 && rows > 0) {
                int need_bytes = cols * rows * 4;
                if (rgba_buf.length != need_bytes)
                    rgba_buf = new uint8[need_bytes];
                for (int i = 0; i < cols * rows; i++) {
                    int c = cells[i];
                    int off = i * 4;
                    rgba_buf[off + 0] = (uint8) (c & 0xFF);
                    rgba_buf[off + 1] = (uint8) ((c >> 8) & 0xFF);
                    rgba_buf[off + 2] = (uint8) ((c >> 16) & 0xFF);
                    rgba_buf[off + 3] = (uint8) ((c >> 24) & 0xFF);
                }
                cr.draw_rgba (rgba_buf, cols, rows, (int) bounds.x, (int) bounds.y);
                cr.restore ();
                return;
            }
            int cx0 = cr.clip_left ();
            int cy0 = cr.clip_top ();
            int cx1 = cr.clip_right ();
            int cy1 = cr.clip_bottom ();
            int ox = (int) bounds.x;
            int oy = (int) bounds.y;
            int bx0 = (cx0 > ox) ? ((cx0 - ox) / st) : 0;
            int by0 = (cy0 > oy) ? ((cy0 - oy) / st) : 0;
            int bx1 = (cx1 - ox + st - 1) / st;
            int by1 = (cy1 - oy + st - 1) / st;
            if (bx0 < 0) bx0 = 0;
            if (by0 < 0) by0 = 0;
            if (bx1 > cols) bx1 = cols;
            if (by1 > rows) by1 = rows;
            for (int by = by0; by < by1; by++) {
                for (int bx = bx0; bx < bx1; bx++) {
                    int c = cells[by * cols + bx];
                    int a = (c >> 24) & 0xFF;
                    if (a == 0)
                        continue;
                    int r = (c >> 16) & 0xFF;
                    int g = (c >> 8) & 0xFF;
                    int b = c & 0xFF;
                    cr.set_source_rgba ((double) r / 255.0, (double) g / 255.0,
                                        (double) b / 255.0, (double) a / 255.0);
                    cr.rectangle (bounds.x + bx * st, bounds.y + by * st, st, st);
                    cr.fill ();
                }
            }
            cr.restore ();
        }
    }

    public class ShadowNode : RenderNode {
        public RenderNode? child;
        public RoundedRect? outline;
        public double dx;
        public double dy;
        public double spread;

        public ShadowNode (RenderNode? c, RoundedRect? rect, double off_x = 0.0, double off_y = 4.0, double spr = 8.0) {
            child = c;
            outline = rect;
            dx = off_x;
            dy = off_y;
            spread = (spr > 0.0) ? spr : 0.0;
        }

        public override void draw_cairo (Context cr) {
            if (outline != null && outline.bounds != null && !outline.bounds.is_empty () && spread > 0.0) {
                double base_rad = outline.clamped_radius ();
                int rings = (spread > 4.0) ? 4 : 2;
                for (int i = rings; i >= 1; i--) {
                    double pad = (spread * i) / (double) rings;
                    double alpha = 0.16 / (double) rings;
                    cr.set_source_rgba (0.0, 0.0, 0.0, alpha);
                    cr.rounded_rectangle (outline.bounds.x + dx - pad, outline.bounds.y + dy - pad,
                                          outline.bounds.w + pad * 2.0, outline.bounds.h + pad * 2.0,
                                          base_rad + pad * 0.5);
                    cr.fill ();
                }
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
            if (text == null || text.length == 0 || font_size <= 0.0 || a <= 0.0)
                return;
            cr.set_source_rgba (r, g, b, a);
            cr.set_font_size (font_size);
            cr.move_to (x, y);
            cr.show_text (text);
        }
    }

    public class ClipNode : RenderNode {
        public Rect clip_rect;
        public RenderNode? child;

        public ClipNode (Rect rect, RenderNode? c) {
            clip_rect = rect;
            child = c;
        }

        public override void draw_cairo (Context cr) {
            if (clip_rect == null || clip_rect.is_empty () || child == null)
                return;
            cr.save ();
            cr.rectangle (clip_rect.x, clip_rect.y, clip_rect.w, clip_rect.h);
            cr.clip ();
            child.draw_cairo (cr);
            cr.restore ();
        }
    }

    public class OpacityNode : RenderNode {
        public double opacity;
        public RenderNode? child;

        public OpacityNode (RenderNode? c, double op = 1.0) {
            child = c;
            opacity = (op < 0.0) ? 0.0 : ((op > 1.0) ? 1.0 : op);
        }

        public override void draw_cairo (Context cr) {
            if (opacity <= 0.0 || child == null)
                return;
            if (opacity >= 1.0) {
                child.draw_cairo (cr);
                return;
            }
            int x0 = cr.clip_left ();
            int y0 = cr.clip_top ();
            int x1 = cr.clip_right ();
            int y1 = cr.clip_bottom ();
            if (x1 <= x0 || y1 <= y0)
                return;
            var tmp = new ImageSurface (Format.ARGB32, x1, y1);
            if (!tmp.is_valid ()) {
                tmp.destroy ();
                child.draw_cairo (cr);
                return;
            }
            var tcr = new Context (tmp);
            tcr.clear ();
            tcr.rectangle ((double) x0, (double) y0, (double) (x1 - x0), (double) (y1 - y0));
            tcr.clip ();
            child.draw_cairo (tcr);
            int w = x1 - x0;
            int h = y1 - y0;
            var rgba = new uint8[w * h * 4];
            int alpha_scale = (int) (opacity * 255.0 + 0.5);
            if (alpha_scale > 255) alpha_scale = 255;
            for (int py = 0; py < h; py++) {
                int row_addr = tmp.buf_addr + ((y0 + py) * x1 + x0) * 4;
                for (int px = 0; px < w; px++) {
                    int argb = Unsafe.peek32 (row_addr + px * 4);
                    int a = (argb >> 24) & 0xFF;
                    if (a == 0)
                        continue;
                    int sa = (a * alpha_scale + 127) / 255;
                    int off = (py * w + px) * 4;
                    rgba[off + 0] = (uint8) (argb & 0xFF);
                    rgba[off + 1] = (uint8) ((argb >> 8) & 0xFF);
                    rgba[off + 2] = (uint8) ((argb >> 16) & 0xFF);
                    rgba[off + 3] = (uint8) sa;
                }
            }
            cr.draw_rgba (rgba, w, h, x0, y0);
            tmp.destroy ();
        }
    }

    public class ContainerNode : RenderNode {
        private GLib.Node<RenderNode?> tree;

        public ContainerNode () {
            tree = new GLib.Node<RenderNode?> (null);
        }

        public void append (RenderNode? node) {
            if (node != null)
                tree.append (new GLib.Node<RenderNode?> (node));
        }

        public void prepend (RenderNode? node) {
            if (node != null)
                tree.prepend (new GLib.Node<RenderNode?> (node));
        }

        public int count () {
            return (int) tree.n_children ();
        }

        public RenderNode? get_child (int idx) {
            if (idx < 0)
                return null;
            var ch = tree.nth_child ((uint) idx);
            return (ch != null) ? ch.data : null;
        }

        public void clear () {
            var ch = tree.first_child ();
            while (ch != null) {
                var nxt = ch.next;
                ch.unlink ();
                ch = nxt;
            }
        }

        public override void draw_cairo (Context cr) {
            unowned var ch = tree.first_child ();
            while (ch != null) {
                if (ch.data != null)
                    ch.data.draw_cairo (cr);
                ch = ch.next;
            }
        }
    }
}
