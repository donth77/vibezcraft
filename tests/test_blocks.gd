extends GutTest


func test_air_is_not_opaque() -> void:
	assert_false(Blocks.is_opaque(Blocks.AIR))


func test_stone_is_opaque() -> void:
	assert_true(Blocks.is_opaque(Blocks.STONE))


func test_name_of() -> void:
	assert_eq(Blocks.name_of(Blocks.GRASS), "grass")
	assert_eq(Blocks.name_of(Blocks.LOG), "log")


func test_grass_has_distinct_per_face_textures() -> void:
	assert_eq(Blocks.get_face_texture(Blocks.GRASS, "top"), "grass_top")
	assert_eq(Blocks.get_face_texture(Blocks.GRASS, "bottom"), "dirt")
	assert_eq(Blocks.get_face_texture(Blocks.GRASS, "side"), "grass_side")


func test_log_uses_end_grain_on_top_and_bottom() -> void:
	assert_eq(Blocks.get_face_texture(Blocks.LOG, "top"), "log_top")
	assert_eq(Blocks.get_face_texture(Blocks.LOG, "bottom"), "log_top")
	assert_eq(Blocks.get_face_texture(Blocks.LOG, "side"), "log_side")


func test_uniform_block_returns_same_for_all_faces() -> void:
	for face: String in ["top", "bottom", "side"]:
		assert_eq(Blocks.get_face_texture(Blocks.STONE, face), "stone")
