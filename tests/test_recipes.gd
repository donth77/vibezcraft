extends GutTest


func before_each() -> void:
	Recipes.load_from_json("res://data/recipes.json")


func _empty_grid(width: int, height: int) -> Array:
	var grid: Array = []
	for i in range(width * height):
		grid.append(Blocks.AIR)
	return grid


# --- Loading ---


func test_recipes_load_from_json_populates_registry() -> void:
	# At minimum the canonical wood progression should have parsed.
	var grid: Array = [Blocks.LOG]
	var result: Dictionary = Recipes.match_grid(grid, 1, 1)
	assert_eq(result.get("item_id", -1), Blocks.PLANKS)
	assert_eq(result.get("count", 0), 4)


# --- Shaped: 1x1 pattern (planks_from_log) ---


func test_log_in_2x2_produces_planks() -> void:
	var grid: Array = _empty_grid(2, 2)
	grid[0] = Blocks.LOG
	var result: Dictionary = Recipes.match_grid(grid, 2, 2)
	assert_eq(result.get("item_id", -1), Blocks.PLANKS)
	assert_eq(result.get("count", 0), 4)


func test_log_in_any_corner_of_2x2_still_matches() -> void:
	for corner in range(4):
		var grid: Array = _empty_grid(2, 2)
		grid[corner] = Blocks.LOG
		var result: Dictionary = Recipes.match_grid(grid, 2, 2)
		assert_eq(result.get("item_id", -1), Blocks.PLANKS, "corner %d should still match" % corner)


func test_log_alongside_other_item_does_not_match() -> void:
	# A 1x1 pattern must NOT match if the grid has anything else in it.
	var grid: Array = _empty_grid(2, 2)
	grid[0] = Blocks.LOG
	grid[1] = Blocks.STONE
	var result: Dictionary = Recipes.match_grid(grid, 2, 2)
	assert_eq(result.size(), 0, "log + stone in grid should not match planks recipe")


# --- Shaped: 1x2 pattern (sticks_from_planks) ---


func test_two_vertical_planks_produces_sticks() -> void:
	var grid: Array = _empty_grid(2, 2)
	grid[0] = Blocks.PLANKS
	grid[2] = Blocks.PLANKS
	var result: Dictionary = Recipes.match_grid(grid, 2, 2)
	assert_eq(result.get("item_id", -1), Items.STICK)
	assert_eq(result.get("count", 0), 4)


# --- Shaped: 3x3 pattern with internal empties (wooden_pickaxe) ---


func test_wooden_pickaxe_at_top_left_of_3x3() -> void:
	var grid: Array = _empty_grid(3, 3)
	# PPP
	# .S.
	# .S.
	grid[0] = Blocks.PLANKS
	grid[1] = Blocks.PLANKS
	grid[2] = Blocks.PLANKS
	grid[4] = Items.STICK
	grid[7] = Items.STICK
	var result: Dictionary = Recipes.match_grid(grid, 3, 3)
	assert_eq(result.get("item_id", -1), Items.WOODEN_PICKAXE)


func test_wooden_pickaxe_pattern_is_3x3_only_at_one_position() -> void:
	# A full-3x3 pattern should not also match if shifted down by 1 (no room).
	var grid: Array = _empty_grid(3, 3)
	# PPP at row 1 (would need row 3 stick, doesn't exist)
	grid[3] = Blocks.PLANKS
	grid[4] = Blocks.PLANKS
	grid[5] = Blocks.PLANKS
	grid[7] = Items.STICK
	var result: Dictionary = Recipes.match_grid(grid, 3, 3)
	assert_eq(result.size(), 0, "incomplete pickaxe pattern should not match")


func test_wooden_pickaxe_with_wrong_handle_material_rejects() -> void:
	# Pattern matches positions but stick is wrong material → planks instead.
	var grid: Array = _empty_grid(3, 3)
	grid[0] = Blocks.PLANKS
	grid[1] = Blocks.PLANKS
	grid[2] = Blocks.PLANKS
	grid[4] = Blocks.PLANKS  # should be STICK
	grid[7] = Blocks.PLANKS  # should be STICK
	var result: Dictionary = Recipes.match_grid(grid, 3, 3)
	assert_eq(result.size(), 0, "planks-as-handle should not match pickaxe recipe")


# --- Shaped: stone variant uses different pattern key ---


func test_stone_pickaxe_matches_with_cobblestone_head() -> void:
	var grid: Array = _empty_grid(3, 3)
	grid[0] = Blocks.COBBLESTONE
	grid[1] = Blocks.COBBLESTONE
	grid[2] = Blocks.COBBLESTONE
	grid[4] = Items.STICK
	grid[7] = Items.STICK
	var result: Dictionary = Recipes.match_grid(grid, 3, 3)
	assert_eq(result.get("item_id", -1), Items.STONE_PICKAXE)


# --- Empty grid + invariants ---


func test_empty_grid_returns_empty_dict() -> void:
	var result: Dictionary = Recipes.match_grid(_empty_grid(3, 3), 3, 3)
	assert_eq(result.size(), 0)


func test_grid_size_mismatch_returns_empty() -> void:
	# 4 cells passed but width*height = 9 — should reject without crashing.
	var result: Dictionary = Recipes.match_grid([Blocks.LOG], 3, 3)
	assert_eq(result.size(), 0)


# --- Compass + clock (Phase 8 B1b — redstone-plan.md §5) ---
# en.java:61 compass = iron ring + redstone core; en.java:60 clock =
# gold ring + redstone core. Both were already in recipes.json with the
# items; the redstone-ore economy (B1a) is what makes the dust input
# legitimately obtainable, so lock the exact patterns here.


func _ring_grid(ring_id: int, center_id: int) -> Array:
	return [
		Blocks.AIR,
		ring_id,
		Blocks.AIR,
		ring_id,
		center_id,
		ring_id,
		Blocks.AIR,
		ring_id,
		Blocks.AIR,
	]


func test_compass_from_iron_ring_and_redstone_core() -> void:
	var result: Dictionary = Recipes.match_grid(_ring_grid(Items.IRON_INGOT, Items.REDSTONE), 3, 3)
	assert_eq(result.get("item_id", -1), Items.COMPASS, "iron ring + redstone → compass")
	assert_eq(result.get("count", 0), 1, "yields exactly one")


func test_clock_from_gold_ring_and_redstone_core() -> void:
	var result: Dictionary = Recipes.match_grid(_ring_grid(Items.GOLD_INGOT, Items.REDSTONE), 3, 3)
	assert_eq(result.get("item_id", -1), Items.CLOCK, "gold ring + redstone → clock")
	assert_eq(result.get("count", 0), 1, "yields exactly one")


func test_compass_requires_the_redstone_core() -> void:
	var result: Dictionary = Recipes.match_grid(
		_ring_grid(Items.IRON_INGOT, Items.IRON_INGOT), 3, 3
	)
	assert_ne(result.get("item_id", -1), Items.COMPASS, "iron center is not a compass")


func test_ring_metal_selects_the_result() -> void:
	var mixed: Dictionary = Recipes.match_grid(_ring_grid(Items.GOLD_INGOT, Items.REDSTONE), 3, 3)
	assert_ne(mixed.get("item_id", -1), Items.COMPASS, "gold ring never yields a compass")
	var iron: Dictionary = Recipes.match_grid(_ring_grid(Items.IRON_INGOT, Items.REDSTONE), 3, 3)
	assert_ne(iron.get("item_id", -1), Items.CLOCK, "iron ring never yields a clock")


# --- Lever (Phase 8b — en.java:58) ---


func test_lever_from_stick_over_cobblestone() -> void:
	var grid: Array = _empty_grid(2, 2)
	grid[0] = Items.STICK
	grid[2] = Blocks.COBBLESTONE
	var result: Dictionary = Recipes.match_grid(grid, 2, 2)
	assert_eq(result.get("item_id", -1), Blocks.LEVER, "stick over cobblestone → lever")
	assert_eq(result.get("count", 0), 1, "yields one lever")


func test_lever_ingredients_are_not_interchangeable() -> void:
	# Cobblestone over stick is the wrong way up — vanilla shaped recipes
	# are order-sensitive and this must not match.
	var grid: Array = _empty_grid(2, 2)
	grid[0] = Blocks.COBBLESTONE
	grid[2] = Items.STICK
	var result: Dictionary = Recipes.match_grid(grid, 2, 2)
	assert_ne(result.get("item_id", -1), Blocks.LEVER, "inverted pattern rejected")


func test_lever_does_not_collide_with_the_torch_recipe() -> void:
	# Both are two-cell vertical recipes; only the ingredients separate
	# them (coal-over-stick vs stick-over-cobblestone).
	var grid: Array = _empty_grid(2, 2)
	grid[0] = Items.COAL
	grid[2] = Items.STICK
	var result: Dictionary = Recipes.match_grid(grid, 2, 2)
	assert_eq(result.get("item_id", -1), Blocks.TORCH, "still a torch")


func test_lever_name_resolves_for_recipe_json() -> void:
	assert_eq(Items.id_from_name("lever"), Blocks.LEVER, "recipe key resolves to the block id")
