// Vanilla Alpha 1.2.6 crosshair blend, reproduced from `nl.java:62-66`:
//
//     GL11.glEnable(GL_BLEND);
//     GL11.glBlendFunc(GL_ONE_MINUS_DST_COLOR, GL_ONE_MINUS_SRC_COLOR);
//     drawTexturedModalRect(w/2 - 7, h/2 - 7, 0, 0, 16, 16);  // icons.png
//
// Blend math: out = src * (1 - dst) + dst * (1 - src)
// With the white "+" sprite, that collapses to `1 - dst` on sprite pixels
// (inversion → dark grey on bright backgrounds, bright on dark) and to `dst`
// where the sprite is transparent. Godot's CanvasItemMaterial has no way to
// set GL_ONE_MINUS_DST_COLOR, so we sample SCREEN_TEXTURE and evaluate the
// blend in the fragment shader.

shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;

void fragment() {
	vec4 spr = texture(TEXTURE, UV);
	if (spr.a < 0.01) {
		discard;
	}
	vec3 scr = texture(screen_tex, SCREEN_UV).rgb;
	vec3 inv = spr.rgb * (1.0 - scr) + scr * (1.0 - spr.rgb);
	COLOR = vec4(inv, 1.0);
}
