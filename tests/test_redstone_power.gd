extends GutTest

# Phase 8b — the Alpha power model (.claude/redstone-plan.md §2).
#
# Ports of cy.java:1589-1644. The whole system rests on four queries and
# one conditional (a strong-powered solid cube becomes a source), so
# these tests encode the truth tables directly rather than through
# gameplay. Fake world: no scene tree, no disk.

const ORIGIN := Vector3i(0, 64, 0)


class FakeWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var writes: Array = []

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func set_world_block_state(pos: Vector3i, id: int, meta: int, _notify: bool = true) -> bool:
		var old_id: int = blocks.get(pos, Blocks.AIR)
		var old_meta: int = metas.get(pos, 0)
		if old_id == id and old_meta == (meta & 0xF):
			return false
		blocks[pos] = id
		metas[pos] = meta & 0xF
		writes.append([pos, id, meta & 0xF])
		return true

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta


var _w: FakeWorld


func before_each() -> void:
	_w = FakeWorld.new()


# --- Slot convention (cy.java:1597-1613) ---


func test_slot_offsets_match_the_vanilla_fanout_order() -> void:
	assert_eq(Redstone.SLOT_OFFSETS[Redstone.SLOT_BELOW], Vector3i(0, -1, 0))
	assert_eq(Redstone.SLOT_OFFSETS[Redstone.SLOT_ABOVE], Vector3i(0, 1, 0))
	assert_eq(Redstone.SLOT_OFFSETS[Redstone.SLOT_NORTH], Vector3i(0, 0, -1))
	assert_eq(Redstone.SLOT_OFFSETS[Redstone.SLOT_SOUTH], Vector3i(0, 0, 1))
	assert_eq(Redstone.SLOT_OFFSETS[Redstone.SLOT_WEST], Vector3i(-1, 0, 0))
	assert_eq(Redstone.SLOT_OFFSETS[Redstone.SLOT_EAST], Vector3i(1, 0, 0))


# --- is_normal_cube: what may relay power ---


func test_only_full_opaque_cubes_conduct() -> void:
	_w.put(ORIGIN, Blocks.STONE)
	assert_true(Redstone.is_normal_cube(_w, ORIGIN), "stone conducts")
	_w.put(ORIGIN, Blocks.DIRT)
	assert_true(Redstone.is_normal_cube(_w, ORIGIN), "dirt conducts")
	for id: int in [Blocks.AIR, Blocks.GLASS, Blocks.LEAVES, Blocks.HALF_SLAB, Blocks.TORCH]:
		_w.put(ORIGIN, id)
		assert_false(
			Redstone.is_normal_cube(_w, ORIGIN), "%s must not relay power" % Blocks.name_of(id)
		)


func test_lever_itself_never_conducts() -> void:
	# If the lever were treated as a normal cube it could relay its own
	# power back into itself through the solid-block branch.
	_w.put(ORIGIN, Blocks.LEVER, Redstone.MOUNT_FLOOR | Redstone.POWERED_BIT)
	assert_false(Redstone.is_normal_cube(_w, ORIGIN), "lever is not a conductor")


# --- Lever weak/strong truth table (pl.java:181,185) ---


func test_off_lever_powers_nothing() -> void:
	_w.put(ORIGIN, Blocks.LEVER, Redstone.MOUNT_FLOOR)
	for slot in range(6):
		assert_false(Redstone.provides_weak_power(_w, ORIGIN, slot), "weak slot %d" % slot)
		assert_false(Redstone.provides_strong_power(_w, ORIGIN, slot), "strong slot %d" % slot)


func test_on_lever_weakly_powers_every_slot() -> void:
	_w.put(ORIGIN, Blocks.LEVER, Redstone.MOUNT_FLOOR | Redstone.POWERED_BIT)
	for slot in range(6):
		assert_true(Redstone.provides_weak_power(_w, ORIGIN, slot), "weak slot %d" % slot)


func test_on_lever_strongly_powers_only_its_mount() -> void:
	# Every mount orientation strong-powers exactly one slot: the one the
	# block it is attached to sees it through.
	var cases := {
		Redstone.MOUNT_FLOOR: Redstone.SLOT_ABOVE,
		Redstone.MOUNT_FLOOR_ALT: Redstone.SLOT_ABOVE,
		Redstone.MOUNT_WEST_WALL: Redstone.SLOT_EAST,
		Redstone.MOUNT_EAST_WALL: Redstone.SLOT_WEST,
		Redstone.MOUNT_NORTH_WALL: Redstone.SLOT_SOUTH,
		Redstone.MOUNT_SOUTH_WALL: Redstone.SLOT_NORTH,
	}
	for mount: int in cases:
		_w.put(ORIGIN, Blocks.LEVER, mount | Redstone.POWERED_BIT)
		for slot in range(6):
			var expected: bool = slot == cases[mount]
			assert_eq(
				Redstone.provides_strong_power(_w, ORIGIN, slot),
				expected,
				"mount %d strong-powers slot %d == %s" % [mount, slot, expected]
			)


func test_toggling_the_powered_bit_preserves_orientation() -> void:
	for mount in range(1, 7):
		var on_meta: int = mount | Redstone.POWERED_BIT
		assert_eq(on_meta & 0x7, mount, "orientation survives the powered bit")
		assert_true((on_meta & Redstone.POWERED_BIT) > 0, "powered bit set")


# --- The §2.3 worked examples ---


func test_example_1_lever_on_a_block_powers_that_block() -> void:
	# Lever mounted on the west face of a stone block: the stone becomes
	# a source for everything adjacent to it.
	var stone := ORIGIN
	var lever := ORIGIN + Vector3i(-1, 0, 0)
	_w.put(stone, Blocks.STONE)
	_w.put(lever, Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	assert_true(Redstone.is_block_powered(_w, stone), "stone is strong-powered")
	# A cell on the far side of the stone sees it as a source.
	var far := stone + Vector3i(1, 0, 0)
	assert_true(Redstone.is_block_indirectly_powered(_w, far), "power relays through the block")


func test_example_2_adjacent_cell_gets_weak_power_directly() -> void:
	var lever := ORIGIN
	_w.put(lever, Blocks.LEVER, Redstone.MOUNT_FLOOR | Redstone.POWERED_BIT)
	for offset: Vector3i in Redstone.SLOT_OFFSETS:
		assert_true(
			Redstone.is_block_indirectly_powered(_w, lever + offset),
			"cell at %s reads the lever's weak power" % offset
		)


func test_unpowered_lever_leaves_everything_dark() -> void:
	var stone := ORIGIN
	var lever := ORIGIN + Vector3i(-1, 0, 0)
	_w.put(stone, Blocks.STONE)
	_w.put(lever, Blocks.LEVER, Redstone.MOUNT_EAST_WALL)
	assert_false(Redstone.is_block_powered(_w, stone), "stone stays unpowered")
	assert_false(Redstone.is_block_indirectly_powered(_w, stone + Vector3i(1, 0, 0)), "no relay")


func test_power_does_not_relay_through_a_non_cube() -> void:
	# Same layout as example 1 but with a slab instead of stone: a slab
	# is not a normal cube, so it must not conduct.
	var slab := ORIGIN
	var lever := ORIGIN + Vector3i(-1, 0, 0)
	_w.put(slab, Blocks.HALF_SLAB)
	_w.put(lever, Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	var far := slab + Vector3i(1, 0, 0)
	assert_false(Redstone.is_block_indirectly_powered(_w, far), "slab does not relay")


func test_relay_is_one_block_only() -> void:
	# Alpha has no repeater: a powered solid block energises its
	# neighbours but those neighbours don't chain onward.
	var a := ORIGIN
	var b := ORIGIN + Vector3i(1, 0, 0)
	var c := ORIGIN + Vector3i(2, 0, 0)
	_w.put(a, Blocks.STONE)
	_w.put(b, Blocks.STONE)
	_w.put(c, Blocks.STONE)
	_w.put(
		ORIGIN + Vector3i(-1, 0, 0), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT
	)
	assert_true(Redstone.is_block_powered(_w, a), "first block is strong-powered")
	assert_false(Redstone.is_block_powered(_w, b), "second block is not strong-powered")
	assert_false(Redstone.is_block_indirectly_powered(_w, c), "no chain beyond the relay")


func test_is_power_source_predicate() -> void:
	assert_true(Redstone.is_power_source(Blocks.LEVER), "lever is a source")
	for id: int in [Blocks.STONE, Blocks.AIR, Blocks.TORCH, Blocks.REDSTONE_ORE]:
		assert_false(Redstone.is_power_source(id), "%s is not a source" % Blocks.name_of(id))
