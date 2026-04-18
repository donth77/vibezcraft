shader_type spatial;
render_mode cull_back, depth_draw_never, unshaded, blend_mix;

// Vertical strip atlas: 6 stages stacked top-to-bottom, each cell SIZE × SIZE.
// Stage 0 at top, stage 5 at bottom.
uniform sampler2D crack_atlas : source_color, filter_nearest;
uniform int stage = 0;  // 0..5
uniform int total_stages = 6;


void fragment() {
	if (stage < 0) {
		discard;
	}
	vec2 atlas_uv = vec2(UV.x, (UV.y + float(stage)) / float(total_stages));
	vec4 c = texture(crack_atlas, atlas_uv);
	if (c.a < 0.05) {
		discard;
	}
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
