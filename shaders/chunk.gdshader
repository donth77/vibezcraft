shader_type spatial;
// `unshaded` skips Godot's PBR pipeline so ALBEDO writes directly to the
// framebuffer. Vanilla Alpha bakes ALL illumination into per-vertex color
// (sky + block light, run through the brightness LUT) and writes that with
// GL_LIGHTING disabled — there's no environmental ambient or sun term on
// terrain. This shader does the same: the LUT + Notch face shade below
// produce the final color, no Godot lift on top. Without `unshaded`, an
// `ambient_light_energy = 0` Environment would gate every face to black
// (ALBEDO × 0 = 0); with `unshaded`, caves drop to the proper Alpha 5% floor.
//
// World-terrain variant: `cull_back` is correct because the camera never
// ends up inside a solid chunk cell (player collides with terrain). Entity
// cubes (falling blocks, dropped items, TP-held block) use the cull_disabled
// sibling at shaders/chunk_entity.gdshader — see that file for why.
render_mode cull_back, unshaded;

#include "res://shaders/chunk_common.gdshaderinc"
