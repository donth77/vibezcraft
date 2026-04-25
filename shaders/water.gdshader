shader_type spatial;
// Translucent, no back-face cull — the player swims inside water so both
// sides of each face need to draw. depth_draw_opaque keeps water from
// sorting over other translucent effects in the future (sun flares, etc).
render_mode cull_disabled, blend_mix, depth_draw_opaque;

// Alpha's water was synthesised at runtime by TextureWaterFX (client-side;
// not in Bukkit/mc-dev which is server-only). It ran cellular automata on
// a 16×16 buffer and packed the result into the 16-frame animated slot in
// terrain.png. We emulate that look procedurally: two scales of hash noise
// scrolled along orthogonal axes produces the same shimmering ripple at a
// fraction of the cost.

uniform vec3 deep_color : source_color = vec3(0.05, 0.18, 0.42);
uniform vec3 shallow_color : source_color = vec3(0.20, 0.48, 0.80);
// Vanilla nq.A BlockFluid registers water at vertex alpha ~0.72; we bump
// to 0.85 so water reads as a solid liquid surface even at night when
// the surrounding terrain dims to ~25% sky_factor and the contrast
// between water and shoreline collapses. Slight deviation from vanilla
// in exchange for water staying visibly water at any time of day.
uniform float alpha_strength : hint_range(0.0, 1.0) = 0.85;
uniform float scroll_speed : hint_range(0.0, 2.0) = 0.12;

varying vec3 v_normal;


float hash12(vec2 p) {
    // Cheap 2D→1D hash. Avalanche is fine for a shimmering surface — we
    // don't need cryptographic distribution.
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}


// Two layers of hash noise at different spatial frequencies, each scrolled
// along a distinct diagonal. The mix gives the "interference pattern" that
// reads as moving water. Stepped with floor() so the output stays pixelated
// like Alpha's 16×16 per-frame pattern, rather than smoothly interpolated.
float ripple(vec2 p, float t) {
    float n1 = hash12(floor((p + vec2(t, t * 0.73)) * 6.0));
    float n2 = hash12(floor((p * 1.83 + vec2(-t * 0.5, t * 0.9)) * 11.0));
    return 0.60 * n1 + 0.40 * n2;
}


void vertex() {
    v_normal = NORMAL;
}


void fragment() {
    float t = TIME * scroll_speed;
    float r = ripple(UV, t);
    vec3 col = mix(deep_color, shallow_color, r);
    // Notch-style face shading, toned down so sides don't go near-black —
    // underwater is already dim enough with translucent alpha.
    float b = 0.85;
    if (v_normal.y > 0.9) {
        b = 1.0;
    } else if (v_normal.y < -0.9) {
        b = 0.60;
    } else if (abs(v_normal.x) > 0.9) {
        b = 0.90;
    } else {
        b = 0.80;
    }
    ALBEDO = col * b;
    ALPHA = alpha_strength;
}
