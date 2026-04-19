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
