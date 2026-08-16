extends GutTest

# The power-source set — vanilla `Block.e()` / `isPowerSource`, and the
# three things that read it.
#
# `is_power_source` looked complete for a long time while missing the
# button and both plates. Nothing failed, because their weak/strong
# OUTPUT was implemented separately and correct: adjacent wire still lit
# up. What broke was everything keyed off the predicate instead —
# `lu.java:295 c()` connectivity, so wire beside a button rendered as an
# unconnected dot AND, being "isolated", fed power to all four
# horizontal neighbours instead of none; plus the changed-neighbour
# guard TNT and rail junctions share, which silently stopped seeing
# button and plate transitions as power events.
#
# Hence a table over every id, and separate coverage of each consumer.

const Y: int = 64
const WIRE := Vector3i(0, Y, 0)

# id → is this block a redstone source? Vanilla class and line for each
# `true` row; everything else inherits `Block.e()` returning false.
const SOURCE_TABLE: Array = [
	[Blocks.LEVER, true],  # pl.java:205
	[Blocks.STONE_BUTTON, true],  # iy.java:206
	[Blocks.STONE_PRESSURE_PLATE, true],  # ap.java:139
	[Blocks.WOODEN_PRESSURE_PLATE, true],  # ap.java:139
	[Blocks.REDSTONE_TORCH, true],  # bo.java
	[Blocks.REDSTONE_TORCH_OFF, true],  # bo.java (both ids)
	[Blocks.REDSTONE_WIRE, true],  # lu.java:282, outside a recomputation
	[Blocks.STONE, false],
	[Blocks.DIRT, false],
	[Blocks.TORCH, false],  # a plain torch is not a redstone source
	[Blocks.REDSTONE_ORE, false],
	[Blocks.GLOWING_REDSTONE_ORE, false],
	[Blocks.TNT, false],
	[Blocks.RAIL, false],
	[Blocks.IRON_DOOR, false],
	[Blocks.AIR, false],
]


class SourceWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func set_world_block_state(pos: Vector3i, id: int, meta: int, _notify: bool = true) -> bool:
		blocks[pos] = id
		metas[pos] = meta & 0xF
		return true

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta


var _w: SourceWorld


func before_each() -> void:
	_w = SourceWorld.new()
	Redstone.reset_state()


# --- The predicate itself ----------------------------------------------


func test_every_block_reports_the_right_source_capability() -> void:
	for row: Array in SOURCE_TABLE:
		assert_eq(
			Redstone.is_power_source(row[0]), row[1], "%s is_power_source" % Blocks.name_of(row[0])
		)


func test_source_capability_ignores_the_switch_position() -> void:
	# `e()` is a property of the CLASS in vanilla — it takes no metadata
	# and cannot consult state. An unpressed button is still a source, so
	# wire connects to it whether or not it is currently on.
	for id: int in [
		Blocks.LEVER,
		Blocks.STONE_BUTTON,
		Blocks.STONE_PRESSURE_PLATE,
		Blocks.WOODEN_PRESSURE_PLATE,
	]:
		assert_true(Redstone.is_power_source(id), "%s off is still a source" % Blocks.name_of(id))


func test_wire_withdraws_from_the_set_only_during_its_own_recomputation() -> void:
	# lu.java:282 returns the recursion guard, which is how a wire avoids
	# reading its own output back as a fresh 15.
	assert_true(Redstone.is_power_source(Blocks.REDSTONE_WIRE), "normally a source")
	Redstone._wire_output_enabled = false
	assert_false(Redstone.is_power_source(Blocks.REDSTONE_WIRE), "not during recomputation")
	Redstone._wire_output_enabled = true


# --- Consumer 1: wire connectivity (lu.java:295) -----------------------


func test_wire_connects_to_every_source_in_every_state() -> void:
	for id: int in [
		Blocks.LEVER,
		Blocks.STONE_BUTTON,
		Blocks.STONE_PRESSURE_PLATE,
		Blocks.WOODEN_PRESSURE_PLATE,
		Blocks.REDSTONE_TORCH,
		Blocks.REDSTONE_TORCH_OFF,
		Blocks.REDSTONE_WIRE,
	]:
		for meta: int in [0, Redstone.POWERED_BIT | 1, 1]:
			before_each()
			var side := WIRE + Vector3i(1, 0, 0)
			_w.put(side, id, meta)
			assert_true(
				Redstone.can_connect_to(_w, side),
				"wire links to %s (meta %d)" % [Blocks.name_of(id), meta]
			)


func test_wire_does_not_connect_to_ordinary_blocks() -> void:
	for id: int in [Blocks.STONE, Blocks.DIRT, Blocks.TORCH, Blocks.REDSTONE_ORE, Blocks.TNT]:
		before_each()
		var side := WIRE + Vector3i(1, 0, 0)
		_w.put(side, id)
		assert_false(Redstone.can_connect_to(_w, side), "no link to %s" % Blocks.name_of(id))


# --- Consumer 2: directional output (lu.java:238-280) ------------------


func _lay_wire_next_to(id: int, meta: int) -> void:
	_w.put(WIRE + Vector3i(0, -1, 0), Blocks.STONE)
	_w.put(WIRE, Blocks.REDSTONE_WIRE, Redstone.WIRE_MAX_POWER)
	_w.put(WIRE + Vector3i(1, 0, 0), id, meta)


func test_wire_beside_a_button_is_not_treated_as_isolated() -> void:
	# The consequence that would have shipped: an unconnected wire powers
	# ALL FOUR horizontal neighbours, so a wire beside a button would
	# have driven a door behind it that vanilla leaves alone.
	_lay_wire_next_to(Blocks.STONE_BUTTON, Redstone.MOUNT_WEST_WALL)
	assert_true(
		Redstone.wire_connects_toward(_w, WIRE, Vector3i(1, 0, 0)), "connects toward the button"
	)
	assert_false(
		Redstone.provides_weak_power(_w, WIRE, Redstone.SLOT_NORTH),
		"and therefore powers nothing perpendicular"
	)
	# Slot names where the WIRE sits relative to whoever is asking, so the
	# cell WEST of this wire queries with SLOT_EAST. A wire running
	# east-west feeds along that line and nowhere else.
	assert_true(
		Redstone.provides_weak_power(_w, WIRE, Redstone.SLOT_EAST),
		"but does power along its own straight line"
	)


func test_wire_beside_each_plate_is_not_treated_as_isolated() -> void:
	for id: int in [Blocks.STONE_PRESSURE_PLATE, Blocks.WOODEN_PRESSURE_PLATE]:
		before_each()
		_lay_wire_next_to(id, 0)
		assert_true(
			Redstone.wire_connects_toward(_w, WIRE, Vector3i(1, 0, 0)),
			"connects toward %s" % Blocks.name_of(id)
		)
		assert_false(
			Redstone.provides_weak_power(_w, WIRE, Redstone.SLOT_NORTH),
			"no perpendicular output beside %s" % Blocks.name_of(id)
		)


func test_a_genuinely_isolated_wire_still_powers_all_four_sides() -> void:
	# The other half of the rule — confirms the tests above are detecting
	# connectivity and not just a blanket "never powers sideways".
	_w.put(WIRE + Vector3i(0, -1, 0), Blocks.STONE)
	_w.put(WIRE, Blocks.REDSTONE_WIRE, Redstone.WIRE_MAX_POWER)
	for slot: int in [
		Redstone.SLOT_NORTH, Redstone.SLOT_SOUTH, Redstone.SLOT_EAST, Redstone.SLOT_WEST
	]:
		assert_true(Redstone.provides_weak_power(_w, WIRE, slot), "isolated wire powers slot")


# --- Consumer 3: the changed-neighbour guard ---------------------------


func test_button_and_plate_transitions_count_as_power_events_for_tnt() -> void:
	# Before the fix these ids failed `is_power_source`, so a button
	# wired to TNT through a relay block could never detonate it.
	for id: int in [Blocks.STONE_BUTTON, Blocks.STONE_PRESSURE_PLATE, Blocks.WOODEN_PRESSURE_PLATE]:
		before_each()
		var tnt := Vector3i(0, Y, 0)
		_w.put(tnt, Blocks.TNT)
		_w.put(tnt + Vector3i(-1, 0, 0), id, Redstone.POWERED_BIT | Redstone.MOUNT_EAST_WALL)
		Redstone.on_neighbor_changed(_w, tnt, id)
		assert_eq(_w.get_world_block(tnt), Blocks.AIR, "%s detonates TNT" % Blocks.name_of(id))
