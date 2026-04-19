// Vanilla MC's first-person held-item rendering: textured 3D mesh with
// per-face Notch shading (top brightest, sides medium, front/back dimmer)
// PLUS depth_test_disabled so the item always draws on top of world
// geometry. Without per-face shading, the voxel-extruded sprite reads as
// flat — every face has identical color and the depth is invisible.
shader_type spatial;
render_mode cull_back, depth_test_disabled, unshaded;

uniform sampler2D item_texture : filter_nearest, source_color;

varying vec3 v_normal;


void vertex() {
	v_normal = NORMAL;
}


void fragment() {
	vec4 c = texture(item_texture, UV);
	if (c.a < 0.5) {
		discard;
	}
	// High-contrast Notch shading. Vanilla MC's curve is subtler (front
	// ~0.65 vs side ~0.85) but at our held-tool render size the eye needs
	// stronger contrast to read the depth. Front/back darkened, sides
	// kept bright — the brightness gap is what makes the extrusion pop.
	float b = 0.7;
	if (v_normal.y > 0.9) {
		b = 1.0;  // top — brightest
	} else if (v_normal.y < -0.9) {
		b = 0.4;  // bottom — darkest
	} else if (abs(v_normal.x) > 0.9) {
		b = 0.95;  // X sides — near full bright (read as "lit edge")
	} else {
		b = 0.55;  // front/back — dimmer than vanilla so sides stand out
	}
	ALBEDO = c.rgb * b;
}
