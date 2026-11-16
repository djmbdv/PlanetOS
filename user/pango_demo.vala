// Pango layout layer demo: metrics, wrapping, ellipsizing, alignment, drawing.

using Cairo;
using Pango;
using PangoCairo;

private int pd_checks = 0;
private int pd_fails = 0;

private void check (bool ok, string name) {
    pd_checks = pd_checks + 1;
    if (ok)
        return;
    pd_fails = pd_fails + 1;
    print (@"pango: FAIL $name\n");
}

int main (string[] args) {
    var ctx = new PangoContext ();
    ctx.font_description.size = 16;

    var lay = new Layout (ctx);
    check (lay.scale () == 2, "scale-16");
    check (lay.char_width () == 12, "char-width-16");
    check (lay.line_height () == 14, "line-height-16");

    // empty text still owns one (empty) line, like Pango
    lay.set_text ("");
    check (lay.line_count () == 1 && lay.pixel_width () == 0, "empty-layout");
    check (lay.pixel_height () == 14, "empty-height");

    lay.set_text ("abc");
    check (lay.line_count () == 1, "one-line");
    check (lay.pixel_width () == 36, "text-width");
    check (lay.pixel_height () == 14, "text-height");

    lay.set_text ("abc\ndef");
    check (lay.line_count () == 2, "two-lines");
    check (lay.pixel_height () == 30, "two-line-height");
    check (lay.line_start_of (1) == 4, "second-line-start");

    lay.set_text ("a\nb\nc");
    check (lay.line_count () == 3 && lay.pixel_height () == 46, "three-lines");

    lay.set_text ("a\n");
    check (lay.line_count () == 2 && lay.line_chars_of (1) == 0, "trailing-newline");

    // word wrapping: 60 px / 12 px = 5 chars per line
    lay.set_text ("aaaa bbbb");
    lay.set_width (60);
    check (lay.line_count () == 2, "word-wrap-lines");
    check (lay.line_chars_of (0) == 4 && lay.line_chars_of (1) == 4, "word-wrap-chars");
    check (lay.pixel_width () == 48, "word-wrap-width");

    // hard break when a single word does not fit: 36 px / 12 = 3 chars
    lay.set_width (36);
    lay.set_text ("abcdefghij");
    check (lay.line_count () == 4, "hard-break-lines");
    check (lay.line_chars_of (0) == 3 && lay.line_chars_of (3) == 1, "hard-break-chars");

    // ellipsize keeps one line and reserves room for ".."
    lay.set_width (60);
    lay.set_ellipsize (EllipsizeMode.END);
    lay.set_text ("abcdefgh");
    check (lay.line_count () == 1, "ellipsize-one-line");
    check (lay.line_chars_of (0) == 3 && lay.line_truncated (0), "ellipsize-truncates");
    check (lay.pixel_width () == 60, "ellipsize-width");

    lay.set_ellipsize (EllipsizeMode.NONE);
    lay.set_width (-1);
    lay.set_text ("abcdefgh");
    check (!lay.line_truncated (0) && lay.line_chars_of (0) == 8, "no-ellipsize");

    // alignment offsets inside the layout box
    lay.set_width (60);
    lay.set_ellipsize (EllipsizeMode.END);
    lay.set_text ("abcdefgh");
    lay.set_alignment (Alignment.LEFT);
    check (lay.alignment_offset (3) == 0, "align-left");
    lay.set_alignment (Alignment.CENTER);
    check (lay.alignment_offset (3) == 12, "align-center");
    lay.set_alignment (Alignment.RIGHT);
    check (lay.alignment_offset (3) == 24, "align-right");

    // font descriptions
    var mono = FontDescription.from_string ("mono 24 italic");
    check (mono.family == "mono" && mono.size == 24 && mono.style == Style.ITALIC, "font-from-string");
    check (new Layout (ctx).scale () == 2 && mono.size == 24, "layout-uses-ctx-font");
    var big = FontDescription.from_string ("Sans 8");
    check (big.size == 8, "font-small");
    lay.set_font_description (big);
    lay.set_text ("abc");
    check (lay.scale () == 1 && lay.char_width () == 6, "scale-8");
    var bold = FontDescription.from_string ("bold");
    check (bold.weight == Weight.BOLD, "font-bold");
    check (bold.describe () == "sans 16", "font-describe");

    // spacing affects the block height
    var normal = FontDescription.from_string ("sans 16");
    lay.set_font_description (normal);
    lay.set_text ("a\nb");
    lay.set_spacing (6);
    check (lay.pixel_height () == 34, "spacing-height");
    lay.set_spacing (2);

    // drawing smoke test: the layout paints inside its box and respects the clip
    var surf = new ImageSurface (Format.ARGB32, 200, 100);
    check (surf.buf_addr != 0, "surface-alloc");
    var cr = new Context (surf);
    cr.set_source_rgb (0.0, 0.0, 0.0);
    cr.paint ();
    int before = cr.pixel_at (10, 10);
    lay.set_text ("hello");
    lay.set_width (-1);
    cr.set_source_rgb (1.0, 1.0, 1.0);
    show_layout_at (cr, lay, 10, 10);
    check (cr.pixel_at (10, 10) != before, "layout-draws");

    // clip() must keep the glyphs out of a region
    cr.set_source_rgb (0.0, 0.0, 0.0);
    cr.rectangle (0, 0, 200, 100);
    cr.clip ();
    cr.rectangle (0, 0, 14, 100);
    cr.clip ();
    cr.set_source_rgb (0.0, 1.0, 0.0);
    cr.rectangle (0, 0, 200, 100);
    cr.fill ();
    check (cr.pixel_at (2, 2) == ((255 << 24) | (0 << 16) | (255 << 8) | 0), "clip-fills-inside");
    check (cr.pixel_at (100, 2) == (255 << 24), "clip-skips-outside");
    cr.reset_clip ();

    print (@"pango:summary checks=$pd_checks failures=$pd_fails\n");
    return (pd_fails == 0) ? 0 : 1;
}
