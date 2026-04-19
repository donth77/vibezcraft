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
	// Texture's crack pixels are dark grey (~61/255), not black. Force pure
	// black so the cracks read as solid black lines over the block — vanilla
	// look. Use 1−luminance so the darker the source pixel, the more opaque
	// the rendered crack (preserves stage-progression intensity).
	float luminance = (c.r + c.g + c.b) / 3.0;
	ALBEDO = vec3(0.0);
	ALPHA = (1.0 - luminance) * c.a;
}
