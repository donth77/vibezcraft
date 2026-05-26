shader_type spatial;
// Translucent, no back-face cull — the player swims inside water so both
// sides of each face need to draw. depth_draw_opaque keeps water from
// sorting over other translucent effects in the future (sun flares, etc).
render_mode cull_disabled, blend_mix, depth_draw_opaque;

// Alpha's water was synthesised at runtime by TextureWaterFX (oe.java in
// the CFR-decompiled source — client-side; not in Bukkit/mc-dev which is
// server-only). It ran a cellular automaton on a 16×16 buffer and packed
// the result into the 16-frame animated tile in terrain.png. We port
// that filter as `WaterFXNative` (src/water_fx_native.cpp) and feed it
// in as `water_fx_tex`. If the GDExtension isn't built or the autoload
// hasn't pushed the texture yet, we fall back to a 2-octave hash-noise
// ripple that approximates the same look at zero CPU cost.

uniform sampler2D water_fx_tex : filter_nearest, repeat_enable;
// 1.0 if the WaterFX driver has pushed a real texture, 0.0 otherwise.
// Set automatically via texture_query() at fragment time — the hash
// fallback path activates when no real texture is bound.
uniform vec3 deep_color : source_color = vec3(0.05, 0.18, 0.42);
uniform vec3 shallow_color : source_color = vec3(0.20, 0.48, 0.80);
// Vanilla nq.A BlockFluid renders water at vertex alpha 0.7 with
// per-vertex light modulating the color. With lighting now wired into
// the shader (caves / night darken water like every other block), we
// can drop alpha back near vanilla — 0.7 reads correctly without the
// "almost transparent at night" issue the old constant-bright version
// had. Tunable via the editor inspector.
uniform float alpha_strength : hint_range(0.0, 1.0) = 0.7;
uniform float scroll_speed : hint_range(0.0, 2.0) = 0.12;
// Day/night driver pushes this every frame (day_night_driver.gd).
// Range 0.10 (midnight) .. 1.0 (noon). Multiplied with per-vertex
// sky_light to produce effective brightness; same convention as
// chunk.gdshader.
uniform float sky_factor = 1.0;

varying vec3 v_normal;
varying float v_sky;
varying float v_block;
// Cell-wide horizontal flow vector, decoded from COLOR.ba in the vertex
// stage. Range -1..1 (0,0) for static sources / fully-symmetric cells.
// Used in fragment to scroll the ripple noise along the water's
// spreading direction — vanilla Alpha streams visibly drift toward
// lower-pressure neighbors (ld.java:91-155 BlockFluids.getFlowVector).
varying vec2 v_flow;


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
    // Mesher packs sky_light/15 in COLOR.r and block_light/15 in COLOR.g
    // (same convention as chunk.gdshader, see Mesher._emit_fluid_faces).
    v_sky = COLOR.r;
    v_block = COLOR.g;
    // Decode flow X/Z from COLOR.b/.a — encoded as (v*0.5 + 0.5) so the
    // [-1,1] range round-trips through Color's [0,1] clamp without loss.
    v_flow = vec2(COLOR.b, COLOR.a) * 2.0 - 1.0;
}


void fragment() {
    float t = TIME * scroll_speed;
    // Directional UV scroll: top/bottom faces drift along the cell's flow
    // vector (so a stream visibly moves downhill); side faces drift
    // downward in V (water sliding down a waterfall column). Side detection:
    // |normal.y| < 0.5 → side. Magnitude tuned to match the existing
    // built-in ripple time-scroll so the two effects feel cohesive rather
    // than racing.
    vec2 uv = UV;
    if (abs(v_normal.y) > 0.5) {
        uv -= v_flow * t;
    } else {
        uv += vec2(0.0, t);
    }
    // Sample the runtime cellular-automaton texture (16×16 RGBA from
    // WaterFXNative). The R channel carries the squared-intensity field
    // — same channel vanilla uses to drive the deep↔shallow color mix.
    // If the texture hasn't been bound yet (extension not built / autoload
    // not run), Godot returns vec4(0) for a default sampler2D, in which
    // case we fall through to the procedural ripple so the surface still
    // animates rather than going flat.
    // UVs come from the mesher in cell-units (each block face spans
    // 1.0 of UV), so the 16×16 FX texture tiles 1:1 with each block.
    // `repeat_enable` on the sampler handles wrapping across blocks
    // and across the time-scrolled offset.
    vec4 fx = texture(water_fx_tex, uv);
    float r = (fx.a > 0.01) ? fx.r : ripple(uv, t);
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
    // Effective per-vertex brightness — vanilla samples this from the
    // open neighbor cell at mesh time. max() of sun-attenuated sky vs.
    // raw block_light so torches dominate at night. Matches the formula
    // chunk.gdshader uses for opaque blocks.
    float light = max(v_sky * sky_factor, v_block);
    // Water keeps its blue identity at every time-of-day. Opaque blocks
    // can fade to near-black at midnight (chunk.gdshader LUT ≈ 0.076
    // floor); water can't — ALPHA stays at 0.7, so a near-black ALBEDO
    // composites to background-with-a-faint-dark-tint, which reads as
    // "the water turned transparent / black" rather than dim blue.
    // Remap [0..1] → [0.6..1.0]. deep_color = (0.05, 0.18, 0.42) sRGB
    // is already dark in linear space (~0.002, 0.026, 0.155); the
    // floor needs to be high enough that the deepest cave / midnight
    // water still reads as a recognizable blue against the background,
    // not just slightly-tinted darkness. 0.6 keeps night/underground
    // water visibly blue while still dimming dusk and torch-lit caves
    // below daylight.
    light = mix(0.6, 1.0, light);
    ALBEDO = col * b * light;
    ALPHA = alpha_strength;
}
