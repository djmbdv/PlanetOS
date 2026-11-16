// Per-pixel SPIR-V fragment shader for the PlanetOS desktop background.
//
// Unlike frag_planet.vala (constant color), this one reads gl_FragCoord, which
// planc exposes as frag_coord_x()/frag_coord_y() and emits as a BuiltIn
// FragCoord input variable. The compositor bakes it once and tiles the result
// behind the windows.

void main () {
    float x = frag_coord_x ();
    float y = frag_coord_y ();
    // horizon gradient: darker at the top, warmer near the bottom
    float hz = y * 0.0016;
    float horizon = hz * hz;
    // radial glow centred on the upper middle of the screen
    float dx = (x - 400.0) * 0.0022;
    float dy = (y - 150.0) * 0.0026;
    float d = dx * dx + dy * dy;
    float glow = 0.30 - d * 0.30;
    float r = 0.05 + horizon * 0.16 + glow * 0.10;
    float g = 0.07 + horizon * 0.20 + glow * 0.30;
    float b = 0.12 + horizon * 0.34 + glow * 0.55;
    frag_color (r, g, b, 1.0);
}
