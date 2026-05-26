// World-space variant of held_item.gdshader — used for the third-person
// held tool that lives in the world (parented to the character_model's
// arm). Identical Notch shading; the difference is no depth_test_disabled
// so the world geometry properly occludes the tool when it goes behind
// blocks (player ducks behind a wall etc).
shader_type spatial;
render_mode cull_back, unshaded;

uniform sampler2D item_texture : filter_nearest, source_color;
// Vanilla EntityRenderer.setBrightness — entities are texture ×
// world.getBrightnessForRender(cell). 1.0 = full daylight (default,
// matches the third-person held tool which keeps the player's own
// brightness). Dropped items push a per-frame value from
// EntityLighting.sample_brightness so they dim at night / in caves.
uniform float world_brightness : hint_range(0.0, 1.0) = 1.0;

varying vec3 v_normal;


void vertex() {
	v_normal = NORMAL;
}


void fragment() {
	vec4 c = texture(item_texture, UV);
	if (c.a < 0.5) {
		discard;
	}
	float b = 0.7;
	if (v_normal.y > 0.9) {
		b = 1.0;
	} else if (v_normal.y < -0.9) {
		b = 0.4;
	} else if (abs(v_normal.x) > 0.9) {
		b = 0.95;
	} else {
		b = 0.55;
	}
	ALBEDO = c.rgb * b * world_brightness;
}
