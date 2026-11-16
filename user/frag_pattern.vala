// Per-pixel SPIR-V fragment shader for the PlanetOS desktop background.
//
// Inputs:   gl_FragCoord  -> frag_coord_x()/frag_coord_y()
// Uniforms: push constant -> uniform_time()/uniform_width()/uniform_height()
//
// The compositor bakes it into 8x8 blocks and, with --animate, re-bakes it with
// a new push-constant time so the glow sweeps across the desktop.

void main () {
    float x = frag_coord_x ();
    float y = frag_coord_y ();
    float t = uniform_time ();

    // horizon gradient: darker at the top, warmer near the bottom
    float hz = y * 0.0016;
    float horizon = hz * hz;

    // glow centred on the upper band, swept horizontally by the time uniform
    float sweep = t * 60.0;
    float dx = (x - 80.0 - sweep) * 0.0022;
    float dy = (y - 150.0) * 0.0026;
    float d = dx * dx + dy * dy;
    float glow = 0.32 - d * 0.32;

    float r = 0.05 + horizon * 0.16 + glow * 0.10;
    float g = 0.07 + horizon * 0.20 + glow * 0.30;
    float b = 0.12 + horizon * 0.34 + glow * 0.55;
    frag_color (r, g, b, 1.0);
}
