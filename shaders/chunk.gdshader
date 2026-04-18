shader_type spatial;
render_mode cull_back;

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
	ALBEDO = c.rgb * b;
}
