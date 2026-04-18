shader_type spatial;
render_mode cull_back;

uniform sampler2D atlas_texture : filter_nearest, source_color;


void fragment() {
	vec4 c = texture(atlas_texture, UV);
	ALBEDO = c.rgb;
	if (c.a < 0.5) {
		discard;
	}
}
