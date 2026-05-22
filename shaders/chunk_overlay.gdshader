// Variant of chunk.gdshader for first-person held items: same per-face Notch
// shading and atlas sampling, but with depth_test_disabled so the held block
// always draws on top of world geometry (matches vanilla MC's hand pass).
// `unshaded` matches chunk.gdshader — ambient_light_energy is 0 in main.tscn,
// so without it Godot's PBR would gate ALBEDO to black.
shader_type spatial;
render_mode cull_back, depth_test_disabled, unshaded;

uniform sampler2D atlas_texture : filter_nearest, source_color;

// Atlas UV slots + biome tints. Mirror chunk.gdshader's pairs so the
// first-person held grass / leaves block renders the same vivid Alpha
// green as world chunks. See comments on the corresponding uniforms in
// chunk.gdshader for the reverse-engineering math behind the values.
// LINEAR-space (G > 1.0 is intentional HDR multiplier).
uniform vec4 grass_top_uv = vec4(0.0);
uniform vec3 grass_tint = vec3(0.52, 1.38, 0.19);
uniform vec4 leaves_uv = vec4(0.0);
uniform vec3 leaves_tint = vec3(0.16, 1.57, 0.10);

varying vec3 v_normal;


void vertex() {
	v_normal = NORMAL;
}


void fragment() {
	vec4 c = texture(atlas_texture, UV);
	if (c.a < 0.5) {
		discard;
	}
	float b = 0.7;
	if (v_normal.y > 0.9) {
		b = 1.0;
	} else if (v_normal.y < -0.9) {
		b = 0.45;
	} else if (abs(v_normal.x) > 0.9) {
		b = 0.85;
	} else {
		b = 0.65;
	}
	vec3 albedo_rgb = c.rgb;
	if (UV.x >= grass_top_uv.x && UV.x < grass_top_uv.x + grass_top_uv.z
			&& UV.y >= grass_top_uv.y && UV.y < grass_top_uv.y + grass_top_uv.w) {
		albedo_rgb *= grass_tint;
	}
	if (UV.x >= leaves_uv.x && UV.x < leaves_uv.x + leaves_uv.z
			&& UV.y >= leaves_uv.y && UV.y < leaves_uv.y + leaves_uv.w) {
		albedo_rgb *= leaves_tint;
	}
	ALBEDO = albedo_rgb * b;
}
