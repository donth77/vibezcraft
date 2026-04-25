shader_type spatial;
// Opaque: lava hides what's behind it and emits its own light. No alpha
// blend so it sorts into the regular opaque pass. cull_back is correct —
// the player can't safely enter the volume, so we never see a back face
// (damage kicks in before they'd see the inside).
render_mode cull_back, depth_draw_opaque;

// Alpha 1.2.6 animated lava via TextureLavaFX — client-side cellular
// automata on a 16×16 buffer drove 20 frames packed in terrain.png. We
// mirror the look procedurally: two scales of hash noise scrolled on
// orthogonal axes give the shimmering "cooling crust" motion at a
// fraction of the cost, same approach as water.gdshader.
//
// Colors picked to match vanilla's terrain.png lava row after tone-mapping:
// deep = molten orange (hot crack), shallow = lighter yellow-orange crust.

uniform vec3 deep_color : source_color = vec3(0.85, 0.22, 0.02);
uniform vec3 shallow_color : source_color = vec3(0.98, 0.66, 0.10);
uniform float scroll_speed : hint_range(0.0, 1.0) = 0.03;
uniform float emission_strength : hint_range(0.0, 2.0) = 0.9;

varying vec3 v_normal;


float hash12(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}


// Same ripple layering as water but slower (0.03 vs 0.12 scroll) to read
// as viscous molten flow rather than rippling liquid.
float ripple(vec2 p, float t) {
    float n1 = hash12(floor((p + vec2(t, t * 0.73)) * 5.0));
    float n2 = hash12(floor((p * 1.83 + vec2(-t * 0.4, t * 0.7)) * 9.0));
    return 0.60 * n1 + 0.40 * n2;
}


void vertex() {
    v_normal = NORMAL;
}


void fragment() {
    float t = TIME * scroll_speed;
    float r = ripple(UV, t);
    vec3 col = mix(deep_color, shallow_color, r);
    // Notch-style per-face shading, but muted — lava glows from within so
    // sides shouldn't go as dark as solid blocks.
    float b = 0.9;
    if (v_normal.y > 0.9) {
        b = 1.0;
    } else if (v_normal.y < -0.9) {
        b = 0.75;
    } else if (abs(v_normal.x) > 0.9) {
        b = 0.92;
    } else {
        b = 0.88;
    }
    ALBEDO = col * b;
    // Light_emission(LAVA)=15 already lights adjacent blocks via the
    // per-vertex light channel; adding emissive here makes the lava cell
    // itself glow regardless of time of day / cave darkness.
    EMISSION = col * emission_strength;
}
