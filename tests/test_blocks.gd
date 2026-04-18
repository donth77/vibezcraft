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


func test_break_time_bare_hand() -> void:
	assert_eq(Blocks.break_time_bare_hand(Blocks.BEDROCK), -1.0, "bedrock unbreakable")
	assert_eq(Blocks.break_time_bare_hand(Blocks.DIRT), 0.75, "dirt fast bare-hand")
	assert_gt(
		Blocks.break_time_bare_hand(Blocks.STONE), 5.0, "stone painfully slow without pickaxe"
	)
	assert_gt(Blocks.break_time_bare_hand(Blocks.OBSIDIAN), 100.0, "obsidian extreme")


func test_drops_alpha_faithful() -> void:
	assert_eq(Blocks.drops(Blocks.STONE), Blocks.COBBLESTONE, "stone → cobblestone")
	assert_eq(Blocks.drops(Blocks.GRASS), Blocks.DIRT, "grass → dirt")
	assert_eq(Blocks.drops(Blocks.LEAVES), Blocks.AIR, "leaves → no drop (no saplings yet)")
	assert_eq(Blocks.drops(Blocks.BEDROCK), Blocks.AIR, "bedrock → no drop")
	assert_eq(Blocks.drops(Blocks.DIRT), Blocks.DIRT, "dirt → dirt")
	assert_eq(Blocks.drops(Blocks.SAND), Blocks.SAND, "sand → sand")
	assert_eq(Blocks.drops(Blocks.LOG), Blocks.LOG, "log → log")
