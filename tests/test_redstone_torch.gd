# gdlint: disable=max-public-methods
extends GutTest

# Phase 8d — the redstone torch (.claude/redstone-plan.md §3.3).
#
# Port of bo.java. Three behaviours matter and each is easy to get
# subtly wrong: the inversion itself, the 2-tick delay that makes it
# Alpha's only timing primitive, and burnout — 8 off-transitions inside
# 100 ticks kills the torch until its entries age out.
#
# The fake world carries its own tick counter (via `redstone_tick`) so
# burnout windows can be driven precisely without the real scheduler.

const Y: int = 64
const MOUNT := Vector3i(0, 64, 0)
# Torch on the east face of MOUNT: it sits at x+1 and points away.
const TORCH := Vector3i(1, 64, 0)


class FakeWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var drops: Array = []
	var burnouts: Array = []
	var burnout_log: Array = []
	var tick: int = 0

	# Burnout history is world state — owning it here keeps each test
	# fully isolated without depending on any static reset.
	func redstone_burnout_log() -> Array:
		return burnout_log

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

	func spawn_block_drop(pos: Vector3i, dropped_id: int) -> void:
		drops.append([pos, dropped_id])

	func play_torch_burnout(pos: Vector3i) -> void:
		burnouts.append(pos)

	func redstone_tick() -> int:
		return tick

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta


var _w: FakeWorld


func before_each() -> void:
	Redstone.reset_state()
	TickScheduler.reset_for_tests()
	_w = FakeWorld.new()
	# Stone mount with a lit torch on its east face (meta 1 = attached
	# to the block at x-1, which is MOUNT).
	_w.put(MOUNT, Blocks.STONE)
	_w.put(TORCH, Blocks.REDSTONE_TORCH, Redstone.MOUNT_WEST_WALL)


func after_each() -> void:
	Redstone.reset_state()
	TickScheduler.reset_for_tests()


# Energise the mount by sticking a powered lever on its far side.
func _power_mount(on: bool) -> void:
	var lever_pos: Vector3i = MOUNT + Vector3i(-1, 0, 0)
	var meta: int = Redstone.MOUNT_EAST_WALL | (Redstone.POWERED_BIT if on else 0)
	_w.put(lever_pos, Blocks.LEVER, meta)


# --- Inversion ---


func test_torch_reads_its_mount() -> void:
	assert_false(Redstone.torch_mount_powered(_w, TORCH), "unpowered mount")
	_power_mount(true)
	assert_true(Redstone.torch_mount_powered(_w, TORCH), "powered mount")


func test_powered_mount_turns_a_lit_torch_off() -> void:
	_power_mount(true)
	Redstone.torch_tick(_w, TORCH, Blocks.REDSTONE_TORCH)
	assert_eq(_w.get_world_block(TORCH), Blocks.REDSTONE_TORCH_OFF, "inverted off")


func test_unpowered_mount_relights_an_off_torch() -> void:
	_w.put(TORCH, Blocks.REDSTONE_TORCH_OFF, Redstone.MOUNT_WEST_WALL)
	Redstone.torch_tick(_w, TORCH, Blocks.REDSTONE_TORCH_OFF)
	assert_eq(_w.get_world_block(TORCH), Blocks.REDSTONE_TORCH, "relit")


func test_state_change_preserves_orientation() -> void:
	_power_mount(true)
	Redstone.torch_tick(_w, TORCH, Blocks.REDSTONE_TORCH)
	assert_eq(
		_w.get_world_block_meta(TORCH),
		Redstone.MOUNT_WEST_WALL,
		"mount metadata survives the id swap"
	)


func test_a_settled_torch_does_not_flip() -> void:
	for _i in range(5):
		Redstone.torch_tick(_w, TORCH, Blocks.REDSTONE_TORCH)
	assert_eq(_w.get_world_block(TORCH), Blocks.REDSTONE_TORCH, "stays lit over an idle mount")


# --- The 2-tick delay ---


func test_neighbour_change_schedules_rather_than_flipping_now() -> void:
	_power_mount(true)
	Redstone.on_neighbor_changed(_w, TORCH)
	assert_eq(_w.get_world_block(TORCH), Blocks.REDSTONE_TORCH, "no immediate flip")
	assert_eq(TickScheduler.pending_count(), 1, "one scheduled re-evaluation")


func test_the_flip_lands_on_tick_two() -> void:
	_power_mount(true)
	Redstone.on_neighbor_changed(_w, TORCH)
	TickScheduler.advance(0.05, _w)
	assert_eq(_w.get_world_block(TORCH), Blocks.REDSTONE_TORCH, "still lit after one tick")
	TickScheduler.advance(0.05, _w)
	assert_eq(_w.get_world_block(TORCH), Blocks.REDSTONE_TORCH_OFF, "flips on the second tick")


func test_an_agreeing_torch_schedules_nothing() -> void:
	# Mount unpowered and torch lit: they already agree, so a neighbour
	# update must not refill the tick queue.
	Redstone.on_neighbor_changed(_w, TORCH)
	assert_eq(TickScheduler.pending_count(), 0, "settled torch schedules nothing")


# --- Power output (bo.java:65, 121) ---


func test_lit_torch_powers_every_slot_except_its_mount() -> void:
	var excluded: int = Redstone._torch_excluded_slot(Redstone.MOUNT_WEST_WALL)
	for slot in range(6):
		var powered: bool = Redstone.provides_weak_power(_w, TORCH, slot)
		if slot == excluded:
			assert_false(powered, "withholds power from its own mount (slot %d)" % slot)
		else:
			assert_true(powered, "powers slot %d" % slot)


func test_excluded_slot_is_correct_for_every_orientation() -> void:
	# The excluded slot is always the one where the asker IS the mount.
	var cases := {
		Redstone.MOUNT_FLOOR: Redstone.SLOT_ABOVE,
		Redstone.MOUNT_WEST_WALL: Redstone.SLOT_EAST,
		Redstone.MOUNT_EAST_WALL: Redstone.SLOT_WEST,
		Redstone.MOUNT_NORTH_WALL: Redstone.SLOT_SOUTH,
		Redstone.MOUNT_SOUTH_WALL: Redstone.SLOT_NORTH,
	}
	for mount: int in cases:
		assert_eq(
			Redstone._torch_excluded_slot(mount),
			cases[mount],
			"mount %d excludes its own slot" % mount
		)


func test_unlit_torch_powers_nothing() -> void:
	_w.put(TORCH, Blocks.REDSTONE_TORCH_OFF, Redstone.MOUNT_WEST_WALL)
	for slot in range(6):
		assert_false(Redstone.provides_weak_power(_w, TORCH, slot), "off torch: slot %d" % slot)


func test_strong_power_goes_only_to_the_block_above() -> void:
	for slot in range(6):
		var strong: bool = Redstone.provides_strong_power(_w, TORCH, slot)
		assert_eq(
			strong,
			slot == Redstone.SLOT_BELOW,
			"strong power only at slot 0 (the block above), not %d" % slot
		)


func test_torch_under_a_block_powers_wire_on_top_of_it() -> void:
	# The classic Alpha circuit: torch beneath a solid block, wire above.
	var below := Vector3i(5, Y, 5)
	var block := below + Vector3i(0, 1, 0)
	var wire := below + Vector3i(0, 2, 0)
	_w.put(below + Vector3i(0, -1, 0), Blocks.STONE)
	_w.put(below, Blocks.REDSTONE_TORCH, Redstone.MOUNT_FLOOR)
	_w.put(block, Blocks.STONE)
	_w.put(wire, Blocks.REDSTONE_WIRE, 0)
	Redstone.update_wire(_w, wire)
	assert_eq(_w.get_world_block_meta(wire), 15, "wire on the block above the torch reads 15")


func test_both_torch_variants_are_power_sources_for_connectivity() -> void:
	# bo.java:e() returns true unconditionally, so wire links to an
	# unlit torch as well.
	assert_true(Redstone.is_power_source(Blocks.REDSTONE_TORCH))
	assert_true(Redstone.is_power_source(Blocks.REDSTONE_TORCH_OFF))


# --- Burnout (bo.java:20-32) ---


func _force_off_transition() -> void:
	# Put the torch back on, power the mount, and run the tick — one
	# recorded off-transition.
	_w.put(TORCH, Blocks.REDSTONE_TORCH, Redstone.MOUNT_WEST_WALL)
	_power_mount(true)
	Redstone.torch_tick(_w, TORCH, Blocks.REDSTONE_TORCH)


func test_seven_transitions_do_not_burn_out() -> void:
	for _i in range(7):
		_force_off_transition()
	assert_eq(_w.burnouts.size(), 0, "under the limit")


func test_the_eighth_transition_burns_out() -> void:
	for _i in range(8):
		_force_off_transition()
	assert_eq(_w.burnouts.size(), 1, "exactly one burnout fired")
	assert_eq(_w.burnouts[0], TORCH, "at the torch's cell")


func test_a_burnt_out_torch_refuses_to_relight() -> void:
	for _i in range(8):
		_force_off_transition()
	_power_mount(false)
	_w.put(TORCH, Blocks.REDSTONE_TORCH_OFF, Redstone.MOUNT_WEST_WALL)
	Redstone.torch_tick(_w, TORCH, Blocks.REDSTONE_TORCH_OFF)
	assert_eq(_w.get_world_block(TORCH), Blocks.REDSTONE_TORCH_OFF, "stays dark while burnt out")


func test_it_recovers_once_the_window_passes() -> void:
	for _i in range(8):
		_force_off_transition()
	_power_mount(false)
	_w.put(TORCH, Blocks.REDSTONE_TORCH_OFF, Redstone.MOUNT_WEST_WALL)
	# Age past the 100-tick retention window.
	_w.tick = Redstone.TORCH_BURNOUT_WINDOW_TICKS + 5
	Redstone.torch_tick(_w, TORCH, Blocks.REDSTONE_TORCH_OFF)
	assert_eq(_w.get_world_block(TORCH), Blocks.REDSTONE_TORCH, "relights after the window")


func test_transitions_spread_over_time_never_burn_out() -> void:
	# Same eight transitions, but spaced past the window — a slow
	# circuit must not be penalised.
	for i in range(8):
		_w.tick = i * (Redstone.TORCH_BURNOUT_WINDOW_TICKS + 1)
		_force_off_transition()
	assert_eq(_w.burnouts.size(), 0, "no burnout when spread out")


func test_burnout_is_per_position() -> void:
	var other := Vector3i(9, Y, 9)
	_w.put(other + Vector3i(-1, 0, 0), Blocks.STONE)
	_w.put(other, Blocks.REDSTONE_TORCH, Redstone.MOUNT_WEST_WALL)
	for _i in range(7):
		_force_off_transition()
	# A different torch's transitions must not push the first over.
	for _i in range(7):
		_w.put(other, Blocks.REDSTONE_TORCH, Redstone.MOUNT_WEST_WALL)
		_w.put(
			other + Vector3i(-2, 0, 0),
			Blocks.LEVER,
			Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT
		)
		Redstone.torch_tick(_w, other, Blocks.REDSTONE_TORCH)
	assert_eq(_w.burnouts.size(), 0, "two torches at 7 each is not 14 at one")


func test_a_fresh_world_starts_with_clean_burnout_history() -> void:
	# Burnout history is per-world state, not a static, so loading a
	# different save can't inherit a torch's history. Seven transitions
	# in one world leave the next world at zero.
	for _i in range(7):
		_force_off_transition()
	assert_eq(_w.burnout_log.size(), 7, "history recorded in this world")
	var other := FakeWorld.new()
	other.put(MOUNT, Blocks.STONE)
	other.put(TORCH, Blocks.REDSTONE_TORCH, Redstone.MOUNT_WEST_WALL)
	assert_eq(other.burnout_log.size(), 0, "a different world starts clean")
	# And it takes a full 8 in the new world to burn out, not 1.
	for _i in range(7):
		other.put(TORCH, Blocks.REDSTONE_TORCH, Redstone.MOUNT_WEST_WALL)
		other.put(
			MOUNT + Vector3i(-1, 0, 0),
			Blocks.LEVER,
			Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT
		)
		Redstone.torch_tick(other, TORCH, Blocks.REDSTONE_TORCH)
	assert_eq(other.burnouts.size(), 0, "history did not carry over")


# --- Support ---


func test_torch_pops_off_when_its_mount_goes() -> void:
	_w.put(MOUNT, Blocks.AIR)
	Redstone.on_neighbor_changed(_w, TORCH)
	assert_eq(_w.get_world_block(TORCH), Blocks.AIR, "removed")
	assert_eq(_w.drops.size(), 1, "dropped")
	assert_eq(_w.drops[0][1], Blocks.REDSTONE_TORCH, "an OFF torch still drops the lit id")


func test_off_torch_also_drops_the_lit_id() -> void:
	_w.put(TORCH, Blocks.REDSTONE_TORCH_OFF, Redstone.MOUNT_WEST_WALL)
	_w.put(MOUNT, Blocks.AIR)
	Redstone.on_neighbor_changed(_w, TORCH)
	assert_eq(_w.drops[0][1], Blocks.REDSTONE_TORCH, "bo.java a() returns the lit id")
