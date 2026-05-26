extends GutTest

# Smoke tests for the Alpha-completeness pack: 4 hoe tiers (stone/iron/
# gold/diamond) + snowball item + snow block drops. Each assertion ties
# back to a vanilla `dx.java` data point — if these change, vanilla
# parity is the source of truth.

# Preloaded so the test parses even when the `class_name` registry
# hasn't refreshed (GUT loads test scripts before the editor scan
# populates the global identifier table).
const _SNOWBALL_SCRIPT: GDScript = preload("res://scripts/entities/snowball.gd")


# All 5 new items resolve via name (id_from_name) — recipe JSON +
# external tools rely on these strings.
func test_id_from_name_resolves_new_items() -> void:
	assert_eq(Items.id_from_name("stone_hoe"), Items.STONE_HOE)
	assert_eq(Items.id_from_name("iron_hoe"), Items.IRON_HOE)
	assert_eq(Items.id_from_name("gold_hoe"), Items.GOLD_HOE)
	assert_eq(Items.id_from_name("diamond_hoe"), Items.DIAMOND_HOE)
	assert_eq(Items.id_from_name("snowball"), Items.SNOWBALL)


# Hoe tool data — all 4 new tiers should have TOOL_TYPE_HOE and the
# vanilla durability per tier.
func test_hoes_have_tool_data() -> void:
	assert_true(Items.is_tool_item(Items.STONE_HOE))
	assert_true(Items.is_tool_item(Items.IRON_HOE))
	assert_true(Items.is_tool_item(Items.GOLD_HOE))
	assert_true(Items.is_tool_item(Items.DIAMOND_HOE))
	assert_eq(Items.tool_type(Items.STONE_HOE), Items.TOOL_TYPE_HOE)
	assert_eq(Items.tool_type(Items.IRON_HOE), Items.TOOL_TYPE_HOE)
	assert_eq(Items.tool_type(Items.GOLD_HOE), Items.TOOL_TYPE_HOE)
	assert_eq(Items.tool_type(Items.DIAMOND_HOE), Items.TOOL_TYPE_HOE)
	# Vanilla durability per tier — pinned so a stray edit can't slip.
	assert_eq(Items.tool_durability(Items.STONE_HOE), 131)
	assert_eq(Items.tool_durability(Items.IRON_HOE), 250)
	assert_eq(Items.tool_durability(Items.GOLD_HOE), 32)
	assert_eq(Items.tool_durability(Items.DIAMOND_HOE), 1561)


# Snowball stacks to 16 (vanilla ItemSnowball aX=16, same cap as egg).
func test_snowball_stack_size() -> void:
	assert_eq(Items.max_stack_size(Items.SNOWBALL), 16)


# Snow block drops 4 snowballs (vanilla bo.java::a — was previously
# dropping the block itself as a TODO).
func test_snow_block_drops_4_snowballs() -> void:
	assert_eq(Blocks.drops(Blocks.SNOW_BLOCK), Items.SNOWBALL)
	assert_eq(Blocks.drop_quantity(Blocks.SNOW_BLOCK), 4)


# Snow layer drops 1 snowball (Alpha — modern scales 1-8 with depth).
func test_snow_layer_drops_snowball() -> void:
	assert_eq(Blocks.drops(Blocks.SNOW_LAYER), Items.SNOWBALL)


# SnowballProjectile script + its THROW_SPEED constant (referenced by
# interaction.gd::_try_throw_snowball). Catches typos / missing exports.
func test_snowball_projectile_throw_speed_const() -> void:
	assert_not_null(_SNOWBALL_SCRIPT, "snowball.gd should preload")
	assert_eq(_SNOWBALL_SCRIPT.THROW_SPEED, 22.0)


# Iron hoe recipe — vanilla pattern is [II / _S / _S] in the upper-
# left 2x3 of a 3x3 grid. Verifies the recipe was registered AND that
# the iron_hoe name resolves to the right item id at match time.
func test_iron_hoe_recipe_matches() -> void:
	Recipes.ensure_loaded()
	var grid: Array = _empty_grid(3, 3)
	# Row 0: II_, Row 1: _S_, Row 2: _S_
	grid[0] = Items.IRON_INGOT
	grid[1] = Items.IRON_INGOT
	grid[4] = Items.STICK
	grid[7] = Items.STICK
	var result: Dictionary = Recipes.match_grid(grid, 3, 3)
	assert_eq(result.get("item_id", -1), Items.IRON_HOE)


# Snow block recipe — 4 snowballs in 2x2 (vanilla).
func test_snow_block_recipe_matches() -> void:
	Recipes.ensure_loaded()
	var grid: Array = _empty_grid(2, 2)
	for i in range(4):
		grid[i] = Items.SNOWBALL
	var result: Dictionary = Recipes.match_grid(grid, 2, 2)
	assert_eq(result.get("item_id", -1), Blocks.SNOW_BLOCK)


# Helper — flat-array empty grid matching the test_recipes.gd helper.
func _empty_grid(width: int, height: int) -> Array:
	var g: Array = []
	g.resize(width * height)
	for i in range(width * height):
		g[i] = Blocks.AIR
	return g
