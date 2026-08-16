# gdlint: disable=max-public-methods
extends GutTest

# Phase 8f — persistence, chunk edges, and world events
# (.claude/redstone-plan.md §9 Batch 5a).
#
# Save/load cases use a UNIQUE throwaway world name per test and clean
# it up on both sides, per the test-plan rule: touching World1 or any
# player-selected world is forbidden.

const Y: int = 64
const REDSTONE_IDS: Array[int] = [
	Blocks.REDSTONE_ORE,
	Blocks.GLOWING_REDSTONE_ORE,
	Blocks.REDSTONE_WIRE,
	Blocks.REDSTONE_TORCH,
	Blocks.REDSTONE_TORCH_OFF,
	Blocks.LEVER,
	Blocks.STONE_BUTTON,
	Blocks.STONE_PRESSURE_PLATE,
	Blocks.WOODEN_PRESSURE_PLATE,
]

var _world_name: String


func before_each() -> void:
	TickScheduler.reset_for_tests()
	Redstone.reset_state()
	# Unique per test so a crashed run can never collide with a real save.
	_world_name = "test_redstone_%d" % Time.get_ticks_usec()
	_purge()


func after_each() -> void:
	_purge()
	TickScheduler.reset_for_tests()


func _purge() -> void:
	SaveLoad.clear_cache()
	var dir: String = SaveLoad.world_dir(_world_name)
	if DirAccess.dir_exists_absolute(dir):
		OS.move_to_trash(ProjectSettings.globalize_path(dir))


# --- Block + metadata round-trip ---


func test_every_redstone_id_and_meta_survives_a_round_trip() -> void:
	var chunk := Chunk.new()
	var expected := {}
	var i: int = 0
	for id: int in REDSTONE_IDS:
		# Give each one a distinct, meaningful metadata value: mount
		# orientations, a mid-range wire level, pressed flags.
		var meta: int = (i * 3) % 16
		chunk.set_block(i, Y, 0, id)
		chunk.set_block_meta(i, Y, 0, meta)
		expected[i] = [id, meta]
		i += 1
	var entry := {
		"bytes": chunk.blocks,
		"block_meta": chunk.block_meta,
		"sky_light": chunk.sky_light,
		"block_light": chunk.block_light,
		"height_map": PackedByteArray(),
		"max_y": chunk.max_y,
	}
	assert_true(SaveLoad.save_chunk(Vector2i(0, 0), entry, _world_name), "saved")
	SaveLoad.clear_cache()
	var loaded: Dictionary = SaveLoad.load_chunk(Vector2i(0, 0), _world_name)
	assert_false(loaded.is_empty(), "chunk came back")
	var blocks: PackedByteArray = loaded["bytes"]
	var metas: PackedByteArray = loaded["block_meta"]
	for x: int in expected:
		var idx: int = Chunk.index(x, Y, 0)
		assert_eq(blocks[idx], expected[x][0], "id at x=%d" % x)
		assert_eq(metas[idx], expected[x][1], "meta at x=%d" % x)


func test_a_full_wire_level_range_round_trips() -> void:
	# Wire uses the entire nibble, so every level must survive — a
	# truncation bug would only show at the high end.
	var chunk := Chunk.new()
	for level in range(16):
		chunk.set_block(level, Y, 1, Blocks.REDSTONE_WIRE)
		chunk.set_block_meta(level, Y, 1, level)
	var entry := {
		"bytes": chunk.blocks,
		"block_meta": chunk.block_meta,
		"sky_light": chunk.sky_light,
		"block_light": chunk.block_light,
		"height_map": PackedByteArray(),
		"max_y": chunk.max_y,
	}
	SaveLoad.save_chunk(Vector2i(0, 0), entry, _world_name)
	SaveLoad.clear_cache()
	var loaded: Dictionary = SaveLoad.load_chunk(Vector2i(0, 0), _world_name)
	var metas: PackedByteArray = loaded["block_meta"]
	for level in range(16):
		assert_eq(metas[Chunk.index(level, Y, 1)], level, "wire level %d" % level)


# --- Pending scheduled ticks ---


func test_pending_redstone_ticks_harvest_and_restore() -> void:
	# A pressed button, a lit ore and a torch all have work in flight.
	# Unloading a chunk must carry that work with it.
	TickScheduler.schedule(Vector3i(2, Y, 2), Blocks.STONE_BUTTON, 20)
	TickScheduler.schedule(Vector3i(3, Y, 3), Blocks.GLOWING_REDSTONE_ORE, 400)
	TickScheduler.schedule(Vector3i(4, Y, 4), Blocks.REDSTONE_TORCH, 2)
	var harvested: Array = TickScheduler.take_for_chunk(0, 0)
	assert_eq(harvested.size(), 3, "all three came out")
	assert_eq(TickScheduler.pending_count(), 0, "queue drained by the harvest")
	TickScheduler.restore_ticks(harvested)
	assert_eq(TickScheduler.pending_count(), 3, "restored")


func test_a_held_plates_recheck_survives_unload_and_reload() -> void:
	# A plate under a standing player re-checks every 20 ticks, and that
	# pending tick is what eventually RELEASES it. Lose it across an
	# unload and the plate stays stuck down forever with nothing
	# scheduled to notice the player has gone.
	var plate := Vector3i(6, Y, 6)
	var world := _FakeWorld.new()
	world.blocks[plate + Vector3i(0, -1, 0)] = Blocks.STONE
	world.blocks[plate] = Blocks.WOODEN_PRESSURE_PLATE
	world.metas[plate] = 0
	world.occupied = true
	Redstone.update_plate(world, plate, Blocks.WOODEN_PRESSURE_PLATE, true)
	assert_eq(world.metas[plate], 1, "pressed")
	assert_eq(TickScheduler.pending_count(), 1, "a recheck is queued")

	for _i in range(7):
		TickScheduler.advance(0.05, world)
	var harvested: Array = TickScheduler.take_for_chunk(0, 0)
	assert_eq(harvested.size(), 1, "the recheck came out with the chunk")
	assert_eq(int(harvested[0]["delay"]), 13, "13 of the 20 ticks remain")
	assert_eq(int(harvested[0]["block_id"]), Blocks.WOODEN_PRESSURE_PLATE, "as a plate tick")

	# Reload with the entity gone: the restored recheck must release it.
	TickScheduler.restore_ticks(harvested)
	world.occupied = false
	for _i in range(14):
		TickScheduler.advance(0.05, world)
	assert_eq(world.metas[plate], 0, "the restored recheck released the plate")


func test_restored_ticks_keep_their_remaining_delay() -> void:
	TickScheduler.schedule(Vector3i(5, Y, 5), Blocks.STONE_BUTTON, 20)
	# Burn 5 ticks, then unload.
	for _i in range(5):
		TickScheduler.advance(0.05, _FakeWorld.new())
	var harvested: Array = TickScheduler.take_for_chunk(0, 0)
	assert_eq(harvested.size(), 1, "harvested")
	assert_eq(int(harvested[0]["delay"]), 15, "15 of the 20 ticks remain, not a fresh 20")


class _FakeWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var occupied: bool = false

	func entities_overlap_box(_box: AABB, _living_only: bool) -> bool:
		return occupied

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func set_world_block_state(pos: Vector3i, id: int, meta: int, _n: bool = true) -> bool:
		blocks[pos] = id
		metas[pos] = meta & 0xF
		return true

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta


# --- Reconciliation after a stale load ---


func test_wire_reconciles_when_its_source_changed_while_unloaded() -> void:
	# The scenario chunk-edge reconciliation exists for: wire comes back
	# from disk still holding power, but the lever that fed it is now
	# off. Re-seeding the network must correct it.
	var w := _FakeWorld.new()
	for i in range(6):
		w.put(Vector3i(i, Y - 1, 0), Blocks.STONE)
		w.put(Vector3i(i, Y, 0), Blocks.REDSTONE_WIRE, maxi(15 - i, 0))
	w.put(Vector3i(-1, Y, 0), Blocks.STONE)
	w.put(Vector3i(-2, Y, 0), Blocks.LEVER, Redstone.MOUNT_EAST_WALL)  # OFF
	Redstone.update_wire(w, Vector3i(0, Y, 0), true)
	for i in range(6):
		assert_eq(w.get_world_block_meta(Vector3i(i, Y, 0)), 0, "stale level cleared at %d" % i)


func test_reconciliation_from_a_far_cell_still_fixes_the_line() -> void:
	# Reconciliation seeds from whichever cells sit on the chunk seam,
	# which may be the far end of a run rather than the source.
	var w := _FakeWorld.new()
	for i in range(6):
		w.put(Vector3i(i, Y - 1, 0), Blocks.STONE)
		w.put(Vector3i(i, Y, 0), Blocks.REDSTONE_WIRE, 0)
	w.put(Vector3i(-1, Y, 0), Blocks.STONE)
	w.put(Vector3i(-2, Y, 0), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	Redstone.update_wire(w, Vector3i(5, Y, 0), true)
	assert_eq(w.get_world_block_meta(Vector3i(0, Y, 0)), 15, "source end powered")
	assert_eq(w.get_world_block_meta(Vector3i(5, Y, 0)), 10, "far end correct")


# --- World events: fluids and explosions ---


func test_redstone_components_are_washed_away_by_fluid() -> void:
	for id: int in [
		Blocks.REDSTONE_WIRE,
		Blocks.REDSTONE_TORCH,
		Blocks.REDSTONE_TORCH_OFF,
		Blocks.STONE_BUTTON,
		Blocks.STONE_PRESSURE_PLATE,
		Blocks.WOODEN_PRESSURE_PLATE,
	]:
		assert_true(
			Blocks.is_replaceable(id), "%s is flimsy enough to wash out" % Blocks.name_of(id)
		)


func test_redstone_ore_is_not_washed_away() -> void:
	for id: int in [Blocks.REDSTONE_ORE, Blocks.GLOWING_REDSTONE_ORE]:
		assert_false(Blocks.is_replaceable(id), "ore is an ordinary solid block")


func test_removing_a_source_depowers_surviving_wire() -> void:
	# Stands in for an explosion taking out the lever: the wire it fed
	# must not stay lit.
	var w := _FakeWorld.new()
	for i in range(5):
		w.put(Vector3i(i, Y - 1, 0), Blocks.STONE)
		w.put(Vector3i(i, Y, 0), Blocks.REDSTONE_WIRE, 0)
	w.put(Vector3i(-1, Y, 0), Blocks.STONE)
	w.put(Vector3i(-2, Y, 0), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	Redstone.update_wire(w, Vector3i(0, Y, 0))
	assert_eq(w.get_world_block_meta(Vector3i(0, Y, 0)), 15, "powered first")
	# Blast removes the lever AND its mount.
	w.put(Vector3i(-2, Y, 0), Blocks.AIR)
	w.put(Vector3i(-1, Y, 0), Blocks.AIR)
	Redstone.update_wire(w, Vector3i(0, Y, 0))
	for i in range(5):
		assert_eq(w.get_world_block_meta(Vector3i(i, Y, 0)), 0, "cell %d de-powered" % i)


func test_all_nine_ids_are_distinct_and_in_the_reserved_range() -> void:
	var seen := {}
	for id: int in REDSTONE_IDS:
		assert_between(id, 88, 96, "%s inside the reserved block range" % Blocks.name_of(id))
		assert_false(seen.has(id), "id %d used once" % id)
		seen[id] = true
	assert_eq(seen.size(), 9, "nine distinct redstone blocks")


# --- Rail curve tie-breaker (oc.java:203+) ---


func test_the_rail_tie_break_lives_in_one_shared_place() -> void:
	# Placement (`interaction.gd`) and the redstone re-evaluation
	# (`jn.java:89`) must resolve a junction identically. They can only
	# be guaranteed to if they call the same code, so this asserts the
	# shared entry point exists — the behaviour itself is pinned, meta by
	# meta, in `tests/test_rail_shape.gd`.
	assert_true(
		load("res://scripts/player/interaction.gd").source_code.contains("RailShape.compute"),
		"placement goes through RailShape"
	)


# --- Convergence cost on a large settled network ---


func test_a_settled_network_does_no_work() -> void:
	# §7.7's core claim, in the form a headless test can check: once a
	# circuit has settled, re-running propagation performs ZERO writes.
	# A settled circuit that keeps rewriting itself would be both a
	# correctness bug and the source of any per-frame cost.
	var w := _CountingWorld.new()
	for i in range(32):
		w.put(Vector3i(i, Y - 1, 0), Blocks.STONE)
		w.put(Vector3i(i, Y, 0), Blocks.REDSTONE_WIRE, 0)
	w.put(Vector3i(-1, Y, 0), Blocks.STONE)
	w.put(Vector3i(-2, Y, 0), Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	Redstone.update_wire(w, Vector3i(0, Y, 0))
	var writes_after_settle: int = w.writes
	assert_gt(writes_after_settle, 0, "the first pass did real work")
	w.writes = 0
	for _i in range(5):
		Redstone.update_wire(w, Vector3i(0, Y, 0))
	assert_eq(w.writes, 0, "a settled network performs no writes at all")


func test_toggling_a_large_network_converges_in_one_pass() -> void:
	var w := _CountingWorld.new()
	for i in range(32):
		w.put(Vector3i(i, Y - 1, 0), Blocks.STONE)
		w.put(Vector3i(i, Y, 0), Blocks.REDSTONE_WIRE, 0)
	w.put(Vector3i(-1, Y, 0), Blocks.STONE)
	var lever := Vector3i(-2, Y, 0)
	w.put(lever, Blocks.LEVER, Redstone.MOUNT_EAST_WALL | Redstone.POWERED_BIT)
	Redstone.update_wire(w, Vector3i(0, Y, 0))
	# Only the first 15 cells can carry power; the rest stay dark.
	assert_eq(w.get_world_block_meta(Vector3i(14, Y, 0)), 1, "reach ends at 15 cells")
	assert_eq(w.get_world_block_meta(Vector3i(15, Y, 0)), 0, "and stops there")
	w.put(lever, Blocks.LEVER, Redstone.MOUNT_EAST_WALL)
	w.writes = 0
	Redstone.update_wire(w, Vector3i(0, Y, 0))
	for i in range(32):
		assert_eq(w.get_world_block_meta(Vector3i(i, Y, 0)), 0, "cell %d drained" % i)
	# Depowering RIPPLES: a cell steps down as the wave drains rather
	# than snapping straight to zero, so cells are rewritten several
	# times in one pass. Vanilla's recursive version behaves the same
	# way — it's why large old-Minecraft circuits visibly take a moment
	# to go dark. Bound it rather than pinning an exact count.
	assert_between(w.writes, 15, 200, "converges without runaway rewriting")


class _CountingWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var writes: int = 0

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func set_world_block_state(pos: Vector3i, id: int, meta: int, _n: bool = true) -> bool:
		var old_id: int = blocks.get(pos, Blocks.AIR)
		var old_meta: int = metas.get(pos, 0)
		if old_id == id and old_meta == (meta & 0xF):
			return false
		blocks[pos] = id
		metas[pos] = meta & 0xF
		writes += 1
		return true

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta
