# gdlint: disable=max-public-methods
extends GutTest

# Phase 8c — wire propagation (.claude/redstone-plan.md §3.2).
#
# Port of lu.java:h(). The acceptance oracle from the plan is exact, not
# statistical: with a lever adjacent to cell 1, a 16-wire line must read
# 15,14,…,1,0. Every test here pins layout and insertion order so a
# result can't drift.

const Y: int = 64
const FLOOR_Y: int = 63


class FakeWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var notified: Array = []
	var drops: Array = []

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
		return true

	func enqueue_block_notification(pos: Vector3i) -> void:
		notified.append(pos)

	func spawn_block_drop(pos: Vector3i, dropped_id: int) -> void:
		drops.append([pos, dropped_id])

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta


var _w: FakeWorld


func before_each() -> void:
	_w = FakeWorld.new()
	Redstone._wire_output_enabled = true


# Lay `count` wire cells running east from x=0, each on a stone floor.
func _lay_line(count: int, y: int = Y) -> void:
	for i in range(count):
		_w.put(Vector3i(i, y - 1, 0), Blocks.STONE)
		_w.put(Vector3i(i, y, 0), Blocks.REDSTONE_WIRE, 0)


func _levels(count: int, y: int = Y) -> Array:
	var out: Array = []
	for i in range(count):
		out.append(_w.get_world_block_meta(Vector3i(i, y, 0)))
	return out


# Power the line by mounting a lever on a stone block west of cell 0.
func _attach_lever(on: bool) -> void:
	_w.put(Vector3i(-1, Y, 0), Blocks.STONE)
	var meta: int = Redstone.MOUNT_EAST_WALL | (Redstone.POWERED_BIT if on else 0)
	_w.put(Vector3i(-2, Y, 0), Blocks.LEVER, meta)


# --- The exact decay oracle ---


func test_sixteen_wire_line_reads_15_down_to_0() -> void:
	_lay_line(16)
	_attach_lever(true)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	var expected: Array = []
	for i in range(16):
		expected.append(maxi(15 - i, 0))
	assert_eq(_levels(16), expected, "15,14,…,1,0 across sixteen cells")


func test_seventeenth_cell_is_dark() -> void:
	_lay_line(17)
	_attach_lever(true)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_eq(_w.get_world_block_meta(Vector3i(15, Y, 0)), 0, "cell 15 is already 0")
	assert_eq(_w.get_world_block_meta(Vector3i(16, Y, 0)), 0, "and stays 0 beyond")


func test_removing_the_source_depowers_the_whole_line() -> void:
	_lay_line(16)
	_attach_lever(true)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_eq(_w.get_world_block_meta(Vector3i(0, Y, 0)), 15, "powered first")
	_attach_lever(false)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	var zeros: Array = []
	for i in range(16):
		zeros.append(0)
	assert_eq(_levels(16), zeros, "entire line returns to 0")


func test_unpowered_line_stays_dark() -> void:
	_lay_line(8)
	_attach_lever(false)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_eq(_levels(8), [0, 0, 0, 0, 0, 0, 0, 0], "no source, no power")


# --- Convergence independent of insertion order ---


func test_result_is_independent_of_which_cell_seeds_the_update() -> void:
	var expected: Array = []
	for i in range(16):
		expected.append(maxi(15 - i, 0))
	for seed_index: int in [0, 1, 7, 14, 15]:
		_w = FakeWorld.new()
		_lay_line(16)
		_attach_lever(true)
		Redstone.update_wire(_w, Vector3i(seed_index, Y, 0))
		assert_eq(_levels(16), expected, "seeded from cell %d" % seed_index)


func test_a_loop_converges_instead_of_spinning() -> void:
	# Ring of wire around a 4x4 footprint, powered at one corner. A
	# naive "already processed" dedup would either spin or settle early.
	for i in range(4):
		for j in range(4):
			if i == 0 or j == 0 or i == 3 or j == 3:
				_w.put(Vector3i(i, Y - 1, j), Blocks.STONE)
				_w.put(Vector3i(i, Y, j), Blocks.REDSTONE_WIRE, 0)
	_w.put(Vector3i(-1, Y, 0), Blocks.STONE)
	_w.put(Vector3i(-2, Y, 0), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_eq(_w.get_world_block_meta(Vector3i(0, Y, 0)), 15, "corner at source is 15")
	# Opposite corner is 6 steps away along either arm of the ring.
	assert_eq(_w.get_world_block_meta(Vector3i(3, Y, 3)), 9, "far corner decayed by 6")


func test_branch_gets_the_same_level_on_both_arms() -> void:
	# T-junction: trunk running east, branch heading north from cell 3.
	_lay_line(6)
	for j in range(1, 4):
		_w.put(Vector3i(3, Y - 1, -j), Blocks.STONE)
		_w.put(Vector3i(3, Y, -j), Blocks.REDSTONE_WIRE, 0)
	_attach_lever(true)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_eq(_w.get_world_block_meta(Vector3i(3, Y, 0)), 12, "trunk at the junction")
	assert_eq(_w.get_world_block_meta(Vector3i(3, Y, -1)), 11, "branch decays from the junction")
	assert_eq(_w.get_world_block_meta(Vector3i(3, Y, -3)), 9, "and keeps decaying")


# --- Vertical rules (lu.java:64-70), which are asymmetric ---


func test_wire_climbs_up_a_step_when_not_roofed() -> void:
	_lay_line(3)
	# Step up at x=3: a solid block with wire on top of it.
	_w.put(Vector3i(3, Y - 1, 0), Blocks.STONE)
	_w.put(Vector3i(3, Y, 0), Blocks.STONE)
	_w.put(Vector3i(3, Y + 1, 0), Blocks.REDSTONE_WIRE, 0)
	_attach_lever(true)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_eq(_w.get_world_block_meta(Vector3i(2, Y, 0)), 13, "cell before the step")
	assert_eq(_w.get_world_block_meta(Vector3i(3, Y + 1, 0)), 12, "power climbed the step")


func test_climb_is_blocked_when_the_lower_wire_is_roofed() -> void:
	_lay_line(3)
	_w.put(Vector3i(3, Y - 1, 0), Blocks.STONE)
	_w.put(Vector3i(3, Y, 0), Blocks.STONE)
	_w.put(Vector3i(3, Y + 1, 0), Blocks.REDSTONE_WIRE, 0)
	# Roof over cell 2 — vanilla refuses the climb in this case.
	_w.put(Vector3i(2, Y + 1, 0), Blocks.STONE)
	_attach_lever(true)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_eq(_w.get_world_block_meta(Vector3i(3, Y + 1, 0)), 0, "roofed cell can't climb")


func test_wire_drops_down_an_open_step() -> void:
	_lay_line(3)
	# Cell 3 is open (air) with wire one level below it.
	_w.put(Vector3i(3, Y - 2, 0), Blocks.STONE)
	_w.put(Vector3i(3, Y - 1, 0), Blocks.REDSTONE_WIRE, 0)
	_attach_lever(true)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_eq(_w.get_world_block_meta(Vector3i(3, Y - 1, 0)), 12, "power dropped down the step")


func test_drop_is_blocked_by_a_solid_side() -> void:
	_lay_line(3)
	_w.put(Vector3i(3, Y, 0), Blocks.STONE)  # solid side, nothing on top
	_w.put(Vector3i(3, Y - 2, 0), Blocks.STONE)
	_w.put(Vector3i(3, Y - 1, 0), Blocks.REDSTONE_WIRE, 0)
	_attach_lever(true)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_eq(_w.get_world_block_meta(Vector3i(3, Y - 1, 0)), 0, "solid side blocks the drop")


# --- Connectivity predicate (lu.java:299) ---


func test_wire_connects_to_wire_and_sources_only() -> void:
	var pos := Vector3i(5, Y, 5)
	_w.put(pos + Vector3i(1, 0, 0), Blocks.REDSTONE_WIRE)
	assert_true(Redstone.can_connect_to(_w, pos + Vector3i(1, 0, 0)), "wire ↔ wire")
	_w.put(pos + Vector3i(1, 0, 0), Blocks.LEVER, Redstone.MOUNT_FLOOR)
	assert_true(Redstone.can_connect_to(_w, pos + Vector3i(1, 0, 0)), "wire ↔ source")
	for id: int in [Blocks.AIR, Blocks.STONE, Blocks.GLASS, Blocks.TORCH]:
		_w.put(pos + Vector3i(1, 0, 0), id)
		assert_false(
			Redstone.can_connect_to(_w, pos + Vector3i(1, 0, 0)),
			"wire must not link to %s" % Blocks.name_of(id)
		)


# --- Directional output (lu.java:c) ---


func test_a_straight_run_powers_beyond_both_ends() -> void:
	_lay_line(3)
	_attach_lever(true)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	# Cell beyond the east end asks with slot WEST (the wire is west of it).
	assert_true(
		Redstone.provides_weak_power(_w, Vector3i(2, Y, 0), Redstone.SLOT_WEST),
		"east-running line powers the cell past its end"
	)
	# It must NOT power sideways off a straight run.
	assert_false(
		Redstone.provides_weak_power(_w, Vector3i(1, Y, 0), Redstone.SLOT_NORTH),
		"no sideways output from a straight line"
	)


func test_wire_always_powers_the_block_below() -> void:
	_lay_line(2)
	_attach_lever(true)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_true(
		Redstone.provides_weak_power(_w, Vector3i(0, Y, 0), Redstone.SLOT_ABOVE),
		"the supporting block reads the wire above it"
	)


func test_isolated_wire_powers_all_four_sides() -> void:
	_w.put(Vector3i(0, Y - 1, 0), Blocks.STONE)
	_w.put(Vector3i(0, Y, 0), Blocks.REDSTONE_WIRE, 9)
	for slot: int in [
		Redstone.SLOT_NORTH, Redstone.SLOT_SOUTH, Redstone.SLOT_WEST, Redstone.SLOT_EAST
	]:
		assert_true(
			Redstone.provides_weak_power(_w, Vector3i(0, Y, 0), slot),
			"unconnected wire powers slot %d" % slot
		)


func test_unpowered_wire_powers_nothing() -> void:
	_w.put(Vector3i(0, Y - 1, 0), Blocks.STONE)
	_w.put(Vector3i(0, Y, 0), Blocks.REDSTONE_WIRE, 0)
	for slot in range(6):
		assert_false(
			Redstone.provides_weak_power(_w, Vector3i(0, Y, 0), slot), "level 0 → no output"
		)


# --- The self-feed guard ---


func test_wire_does_not_feed_itself_through_its_support_block() -> void:
	# A powered wire strong-powers the block below it. Without the
	# recomputation guard, that block would look like a fresh source and
	# pin the whole line at 15.
	_lay_line(5)
	_attach_lever(true)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_eq(_w.get_world_block_meta(Vector3i(4, Y, 0)), 11, "still decaying, not pinned at 15")
	assert_true(Redstone._wire_output_enabled, "guard restored after the pass")


func test_guard_is_restored_even_across_repeated_updates() -> void:
	_lay_line(4)
	_attach_lever(true)
	for _i in range(3):
		Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_true(Redstone._wire_output_enabled, "guard is not left off")


# --- Zero-crossing notification rule (lu.java:104) ---


func test_notifications_only_fire_on_zero_crossings() -> void:
	_lay_line(4)
	_attach_lever(true)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	# Every cell went 0 → non-zero, so each notifies exactly once.
	assert_eq(_w.notified.size(), 4, "one notification per cell that left zero")
	_w.notified.clear()
	# Re-running with no change must notify nobody.
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_eq(_w.notified.size(), 0, "settled network is silent")


# --- Support loss ---


func test_wire_pops_off_when_its_floor_goes() -> void:
	var pos := Vector3i(0, Y, 0)
	_w.put(pos, Blocks.REDSTONE_WIRE, 5)
	Redstone.on_neighbor_changed(_w, pos)
	assert_eq(_w.get_world_block(pos), Blocks.AIR, "wire removed")
	assert_eq(_w.drops.size(), 1, "dropped")
	assert_eq(_w.drops[0][1], Items.REDSTONE, "drops dust, not a block")


func test_supported_wire_survives_a_neighbour_change() -> void:
	var pos := Vector3i(0, Y, 0)
	_w.put(Vector3i(0, Y - 1, 0), Blocks.STONE)
	_w.put(pos, Blocks.REDSTONE_WIRE, 0)
	Redstone.on_neighbor_changed(_w, pos)
	assert_eq(_w.get_world_block(pos), Blocks.REDSTONE_WIRE, "still there")
	assert_eq(_w.drops.size(), 0, "no drop")


func test_non_cube_support_is_not_enough() -> void:
	var pos := Vector3i(0, Y, 0)
	_w.put(Vector3i(0, Y - 1, 0), Blocks.HALF_SLAB)
	_w.put(pos, Blocks.REDSTONE_WIRE, 0)
	Redstone.on_neighbor_changed(_w, pos)
	assert_eq(_w.get_world_block(pos), Blocks.AIR, "a slab can't hold wire")


# --- Scale ---


func test_large_network_converges_within_the_worklist_cap() -> void:
	# 32x32 wire field on stone — far larger than any real Alpha circuit.
	for i in range(32):
		for j in range(32):
			_w.put(Vector3i(i, Y - 1, j), Blocks.STONE)
			_w.put(Vector3i(i, Y, j), Blocks.REDSTONE_WIRE, 0)
	_w.put(Vector3i(-1, Y, 0), Blocks.STONE)
	_w.put(Vector3i(-2, Y, 0), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	Redstone.update_wire(_w, Vector3i(0, Y, 0))
	assert_eq(_w.get_world_block_meta(Vector3i(0, Y, 0)), 15, "source corner at full strength")
	# A field conducts outward in all directions; 15 steps away is dark.
	assert_eq(_w.get_world_block_meta(Vector3i(20, Y, 20)), 0, "beyond range stays dark")
