extends GutTest


func before_each() -> void:
	BlockAtlas.reset()
	BlockAtlas.build()


# Parity check: the fast indexed path must return exactly the same Rect2
# as the old string-keyed path for every block/face combo. This is the
# regression guard for the mesher UV lookup refactor.
func test_uv_rect_for_matches_string_keyed_lookup() -> void:
	var face_kinds := {
		BlockAtlas.FACE_TOP: "top", BlockAtlas.FACE_BOTTOM: "bottom", BlockAtlas.FACE_SIDE: "side"
	}
	# Cover all block IDs defined in Blocks plus a buffer for unknown ids
	# (which must still resolve to the zero Rect2 both ways).
	for block_id in range(32):
		for face_kind: int in face_kinds:
			var face_name: String = face_kinds[face_kind]
			var via_index: Rect2 = BlockAtlas.uv_rect_for(block_id, face_kind)
			var tex_name: String = Blocks.get_face_texture(block_id, face_name)
			var via_string: Rect2 = BlockAtlas.uv_rect(tex_name)
			assert_eq(
				via_index,
				via_string,
				"uv_rect_for(%d, %s) must match uv_rect(%s)" % [block_id, face_name, tex_name]
			)


func test_uv_rect_for_is_nonzero_for_known_blocks() -> void:
	# Stone, grass, dirt etc. should all have non-empty rects on their faces.
	var stone_top: Rect2 = BlockAtlas.uv_rect_for(Blocks.STONE, BlockAtlas.FACE_TOP)
	assert_gt(stone_top.size.x, 0.0, "stone top UV has width")
	var grass_top: Rect2 = BlockAtlas.uv_rect_for(Blocks.GRASS, BlockAtlas.FACE_TOP)
	assert_gt(grass_top.size.x, 0.0, "grass top UV has width")
	# Grass top and side must pull different atlas rects.
	var grass_side: Rect2 = BlockAtlas.uv_rect_for(Blocks.GRASS, BlockAtlas.FACE_SIDE)
	assert_ne(grass_top.position, grass_side.position, "grass top != grass side")


func test_uv_rect_for_returns_zero_rect_for_air() -> void:
	var air_rect: Rect2 = BlockAtlas.uv_rect_for(Blocks.AIR, BlockAtlas.FACE_TOP)
	assert_eq(air_rect, Rect2(0, 0, 0, 0), "AIR has no atlas rect")


func test_reset_clears_face_uvs() -> void:
	BlockAtlas.reset()
	# uv_rect_for should lazy-init on next call.
	var stone_side: Rect2 = BlockAtlas.uv_rect_for(Blocks.STONE, BlockAtlas.FACE_SIDE)
	assert_gt(stone_side.size.x, 0.0, "lazy-rebuild after reset works")
