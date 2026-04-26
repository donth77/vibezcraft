extends GutTest

# Sanity checks for the ChestStorage autoload — verifies the per-position
# 27-slot inventory model behaves like a tile-entity store.


func before_each() -> void:
	# Clear any state from prior tests by walking known coords. Autoload
	# is process-lifetime so we can't instance fresh; the explicit forget
	# pattern matches what break-block does in production.
	for pos in [Vector3i(0, 0, 0), Vector3i(1, 1, 1), Vector3i(-2, 5, 7)]:
		ChestStorage.forget(pos)


func test_get_or_create_returns_27_empty_stacks() -> void:
	var slots: Array = ChestStorage.get_or_create(Vector3i(0, 0, 0))
	assert_eq(slots.size(), 27, "vanilla TileEntityChest = 27 slots")
	for stack: ItemStack in slots:
		assert_true(stack.is_empty(), "fresh chest has all slots empty")


func test_mutations_persist_across_get_or_create_calls() -> void:
	var pos := Vector3i(1, 1, 1)
	var first: Array = ChestStorage.get_or_create(pos)
	first[0].item_id = Blocks.STONE
	first[0].count = 5
	# Re-fetch — must hand back the SAME array, not a fresh one. Without
	# this, dragging items into a chest would silently revert on every
	# UI repaint.
	var again: Array = ChestStorage.get_or_create(pos)
	assert_eq(again[0].item_id, Blocks.STONE, "position lookup is stable")
	assert_eq(again[0].count, 5)


func test_forget_clears_position() -> void:
	var pos := Vector3i(-2, 5, 7)
	var slots: Array = ChestStorage.get_or_create(pos)
	slots[3].item_id = Blocks.COBBLESTONE
	slots[3].count = 12
	ChestStorage.forget(pos)
	assert_false(ChestStorage.has_chest(pos), "post-forget = no chest at pos")
	# A fresh get_or_create at the same position starts empty — proves
	# forget actually wiped, not just hid.
	var fresh: Array = ChestStorage.get_or_create(pos)
	assert_true(fresh[3].is_empty(), "post-forget get_or_create is fresh")


func test_contents_snapshot_skips_empty_slots() -> void:
	var pos := Vector3i(0, 0, 0)
	var slots: Array = ChestStorage.get_or_create(pos)
	slots[0].item_id = Blocks.STONE
	slots[0].count = 3
	slots[15].item_id = Items.COAL
	slots[15].count = 7
	# slot 1, 2, ..., 14, 16, ..., 26 stay empty.
	var snap: Array = ChestStorage.contents_snapshot(pos)
	assert_eq(snap.size(), 2, "snapshot only contains non-empty stacks")
	# Snapshot is a duplicate — mutating it must not touch live state.
	snap[0].count = 999
	assert_eq(slots[0].count, 3, "snapshot is independent of live storage")


func test_distinct_positions_have_independent_inventories() -> void:
	var a := Vector3i(0, 0, 0)
	var b := Vector3i(1, 1, 1)
	ChestStorage.get_or_create(a)[0].item_id = Blocks.STONE
	ChestStorage.get_or_create(b)[0].item_id = Blocks.PLANKS
	assert_eq(ChestStorage.get_or_create(a)[0].item_id, Blocks.STONE)
	assert_eq(ChestStorage.get_or_create(b)[0].item_id, Blocks.PLANKS)
