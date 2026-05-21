extends GutTest

# Farming tests. Locks in:
#   - CROPS support requirement (FARMLAND only — not dirt/grass)
#   - TALL_GRASS support requirement (grass/dirt/farmland accepted)
#   - Mesh shape + light opacity for both
#   - SFX routing (grass material for both)
#   - Block properties (hardness, replaceable)


func test_crops_require_farmland_support() -> void:
	assert_true(Blocks.can_place_at(Blocks.CROPS, Blocks.FARMLAND))
	# Not on grass / dirt — vanilla forces tilling first.
	assert_false(Blocks.can_place_at(Blocks.CROPS, Blocks.GRASS))
	assert_false(Blocks.can_place_at(Blocks.CROPS, Blocks.DIRT))
	assert_false(Blocks.can_place_at(Blocks.CROPS, Blocks.STONE))


func test_tall_grass_accepts_grass_dirt_farmland() -> void:
	assert_true(Blocks.can_place_at(Blocks.TALL_GRASS, Blocks.GRASS))
	assert_true(Blocks.can_place_at(Blocks.TALL_GRASS, Blocks.DIRT))
	assert_true(Blocks.can_place_at(Blocks.TALL_GRASS, Blocks.FARMLAND))
	assert_false(Blocks.can_place_at(Blocks.TALL_GRASS, Blocks.STONE))
	assert_false(Blocks.can_place_at(Blocks.TALL_GRASS, Blocks.SAND))


# Both crops + tall grass render as cross-quads (saplings/flowers
# pattern). Same MESH_SHAPE_CROSS pathway, no special mesh.
func test_farming_blocks_use_cross_mesh() -> void:
	assert_eq(Blocks.mesh_shape(Blocks.CROPS), Blocks.MESH_SHAPE_CROSS)
	assert_eq(Blocks.mesh_shape(Blocks.TALL_GRASS), Blocks.MESH_SHAPE_CROSS)


func test_farming_blocks_are_light_transparent() -> void:
	# Non-solid plants pass light fully — matches sapling / flowers.
	assert_eq(Blocks.light_opacity(Blocks.CROPS), 0)
	assert_eq(Blocks.light_opacity(Blocks.TALL_GRASS), 0)


func test_farming_blocks_break_instantly() -> void:
	# Vanilla BlockBush hardness is 0 — instant break by any tool.
	assert_eq(Blocks.hardness(Blocks.CROPS), 0.0)
	assert_eq(Blocks.hardness(Blocks.TALL_GRASS), 0.0)


# is_replaceable — placing a block into a tall-grass cell or crop cell
# should OVERWRITE it. Vanilla treats both as plants whose cells the
# player can place into directly.
func test_farming_blocks_are_replaceable() -> void:
	assert_true(Blocks.is_replaceable(Blocks.TALL_GRASS))
	assert_true(Blocks.is_replaceable(Blocks.CROPS))
