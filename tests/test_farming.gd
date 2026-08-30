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


class CropManager:
	extends RefCounted
	var support_id: int = Blocks.FARMLAND
	var crop_meta: int = 0
	var effective_light: int = 15
	var writes: Array = []

	func get_world_block(pos: Vector3i) -> int:
		if pos.y == 63:
			return support_id
		return Blocks.CROPS

	func get_world_block_meta(_pos: Vector3i) -> int:
		return crop_meta

	func get_world_effective_light(_pos: Vector3i) -> int:
		return effective_light

	func set_world_block(pos: Vector3i, id: int, meta: int = 0) -> void:
		writes.append([pos, id, meta])
		crop_meta = meta


func before_each() -> void:
	TickScheduler.clear_all()


func after_each() -> void:
	TickScheduler.clear_all()


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


func test_crop_growth_requires_effective_light_nine() -> void:
	var manager := CropManager.new()
	manager.effective_light = 8
	Blocks._tick_crops(manager, Vector3i(0, 64, 0))
	assert_eq(manager.writes.size(), 0, "dark crop must not advance")
	assert_eq(TickScheduler._pending.size(), 1, "dark crop should retry later")


func test_crop_growth_advances_at_effective_light_nine() -> void:
	var manager := CropManager.new()
	manager.effective_light = 9
	Blocks._tick_crops(manager, Vector3i(0, 64, 0))
	assert_eq(manager.writes, [[Vector3i(0, 64, 0), Blocks.CROPS, 1]])
	assert_eq(TickScheduler._pending.size(), 1)


func test_mushroom_placement_rejects_only_light_above_thirteen() -> void:
	for mushroom_id: int in [Blocks.MUSHROOM_BROWN, Blocks.MUSHROOM_RED]:
		assert_true(Blocks.light_allows_placement(mushroom_id, 13))
		assert_false(Blocks.light_allows_placement(mushroom_id, 14))
	assert_true(Blocks.light_allows_placement(Blocks.SAPLING, 15))
