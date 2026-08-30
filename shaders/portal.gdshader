shader_type spatial;

// Nether portal surface — the visual half of x.java + et.java.
// See docs/nether-alpha-1.2.6-implementation-plan.md §7.1.
//
// The 32 animation frames are baked into ONE 16x512 strip texture at boot
// (PortalTexture builds them from Random(100), exactly as et.java does),
// and the frame is picked here from TIME. That is what keeps the plan's
// "one shared material/texture resource" promise while still animating:
// nothing is uploaded per frame, nothing is allocated per portal, and the
// whole effect costs one uniform-free texture fetch.
//
// unshaded because Alpha draws the portal at full brightness regardless
// of the surrounding light level — the block's own light emission (11) is
// what lights the room, not the other way round.

render_mode blend_mix, cull_disabled, unshaded, depth_draw_opaque, shadows_disabled;

// The 32 frames stacked vertically, 16x16 each.
uniform sampler2D frames : source_color, filter_nearest, repeat_disable;
// Vanilla advances one frame per client tick.
uniform float frames_per_second = 20.0;
uniform float frame_count = 32.0;

void fragment() {
	// mod() on the float index rather than an int cast, so the strip keeps
	// looping past the point a 32-bit int would start losing precision on
	// a long-running session.
	float frame = floor(mod(TIME * frames_per_second, frame_count));
	// V runs down the strip: each frame owns 1/32 of it.
	vec2 strip_uv = vec2(UV.x, (frame + fract(UV.y)) / frame_count);
	vec4 texel = texture(frames, strip_uv);
	ALBEDO = texel.rgb;
	ALPHA = texel.a;
}
