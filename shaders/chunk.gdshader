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

// Animated fire strip — vanilla fire_layer_0.png at 16×512 (32 frames of
// 16×16 stacked vertically). When a fragment's UV falls inside the fire
// tile's atlas region (`fire_uv`), we sample from THIS texture instead
// of the atlas, with V offset by TIME × FPS so frames cycle. Single tex
// + single shader branch — avoids a per-chunk material or re-meshing.
uniform sampler2D fire_strip : filter_nearest, source_color;
uniform vec4 fire_uv = vec4(-1.0);  // (x, y, w, h) in atlas space; (-1,-1,-1,-1) = disabled
const float FIRE_FRAMES = 32.0;
const float FIRE_FPS = 24.0;

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

// Same gate for leaves — `leaves.png` ships GRAYSCALE with alpha-tested
// transparency gaps, and the shader applies the canonical Alpha foliage
// green via `leaves_tint` below. BlockAtlas pushes the slot rect at
// build() so dirt / planks fragments aren't caught by the tint.
uniform vec4 leaves_uv = vec4(0.0);

// Per-instance base grass tint. grass_top.png ships GRAYSCALE in the
// pack (matches Mojang's terrain.png), so the renderer is responsible
// for the green.
//
// Default is reverse-engineered from a reference Alpha-style screenshot
// (vivid sunlit plains green, foreground grass avg sRGB ≈ (111, 175, 72),
// brightest sunlit pixels ≈ (120, 184, 78)). Canonical ColorizerGrass
// (#91BD59) renders noticeably darker through grayscale × tint math
// because Mojang painted the foliage texture brighter than that math
// alone produces; the screenshot color is what players actually
// associate with "iconic Alpha green."
//
// Target math (Godot 4 linear-space lighting):
//   grass_top avg pixel = gray 146 sRGB → linear 0.288
//   screenshot target avg = (111, 175, 72) sRGB → linear (0.150, 0.398, 0.054)
//   solve tint × 0.288 = target → linear tint ≈ (0.52, 1.38, 0.19)
//
// G > 1.0 is intentional. HDR-space tint multiplier; the brightest
// grass_top pixels (linear 0.566) × 1.38 = 0.781 linear → sRGB ~228,
// which is the vivid sunlit grass in the screenshot's bright spots.
// 8-bit framebuffer clamps gracefully at sRGB encode time.
// ChunkNode can still override per-chunk via
//   set_instance_shader_parameter("grass_tint", Color8(...).srgb_to_linear())
// once biome variation lands.
instance uniform vec3 grass_tint = vec3(0.52, 1.38, 0.19);

// Per-instance leaves tint. leaves.png ships GRAYSCALE w/ alpha gaps —
// same shader-tinting pattern as grass_top, calibrated against the same
// reference screenshot. Foreground tree canopy avg ≈ sRGB (38, 123, 30)
// = linear (0.020, 0.196, 0.013); our leaves grayscale source avgs 99
// sRGB → linear 0.125. Required tint per channel: target / source.
// Same HDR G > 1.0 trick as grass — vivid sunlit leaves come from
// bright source pixels × big tint, framebuffer encode clamps gracefully.
//   tint_R = 0.020 / 0.125 = 0.16
//   tint_G = 0.196 / 0.125 = 1.57
//   tint_B = 0.013 / 0.125 = 0.10
instance uniform vec3 leaves_tint = vec3(0.16, 1.57, 0.10);

// Per-instance Savanna tint factor (0.0 = no tint, 1.0 = full yellow).
// ChunkNode sets this based on the chunk-center biome. Stacks ON TOP of
// grass_tint above — the base plains green still applies, then savanna
// pulls toward warm yellow. Beta-style mostly-per-chunk biome tinting;
// per-cell precision would need a chunk biome_map + mesher changes
// (deferred).
instance uniform float savanna_tint : hint_range(0.0, 1.0) = 0.0;

// Per-instance entity brightness override. Dropped cube-block items
// reuse this shader (BlockAtlas.entity_material) but have no per-vertex
// sky/block light packed into COLOR — they'd otherwise render fullbright
// regardless of time of day. Vanilla af.java applies the lightmap to
// EntityItem renders too, so we expose a 0..1 LUT-applied brightness
// that the entity script samples each tick via EntityLighting.
// Default -1.0 = "use vertex-color path" (world chunks). Anything >=0
// replaces `lit` below. Costs nothing on chunks since instance uniforms
// are baked per-MeshInstance3D, not per-fragment branch.
instance uniform float entity_brightness = -1.0;

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
	vec4 c;
	// Fire animation — UV check against the fire tile's atlas region.
	// If inside, remap to the fire_strip texture with TIME-based V offset
	// so frames cycle. Outside, sample the atlas as normal.
	if (fire_uv.x >= 0.0
			&& UV.x >= fire_uv.x && UV.x < fire_uv.x + fire_uv.z
			&& UV.y >= fire_uv.y && UV.y < fire_uv.y + fire_uv.w) {
		vec2 local_uv = (UV - fire_uv.xy) / fire_uv.zw;
		float frame = floor(mod(TIME * FIRE_FPS, FIRE_FRAMES));
		vec2 strip_uv = vec2(local_uv.x, (frame + local_uv.y) / FIRE_FRAMES);
		c = texture(fire_strip, strip_uv);
	} else {
		c = texture(atlas_texture, UV);
	}
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
	// Restored vanilla's 0.05 floor so cells with sky=block=0 render at 5%
	// brightness instead of pure black. Earlier 0.0 made under-overhang
	// faces and unlit cave ceilings unreadably dark on modern monitors.
	// One cell away from a torch (light=14) the LUT still hits ~78%, so
	// torches remain strong sources and the non-linear roll-off in
	// vanilla's curve is preserved for steps 1..15.
	float f2 = 0.05;
	float f3 = 1.0 - light;
	float lit = (1.0 - f3) / (f3 * 3.0 + 1.0) * (1.0 - f2) + f2;
	// Entity override: dropped cube items sample EntityLighting per-tick
	// and push a LUT-applied 0..1 value here. The world-chunk path leaves
	// it at -1, so the branch is a no-op for terrain rendering.
	if (entity_brightness >= 0.0) {
		lit = entity_brightness;
	}
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
	// Grass-top biome tint. Applied to every fragment inside the grass_top
	// atlas slot so the grayscale grass tile renders as the canonical Alpha
	// plains green (#91BD59) — same math vanilla used at render time
	// (GL_MODULATE: texture × biome_color), just baked into a single
	// uniform multiply. The savanna shift below (warm yellow) stacks on top
	// of this base tint, so savanna chunks first become plains-green then
	// pull toward yellow.
	bool in_grass_top = (
			UV.x >= grass_top_uv.x && UV.x < grass_top_uv.x + grass_top_uv.z
			&& UV.y >= grass_top_uv.y && UV.y < grass_top_uv.y + grass_top_uv.w);
	if (in_grass_top) {
		albedo_rgb *= grass_tint;
	}
	// Same UV-gate treatment for leaves so dirt / planks / etc. that
	// happen to share neighbor atlas rows aren't accidentally tinted.
	bool in_leaves = (
			UV.x >= leaves_uv.x && UV.x < leaves_uv.x + leaves_uv.z
			&& UV.y >= leaves_uv.y && UV.y < leaves_uv.y + leaves_uv.w);
	if (in_leaves) {
		albedo_rgb *= leaves_tint;
	}
	// Savanna biome tint. Same UV gate so only grass-top faces in savanna
	// chunks get the yellow shift; dirt / stone tops render normally.
	// Vanilla Beta savanna grass color (BiomeBase.l() default ~ #BFB755 →
	// ~vec3(0.75, 0.72, 0.33)).
	if (savanna_tint > 0.0 && in_grass_top) {
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
