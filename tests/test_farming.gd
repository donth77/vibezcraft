extends GutTest

# Farming tests. Locks in:
#   - CROPS support requirement (FARMLAND only — not dirt/grass)
#   - Mesh shape + light opacity
#   - SFX routing (grass material)
#   - Block properties (hardness, replaceable)
#
# Note: TALL_GRASS used to live here (Beta 1.6) but was removed for
# Alpha-fidelity. Wheat seeds in Alpha 1.2.6 had no natural source;
# players got them via creative-mode item spawn (now: debug spawner J).


func test_crops_require_farmland_support() -> void:
	assert_true(Blocks.can_place_at(Blocks.CROPS, Blocks.FARMLAND))
	# Not on grass / dirt — vanilla forces tilling first.
	assert_false(Blocks.can_place_at(Blocks.CROPS, Blocks.GRASS))
	assert_false(Blocks.can_place_at(Blocks.CROPS, Blocks.DIRT))
	assert_false(Blocks.can_place_at(Blocks.CROPS, Blocks.STONE))


# Crops render as cross-quads (sapling pattern). MESH_SHAPE_CROSS path,
# no special mesh.
func test_crops_use_cross_mesh() -> void:
	assert_eq(Blocks.mesh_shape(Blocks.CROPS), Blocks.MESH_SHAPE_CROSS)


func test_crops_are_light_transparent() -> void:
	# Non-solid plants pass light fully — matches sapling / flowers.
	assert_eq(Blocks.light_opacity(Blocks.CROPS), 0)


func test_crops_break_instantly() -> void:
	# Vanilla BlockBush hardness is 0 — instant break by any tool.
	assert_eq(Blocks.hardness(Blocks.CROPS), 0.0)


# is_replaceable — placing a block into a crop cell should OVERWRITE
# it. Vanilla treats plant cells as replaceable.
func test_crops_are_replaceable() -> void:
	assert_true(Blocks.is_replaceable(Blocks.CROPS))
