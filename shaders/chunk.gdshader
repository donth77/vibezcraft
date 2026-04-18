shader_type spatial;
render_mode cull_back;

uniform sampler2D atlas_texture : filter_nearest, source_color;

varying vec3 v_normal;
varying vec3 v_world_pos;


void vertex() {
	v_normal = NORMAL;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	vec4 c = texture(atlas_texture, UV);
	if (c.a < 0.5) {
		discard;
	}

	// Notch-style face shading
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

	// HARD per-block edge — draws an almost-black 1-pixel-ish line at every
	// integer world boundary on the face plane. Makes every cube visibly
	// distinct even on flat fields of identical blocks.
	vec2 face_uv;
	if (abs(v_normal.y) > 0.9) {
		face_uv = vec2(v_world_pos.x, v_world_pos.z);
	} else if (abs(v_normal.x) > 0.9) {
		face_uv = vec2(v_world_pos.z, v_world_pos.y);
	} else {
		face_uv = vec2(v_world_pos.x, v_world_pos.y);
	}
	vec2 fp = fract(face_uv);
	float edge_dist = min(min(fp.x, 1.0 - fp.x), min(fp.y, 1.0 - fp.y));
	// Hard threshold: 0.04 of the face on every side is darkened to 25% brightness
	float edge_factor = step(0.04, edge_dist);
	float edge_mult = mix(0.25, 1.0, edge_factor);

	ALBEDO = c.rgb * b * edge_mult;
}
