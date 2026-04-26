// Variant of chunk.gdshader for first-person held items: same per-face Notch
// shading and atlas sampling, but with depth_test_disabled so the held block
// always draws on top of world geometry (matches vanilla MC's hand pass).
// `unshaded` matches chunk.gdshader — ambient_light_energy is 0 in main.tscn,
// so without it Godot's PBR would gate ALBEDO to black.
shader_type spatial;
render_mode cull_back, depth_test_disabled, unshaded;

uniform sampler2D atlas_texture : filter_nearest, source_color;

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
	ALBEDO = c.rgb * b;
}
