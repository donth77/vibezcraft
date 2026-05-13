shader_type spatial;
// `unshaded` skips Godot's PBR pipeline so ALBEDO writes directly to the
// framebuffer. Vanilla Alpha bakes ALL illumination into per-vertex color
// (sky + block light, run through the brightness LUT) and writes that with
// GL_LIGHTING disabled — there's no environmental ambient or sun term on
// terrain. This shader does the same: the LUT + Notch face shade below
// produce the final color, no Godot lift on top. Without `unshaded`, an
// `ambient_light_energy = 0` Environment would gate every face to black
// (ALBEDO × 0 = 0); with `unshaded`, caves drop to the proper Alpha 5% floor.
render_mode cull_back, unshaded;

uniform sampler2D atlas_texture : filter_nearest, source_color;

// Sky-light multiplier driven by WorldTime.sky_factor() (0.05 midnight,
// 1.0 noon). Applied to the per-vertex sky_light value packed in COLOR.r.
// Default 1.0 keeps the shader functional when no driver is attached
// (tests, editor preview).
uniform float sky_factor : hint_range(0.0, 1.0) = 1.0;

// Debug visualization, cycled at runtime via F8 (see debug_stats.gd).
//   0 = normal (Alpha lighting model)
//   1 = sky_light heatmap (red→green = 0→15, what the mesher packed)
//   2 = block_light heatmap
//   3 = combined-light heatmap (after sky_factor + max-of-both)
// Default 0 keeps shipping behavior identical when no key is pressed.
uniform int debug_view = 0;

// Atlas UV slot for grass_top (x, y, w, h). Set by BlockAtlas at build()
// so the per-instance biome tint below only modifies grass faces — without
// this, dirt / stone tops would also catch the savanna yellow.
uniform vec4 grass_top_uv = vec4(0.0);

// Per-instance Savanna tint factor (0.0 = no tint, 1.0 = full yellow).
// ChunkNode sets this based on the chunk-center biome. Beta-style mostly-
// per-chunk biome tinting; per-cell precision would need a chunk biome_map
// + mesher changes (deferred).
instance uniform float savanna_tint : hint_range(0.0, 1.0) = 0.0;

varying vec3 v_normal;
varying vec2 v_light;


void vertex() {
	v_normal = NORMAL;
	// COLOR.r = sky_light/15, COLOR.g = block_light/15. Mesher emits these
	// per face; flat across all 4 vertices (Alpha 1.2.6 had no smooth
	// lighting — added Beta 1.6 with the AO mod).
	v_light = COLOR.rg;
}


void fragment() {
	vec4 c = texture(atlas_texture, UV);
	if (c.a < 0.5) {
		discard;
	}
	// Effective per-cell brightness = max(sky * sky_factor, block).
	// Mirrors the slice-1 Chunk.effective_light formula and vanilla's
	// World.j(time) sun-brightness scaler (vendor/alpha-1.2.6-src/cy.java
	// World.h(int, int, int) renderer-side combine).
	float light = max(v_light.x * sky_factor, v_light.y);
	// Vanilla Alpha 1.2.6 brightness LUT (vendor/alpha-1.2.6-src/oz.java:22-28):
	//     float f2 = 0.05;  // floor
	//     float f3 = 1 - i/15;
	//     brightness[i] = (1 - f3) / (f3*3 + 1) * (1 - f2) + f2;
	// Source uses 0.05 floor — on 2010 LCDs that crushed to perceived black.
	// Modern OLED/IPS panels render the same value as visibly dim; to match
	// the "I literally cannot see anything" cave feel that vanilla had on
	// contemporary hardware, we use 0.0 here. At light=0 (deep cave, no
	// torch) faces render pure black; one cell away from a torch (light=14)
	// the LUT still hits ~78%, so torches are strong sources and the
	// non-linear roll-off in vanilla's curve is preserved for steps 1..15.
	float f2 = 0.0;
	float f3 = 1.0 - light;
	float lit = (1.0 - f3) / (f3 * 3.0 + 1.0) * (1.0 - f2) + f2;
	// Per-face Notch shading. Vanilla constants (vendor/alpha-1.2.6-src/bk.java:819-822):
	//   f6 = 1.0  (top)      f5 = 0.5  (bottom)
	//   f7 = 0.8  (east/west, X-axis)
	//   f8 = 0.6  (north/south, Z-axis)
	// Multiplicative with `light` so a fully-dark cell stays dark regardless
	// of face direction (vanilla bakes both into vertex color the same way).
	float b = 0.6;
	if (v_normal.y > 0.9) {
		b = 1.0;
	} else if (v_normal.y < -0.9) {
		b = 0.5;
	} else if (abs(v_normal.x) > 0.9) {
		b = 0.8;
	} else {
		b = 0.6;
	}
	vec3 albedo_rgb = c.rgb;
	// Savanna biome tint. Gate on UV being inside the grass_top slot so
	// only grass-top faces in savanna chunks get the yellow shift; dirt /
	// stone tops in the same chunk render normally. Vanilla Beta savanna
	// grass color (BiomeBase.l() default ~ #BFB755 → ~vec3(0.75, 0.72, 0.33)).
	if (savanna_tint > 0.0
			&& UV.x >= grass_top_uv.x && UV.x < grass_top_uv.x + grass_top_uv.z
			&& UV.y >= grass_top_uv.y && UV.y < grass_top_uv.y + grass_top_uv.w) {
		vec3 tint = vec3(1.0, 0.95, 0.55);
		albedo_rgb = mix(albedo_rgb, albedo_rgb * tint, savanna_tint);
	}
	vec3 normal_color = albedo_rgb * b * lit;
	// Heatmap: 0 → red, 15 → green, linear lerp in between. Lets us
	// SEE the exact per-face value the mesher packed without having
	// to chase it through the lighting LUT or face shade. Faces with
	// the wrong sky_light show up as red even when their normal would
	// suggest they should be lit.
	vec3 heat = vec3(1.0 - v_light.x, v_light.x, 0.0);
	if (debug_view == 2) {
		heat = vec3(1.0 - v_light.y, v_light.y, 0.0);
	} else if (debug_view == 3) {
		heat = vec3(1.0 - light, light, 0.0);
	}
	ALBEDO = (debug_view == 0) ? normal_color : heat;
}
