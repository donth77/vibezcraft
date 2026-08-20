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
	# nq.java:72 — Alpha obsidian is hardness 10, so bare hands take
	# 10 × 5 = 50 s. The old "> 100" expectation encoded the later-version
	# hardness-50 buff (250 s), which had drifted in.
	assert_almost_eq(
		Blocks.break_time_bare_hand(Blocks.OBSIDIAN),
		50.0,
		0.01,
		"obsidian: 50 s bare-handed in Alpha"
	)


func test_drops_alpha_faithful() -> void:
	assert_eq(Blocks.drops(Blocks.STONE), Blocks.COBBLESTONE, "stone → cobblestone")
	assert_eq(Blocks.drops(Blocks.GRASS), Blocks.DIRT, "grass → dirt")
	assert_eq(Blocks.drops(Blocks.LEAVES), Blocks.AIR, "leaves → no drop (no saplings yet)")
	assert_eq(Blocks.drops(Blocks.BEDROCK), Blocks.AIR, "bedrock → no drop")
	assert_eq(Blocks.drops(Blocks.DIRT), Blocks.DIRT, "dirt → dirt")
	assert_eq(Blocks.drops(Blocks.SAND), Blocks.SAND, "sand → sand")
	assert_eq(Blocks.drops(Blocks.LOG), Blocks.LOG, "log → log")


# --- Redstone ore (Phase 8 B1a — .claude/redstone-plan.md §1.1/§3.1) ---


func test_redstone_ore_ids_are_reserved_values() -> void:
	# Persisted in chunk bytes — renumbering corrupts saves. Lock them.
	assert_eq(Blocks.REDSTONE_ORE, 88, "redstone ore claims id 88")
	assert_eq(Blocks.GLOWING_REDSTONE_ORE, 89, "glowing variant claims id 89")


func test_redstone_ore_core_properties() -> void:
	for id: int in [Blocks.REDSTONE_ORE, Blocks.GLOWING_REDSTONE_ORE]:
		assert_true(Blocks.is_opaque(id), "ore %d renders as an opaque cube" % id)
		assert_true(Blocks.is_solid_collision(id), "ore %d is solid" % id)
		assert_eq(Blocks.hardness(id), 3.0, "an.java c(3.0f)")
		assert_eq(
			Blocks.explosion_resistance(id),
			Blocks.explosion_resistance(Blocks.DIAMOND_ORE),
			"an.java b(5.0f) — same registration as the other ores"
		)
		assert_eq(
			Blocks.preferred_tool_type(id), Items.TOOL_TYPE_PICKAXE, "stone material → pickaxe"
		)
		assert_eq(Blocks.required_harvest_level(id), 2, "iron+ pickaxe to drop")
		assert_eq(Blocks.mesh_shape(id), Blocks.MESH_SHAPE_CUBE, "plain cube mesh")
	assert_eq(Blocks.name_of(Blocks.REDSTONE_ORE), "redstone_ore")
	assert_eq(Blocks.name_of(Blocks.GLOWING_REDSTONE_ORE), "glowing_redstone_ore")


func test_redstone_ore_light_emission() -> void:
	assert_eq(Blocks.light_emission(Blocks.REDSTONE_ORE), 0, "unlit ore emits nothing")
	assert_eq(
		Blocks.light_emission(Blocks.GLOWING_REDSTONE_ORE),
		9,
		"nq.aO .a(0.625f) → int(15 × 0.625) = 9"
	)


func test_redstone_ore_shares_one_texture_tile() -> void:
	# nq.aN and nq.aO both register texture index 51 — the glow is light
	# emission, not a texture swap.
	for face: String in ["top", "bottom", "side"]:
		assert_eq(Blocks.get_face_texture(Blocks.REDSTONE_ORE, face), "redstone_ore")
		assert_eq(Blocks.get_face_texture(Blocks.GLOWING_REDSTONE_ORE, face), "redstone_ore")


func test_redstone_ore_drop_gating_and_quantity() -> void:
	for id: int in [Blocks.REDSTONE_ORE, Blocks.GLOWING_REDSTONE_ORE]:
		assert_eq(Blocks.drops(id), Items.REDSTONE, "an.java a() → redstone dust for both ids")
		assert_eq(Blocks.drop_with_tool(id, Blocks.AIR), Blocks.AIR, "bare hand → nothing")
		assert_eq(
			Blocks.drop_with_tool(id, Items.STONE_PICKAXE),
			Blocks.AIR,
			"stone pick (level 1) below iron gate → nothing"
		)
		assert_eq(
			Blocks.drop_with_tool(id, Items.IRON_PICKAXE),
			Items.REDSTONE,
			"iron pick (level 2) satisfies the gate"
		)
		assert_eq(
			Blocks.drop_with_tool(id, Items.DIAMOND_PICKAXE), Items.REDSTONE, "diamond also fine"
		)
		# an.java a(Random) = 4 + nextInt(2). Sample the quantity roll —
		# every draw must be 4 or 5, and both values must occur.
		var seen := {}
		for _i in range(64):
			var n: int = Blocks.drop_quantity(id)
			assert_between(n, 4, 5, "quantity always 4-5")
			seen[n] = true
		assert_true(seen.has(4) and seen.has(5), "both 4 and 5 occur across 64 rolls")
