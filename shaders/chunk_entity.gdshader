shader_type spatial;
// Entity variant of chunk.gdshader for FallingBlock / DroppedItem / the
// third-person held block. Same atlas sampling, same Notch face shade,
// same brightness LUT — see chunk_common.gdshaderinc.
//
// The ONE difference: cull_disabled instead of cull_back. FallingBlock
// deliberately passes through the player (vanilla EntityFallingBlock
// collides with blocks only, not entities — see falling_block.gd:33-42),
// so the camera ends up INSIDE the cube's 1m volume for several frames as
// gravel falls on the player's head. With cull_back the inside-facing
// half of every face is hidden AND `c.a < 0.5 → discard` skips depth
// writes, so the missing faces read as see-through-to-the-world flickers.
// Disabling cull renders the cube double-sided, which costs ~6 extra
// triangles per entity (free) and removes that artifact for every entity
// using the shared entity_material.
render_mode cull_disabled, unshaded;

// Entities are the only instances allowed to carry the per-instance
// brightness override — see the ENTITY_BRIGHTNESS_INSTANCED block in the
// include for why terrain must declare zero instance uniforms.
#define ENTITY_BRIGHTNESS_INSTANCED
#include "res://shaders/chunk_common.gdshaderinc"
