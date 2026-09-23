# gdlint: disable=max-public-methods
extends GutTest

# Rail auto-orientation and the one place Alpha lets redstone touch a
# rail — `oc.java:203-283` (shape) and `jn.java:65-99` (when it re-runs).
#
# The tie-break is genuinely strange and therefore easy to "simplify"
# into something wrong: vanilla assigns the straights first, then runs
# the four curve tests, letting each overwrite the last — so running
# those four tests in REVERSE order is the entire difference between a
# powered and an unpowered junction. Every expected meta below was read
# off the decompiled ordering by hand, not generated from the code under
# test, so a refactor that inverts the order fails here.
#
# The previous test for this only checked that `interaction.gd` had a
# constant map. It never built a rail.

const RAIL := Vector3i(0, 64, 0)
const SUPPORT := Vector3i(0, 63, 0)
const TORCH := Vector3i(0, 62, 0)


class RailWorld:
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


var _w: RailWorld


func before_each() -> void:
	_w = RailWorld.new()
	Redstone.reset_state()


func _lay_neighbours(n: bool, s: bool, e: bool, w: bool) -> void:
	_w.put(RAIL, Blocks.RAIL, 0)
	if n:
		_w.put(RAIL + Vector3i(0, 0, -1), Blocks.RAIL, 0)
	if s:
		_w.put(RAIL + Vector3i(0, 0, 1), Blocks.RAIL, 0)
	if e:
		_w.put(RAIL + Vector3i(1, 0, 0), Blocks.RAIL, 0)
	if w:
		_w.put(RAIL + Vector3i(-1, 0, 0), Blocks.RAIL, 0)


# Power (or don't) the rail cell from UNDERNEATH: a floor-mounted torch
# strong-powers the block above it (bo.java:121), that block is a normal
# cube so it relays, and the rail on top reads as indirectly powered.
#
# Deliberately not a lever on a side block — the four horizontal cells
# are the ones under test, and a source parked in one of them would
# change the junction's shape as a side effect of powering it.
func _power_from_below(on: bool) -> void:
	_w.put(SUPPORT, Blocks.STONE)
	_w.put(TORCH, Blocks.REDSTONE_TORCH if on else Blocks.REDSTONE_TORCH_OFF, Redstone.MOUNT_FLOOR)


# --- The ambiguous tie-break, exact metas ------------------------------


func test_every_three_way_junction_resolves_to_its_documented_curve() -> void:
	# [n, s, e, w, unpowered_meta, powered_meta]
	var cases: Array = [
		[true, true, true, false, RailShape.CURVE_SE, RailShape.CURVE_NE],
		[true, true, false, true, RailShape.CURVE_SW, RailShape.CURVE_NW],
		[true, false, true, true, RailShape.CURVE_NE, RailShape.CURVE_NW],
		[false, true, true, true, RailShape.CURVE_SE, RailShape.CURVE_SW],
	]
	for case: Array in cases:
		var label: String = (
			"n=%s s=%s e=%s w=%s" % [str(case[0]), str(case[1]), str(case[2]), str(case[3])]
		)
		assert_eq(
			RailShape.ambiguous_meta(case[0], case[1], case[2], case[3], false),
			case[4],
			"unpowered %s" % label
		)
		assert_eq(
			RailShape.ambiguous_meta(case[0], case[1], case[2], case[3], true),
			case[5],
			"powered %s" % label
		)


func test_power_flips_every_three_way_junction_to_a_different_curve() -> void:
	# The property the tie-break exists for. Stated separately from the
	# table so a table typo can't accidentally satisfy it.
	for case: Array in [
		[true, true, true, false],
		[true, true, false, true],
		[true, false, true, true],
		[false, true, true, true],
	]:
		var off: int = RailShape.ambiguous_meta(case[0], case[1], case[2], case[3], false)
		var on: int = RailShape.ambiguous_meta(case[0], case[1], case[2], case[3], true)
		assert_ne(off, on, "power changes the resolved curve")


func test_a_four_way_junction_also_resolves_but_to_its_own_pair() -> void:
	assert_eq(RailShape.ambiguous_meta(true, true, true, true, false), RailShape.CURVE_SE)
	assert_eq(RailShape.ambiguous_meta(true, true, true, true, true), RailShape.CURVE_NW)


# --- Shape computation from a real layout ------------------------------


func test_connection_count_matches_oc_c() -> void:
	_lay_neighbours(true, true, true, false)
	assert_eq(RailShape.connection_count(_w, RAIL), 3, "three same-Y rail neighbours")
	_lay_neighbours(true, true, true, true)
	assert_eq(RailShape.connection_count(_w, RAIL), 4, "four")


func test_two_opposite_neighbours_make_a_straight() -> void:
	_lay_neighbours(true, true, false, false)
	assert_eq(RailShape.compute(_w, RAIL, false, 0), RailShape.STRAIGHT_NS, "N/S straight")
	before_each()
	_lay_neighbours(false, false, true, true)
	assert_eq(RailShape.compute(_w, RAIL, false, 0), RailShape.STRAIGHT_EW, "E/W straight")


func test_two_perpendicular_neighbours_make_the_matching_curve() -> void:
	var cases: Array = [
		[true, false, true, false, RailShape.CURVE_NE],
		[true, false, false, true, RailShape.CURVE_NW],
		[false, true, true, false, RailShape.CURVE_SE],
		[false, true, false, true, RailShape.CURVE_SW],
	]
	for case: Array in cases:
		before_each()
		_lay_neighbours(case[0], case[1], case[2], case[3])
		assert_eq(RailShape.compute(_w, RAIL, false, 0), case[4], "curve")


func test_a_higher_neighbour_turns_a_straight_into_a_ramp() -> void:
	_w.put(RAIL, Blocks.RAIL, 0)
	_w.put(RAIL + Vector3i(0, 0, -1), Blocks.RAIL, 0)
	_w.put(RAIL + Vector3i(0, 1, -1), Blocks.RAIL, 0)
	assert_eq(RailShape.compute(_w, RAIL, false, 0), RailShape.ASCEND_NORTH, "ascends north")


func test_an_isolated_rail_takes_the_callers_fallback() -> void:
	_w.put(RAIL, Blocks.RAIL, 0)
	assert_eq(RailShape.compute(_w, RAIL, false, RailShape.STRAIGHT_EW), RailShape.STRAIGHT_EW)
	assert_eq(RailShape.compute(_w, RAIL, false, RailShape.STRAIGHT_NS), RailShape.STRAIGHT_NS)


func test_a_three_way_junction_reads_power_through_the_shape_path_too() -> void:
	_lay_neighbours(true, true, true, false)
	assert_eq(RailShape.compute(_w, RAIL, false, 0), RailShape.CURVE_SE, "unpowered")
	assert_eq(RailShape.compute(_w, RAIL, true, 0), RailShape.CURVE_NE, "powered")


func test_connection_count_includes_rails_a_step_up_or_down() -> void:
	# oc.java:72-80 looks at the neighbour cell AND one above and below.
	_w.put(RAIL, Blocks.RAIL, 0)
	_w.put(RAIL + Vector3i(0, 0, -1), Blocks.RAIL, 0)
	_w.put(RAIL + Vector3i(1, 1, 0), Blocks.RAIL, 0)
	_w.put(RAIL + Vector3i(-1, -1, 0), Blocks.RAIL, 0)
	assert_eq(RailShape.connection_count(_w, RAIL), 3)


# --- Placement: jn.java:58-63 → oc.java:203-290 ------------------------
#
# Each rail below is laid the way the game lays one — RailShape.update
# with fresh = true — so neighbours re-shape exactly as they would in play.


func _place(pos: Vector3i, isolated_meta: int) -> int:
	_w.put(pos + Vector3i(0, -1, 0), Blocks.STONE)
	return RailShape.update(_w, pos, false, isolated_meta, true)


func test_the_rail_at_the_top_of_a_step_stays_flat() -> void:
	# Field report #10: "railing will go uphill on first place despite a
	# rail not being uphill". Laying a rail on a step next to a lower one
	# tilted the NEW rail up into empty air. Vanilla only ever tilts the
	# lower rail, toward the higher one; the top rail stays flat.
	var low := Vector3i(0, 64, 0)
	var high := Vector3i(1, 65, 0)
	_place(low, RailShape.STRAIGHT_EW)
	_place(high, RailShape.STRAIGHT_NS)
	assert_eq(_w.get_world_block_meta(high), RailShape.STRAIGHT_EW, "top rail flat, aimed down")
	assert_eq(_w.get_world_block_meta(low), RailShape.ASCEND_EAST, "lower rail ramps up to it")


func test_laying_the_lower_rail_second_gives_the_same_ramp() -> void:
	var low := Vector3i(0, 64, 0)
	var high := Vector3i(1, 65, 0)
	_place(high, RailShape.STRAIGHT_NS)
	assert_eq(_place(low, RailShape.STRAIGHT_NS), RailShape.ASCEND_EAST, "new rail ramps up")
	assert_eq(
		_w.get_world_block_meta(high), RailShape.STRAIGHT_EW, "the top rail turns to meet the ramp"
	)


func test_a_staircase_ramps_every_step_but_the_top_whichever_end_is_laid_first() -> void:
	var steps: Array[Vector3i] = [Vector3i(0, 64, 0), Vector3i(1, 65, 0), Vector3i(2, 66, 0)]
	for bottom_up: bool in [true, false]:
		before_each()
		var order: Array[Vector3i] = steps.duplicate()
		if not bottom_up:
			order.reverse()
		for pos: Vector3i in order:
			_place(pos, RailShape.STRAIGHT_EW)
		var label: String = "bottom-up" if bottom_up else "top-down"
		assert_eq(_w.get_world_block_meta(steps[0]), RailShape.ASCEND_EAST, "%s: step 1" % label)
		assert_eq(_w.get_world_block_meta(steps[1]), RailShape.ASCEND_EAST, "%s: step 2" % label)
		assert_eq(_w.get_world_block_meta(steps[2]), RailShape.STRAIGHT_EW, "%s: top" % label)


func test_a_ramp_joins_onto_flat_track_behind_it() -> void:
	# The lower rail already runs west; the new rail a step up to the
	# east is its second link, so it straightens and tilts toward it.
	_place(Vector3i(-1, 64, 0), RailShape.STRAIGHT_EW)
	_place(Vector3i(0, 64, 0), RailShape.STRAIGHT_NS)
	_place(Vector3i(1, 65, 0), RailShape.STRAIGHT_NS)
	assert_eq(_w.get_world_block_meta(Vector3i(0, 64, 0)), RailShape.ASCEND_EAST)
	assert_eq(_w.get_world_block_meta(Vector3i(-1, 64, 0)), RailShape.STRAIGHT_EW)


func test_a_rail_beside_the_middle_of_a_track_leaves_the_track_straight() -> void:
	# The middle rail's two ends are both linked, so it is full and does
	# not take a third (oc.java:130-145). Re-deriving it from scratch
	# bent it into a curve.
	for z: int in [-1, 0, 1]:
		_place(Vector3i(0, 64, z), RailShape.STRAIGHT_NS)
	assert_eq(_w.get_world_block_meta(Vector3i(0, 64, 0)), RailShape.STRAIGHT_NS, "laid straight")
	var side: int = _place(Vector3i(1, 64, 0), RailShape.STRAIGHT_EW)
	assert_eq(_w.get_world_block_meta(Vector3i(0, 64, 0)), RailShape.STRAIGHT_NS, "still straight")
	assert_eq(side, RailShape.STRAIGHT_EW, "the new rail links to nothing and takes the fallback")


func test_a_rail_beside_the_end_of_a_track_turns_the_end_into_a_curve() -> void:
	_place(Vector3i(0, 64, 0), RailShape.STRAIGHT_NS)
	_place(Vector3i(0, 64, 1), RailShape.STRAIGHT_NS)
	assert_eq(_place(Vector3i(1, 64, 1), RailShape.STRAIGHT_NS), RailShape.STRAIGHT_EW)
	assert_eq(_w.get_world_block_meta(Vector3i(0, 64, 1)), RailShape.CURVE_NE, "N + E curve")
	assert_eq(_w.get_world_block_meta(Vector3i(0, 64, 0)), RailShape.STRAIGHT_NS, "untouched")


# --- jn.java:89 — when the runtime actually re-shapes ------------------


func test_powering_a_three_way_junction_reshapes_it() -> void:
	_lay_neighbours(true, true, true, false)
	_w.metas[RAIL] = RailShape.CURVE_SE
	_power_from_below(true)
	Redstone.on_neighbor_changed(_w, RAIL, Blocks.REDSTONE_TORCH)
	assert_eq(_w.get_world_block_meta(RAIL), RailShape.CURVE_NE, "flipped to the powered curve")


func test_unpowering_it_puts_the_curve_back() -> void:
	_lay_neighbours(true, true, true, false)
	_w.metas[RAIL] = RailShape.CURVE_NE
	_power_from_below(false)
	Redstone.on_neighbor_changed(_w, RAIL, Blocks.REDSTONE_TORCH_OFF)
	assert_eq(_w.get_world_block_meta(RAIL), RailShape.CURVE_SE, "back to the unpowered curve")


func test_a_non_source_neighbour_change_leaves_the_junction_alone() -> void:
	# Same guard as TNT: `nq.m[n5].e()`. Stacking dirt next to a junction
	# must not silently re-shape the track under a moving cart.
	_lay_neighbours(true, true, true, false)
	_w.metas[RAIL] = RailShape.CURVE_SE
	_power_from_below(true)
	Redstone.on_neighbor_changed(_w, RAIL, Blocks.DIRT)
	assert_eq(_w.get_world_block_meta(RAIL), RailShape.CURVE_SE, "unchanged")


func test_a_four_way_junction_is_left_alone_by_power_changes() -> void:
	# `oc.a(...) == 3` is an equality, not a minimum — vanilla declines to
	# re-shape a four-way crossing on a power change.
	_lay_neighbours(true, true, true, true)
	_w.metas[RAIL] = RailShape.CURVE_SE
	_power_from_below(true)
	Redstone.on_neighbor_changed(_w, RAIL, Blocks.REDSTONE_TORCH)
	assert_eq(_w.get_world_block_meta(RAIL), RailShape.CURVE_SE, "four-way is not re-shaped")


func test_a_straight_rail_is_never_reshaped_by_power() -> void:
	_lay_neighbours(true, true, false, false)
	_w.metas[RAIL] = RailShape.STRAIGHT_NS
	_power_from_below(true)
	Redstone.on_neighbor_changed(_w, RAIL, Blocks.REDSTONE_TORCH)
	assert_eq(_w.get_world_block_meta(RAIL), RailShape.STRAIGHT_NS, "two connections, no ambiguity")
