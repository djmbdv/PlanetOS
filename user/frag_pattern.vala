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
    float h = uniform_height ();
    // Effect parameters: p0 scales the glow, p1 its radius (Gsk.ShaderNode
    // passes them; the compositor relies on the defaults).
    float gain = uniform_p0 ();
    float radius = uniform_p1 ();

    // horizon gradient: darker at the top, warmer near the bottom
    float hz = clamp (y / h, 0.0, 1.0);
    float horizon = hz * hz;

    // glow centred on the upper band, swept horizontally by the time uniform
    float sweep = t * 60.0;
    float dx = (x - 80.0 - sweep) * 0.0022;
    float dy = (y - 150.0) * 0.0026;
    float d = sqrt (dx * dx + dy * dy);
    float glow = clamp (1.0 - d * radius, 0.0, 1.0) * gain;

    float r = mix (0.05, 0.21, horizon) + glow * 0.10;
    float g = mix (0.07, 0.27, horizon) + glow * 0.30;
    float b = mix (0.12, 0.46, horizon) + glow * 0.55;
    frag_color (r, g, b, 1.0);
}
