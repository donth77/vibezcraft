extends GutTest

# Phase 8 B1b — redstone ore contact glow (.claude/redstone-plan.md §3.1).
#
# All three vanilla contact paths (walking an.b(…,lw2), punching
# an.a(…,eb2), right-clicking an.b(…,eb2)) funnel into one handler —
# our Blocks.touch_redstone_ore — so these tests lock the shared state
# machine on a fake manager. The engine wiring (interaction.gd punch +
# right-click, player footstep, mob env-tick) is call-site plumbing
# verified in the manual hand-back.
#
# Runs on the FakeWorld pattern from test_farming.gd: no scene tree, no
# disk, no real ChunkManager. TickScheduler is static — reset per test.


class FakeWorld:
	extends RefCounted
	# Sparse cell map; everything else reads AIR.
	var cells: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return cells.get(pos, Blocks.AIR)

	func set_world_block(pos: Vector3i, id: int) -> void:
		cells[pos] = id


const ORE_POS := Vector3i(4, 10, 4)

var _world: FakeWorld


func before_each() -> void:
	TickScheduler.reset_for_tests()
	_world = FakeWorld.new()
	_world.cells[ORE_POS] = Blocks.REDSTONE_ORE


func after_each() -> void:
	TickScheduler.reset_for_tests()


# Bury the ore completely in stone.
func _entomb() -> void:
	for normal: Vector3i in [
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1),
	]:
		_world.cells[ORE_POS + normal] = Blocks.STONE


# --- Contact → glow transition ---


func test_touch_swaps_unlit_to_glowing() -> void:
	Blocks.touch_redstone_ore(_world, ORE_POS)
	assert_eq(_world.get_world_block(ORE_POS), Blocks.GLOWING_REDSTONE_ORE, "unlit → lit swap")


func test_touch_on_lit_ore_keeps_it_lit() -> void:
	_world.cells[ORE_POS] = Blocks.GLOWING_REDSTONE_ORE
	Blocks.touch_redstone_ore(_world, ORE_POS)
	assert_eq(_world.get_world_block(ORE_POS), Blocks.GLOWING_REDSTONE_ORE, "stays lit")


func test_touch_on_non_ore_is_a_no_op() -> void:
	_world.cells[ORE_POS] = Blocks.STONE
	var emitted: int = Blocks.touch_redstone_ore(_world, ORE_POS)
	assert_eq(emitted, 0, "no particles on non-ore")
	assert_eq(_world.get_world_block(ORE_POS), Blocks.STONE, "cell untouched")
	assert_eq(TickScheduler.pending_count(), 0, "nothing scheduled")


func test_walking_hook_routes_ore_and_ignores_everything_else() -> void:
	Blocks.on_entity_walking(_world, ORE_POS)
	assert_eq(_world.get_world_block(ORE_POS), Blocks.GLOWING_REDSTONE_ORE, "walking lights ore")
	var stone_pos := Vector3i(9, 10, 9)
	_world.cells[stone_pos] = Blocks.STONE
	Blocks.on_entity_walking(_world, stone_pos)
	assert_eq(_world.get_world_block(stone_pos), Blocks.STONE, "walking on stone: no-op")
	assert_eq(TickScheduler.pending_count(), 1, "only the ore contact scheduled")


# --- Particle exposure rule (an.java i(): one per exposed face) ---


func test_fully_buried_ore_emits_no_particles() -> void:
	_entomb()
	assert_eq(Blocks.touch_redstone_ore(_world, ORE_POS), 0, "no faces exposed → 0 motes")


func test_one_exposed_face_emits_one_particle() -> void:
	_entomb()
	_world.cells.erase(ORE_POS + Vector3i(0, 1, 0))  # open the top face
	assert_eq(Blocks.touch_redstone_ore(_world, ORE_POS), 1, "single open face → 1 mote")


func test_fully_exposed_ore_emits_six_particles() -> void:
	assert_eq(Blocks.touch_redstone_ore(_world, ORE_POS), 6, "all six faces open → 6 motes")


func test_non_opaque_neighbors_count_as_exposed() -> void:
	# Water and torches are non-opaque — vanilla's `!cy2.g(...)` check
	# treats them like air, so the mote still spawns on that face.
	_entomb()
	_world.cells[ORE_POS + Vector3i(0, 1, 0)] = Blocks.WATER_STILL
	_world.cells[ORE_POS + Vector3i(1, 0, 0)] = Blocks.TORCH
	assert_eq(Blocks.touch_redstone_ore(_world, ORE_POS), 2, "water + torch faces are exposed")


func test_repeated_contact_still_sparkles() -> void:
	# Vanilla re-fires the sparkle on every contact even while lit.
	Blocks.touch_redstone_ore(_world, ORE_POS)
	assert_eq(Blocks.touch_redstone_ore(_world, ORE_POS), 6, "lit ore still emits per contact")


# --- Revert scheduling ---


func test_revert_scheduled_only_on_the_lit_transition() -> void:
	Blocks.touch_redstone_ore(_world, ORE_POS)
	assert_eq(TickScheduler.pending_count(), 1, "first contact schedules the revert")
	for _i in range(16):
		Blocks.touch_redstone_ore(_world, ORE_POS)
	assert_eq(TickScheduler.pending_count(), 1, "16 repeat contacts never grow the queue")


func test_revert_delay_stays_in_the_300_500_band() -> void:
	# Pin the global RNG so the sampled draws are reproducible (§10: no
	# statistical oracles).
	seed(1234)
	var seen := {}
	for _i in range(32):
		TickScheduler.reset_for_tests()
		_world.cells[ORE_POS] = Blocks.REDSTONE_ORE
		Blocks.touch_redstone_ore(_world, ORE_POS)
		var entries: Array = TickScheduler.peek_for_chunk(0, 0)
		assert_eq(entries.size(), 1, "exactly one pending revert")
		var delay: int = entries[0]["delay"]
		assert_between(delay, 300, 499, "delay ∈ [300, 500) ticks")
		seen[delay] = true
	assert_gt(seen.size(), 1, "delay actually varies across contacts")


func test_scheduled_revert_fires_at_the_exact_tick() -> void:
	Blocks.touch_redstone_ore(_world, ORE_POS)
	TickScheduler.cancel(ORE_POS, Blocks.GLOWING_REDSTONE_ORE)
	TickScheduler.schedule(ORE_POS, Blocks.GLOWING_REDSTONE_ORE, 10)
	# 9 ticks: nothing yet. Stepped one advance() per tick — the catch-up
	# cap (_MAX_TICKS_PER_ADVANCE = 2) discards bulk jumps.
	for _i in range(9):
		TickScheduler.advance(0.05, _world)
	assert_eq(_world.get_world_block(ORE_POS), Blocks.GLOWING_REDSTONE_ORE, "no early revert")
	# The 10th tick fires the revert.
	TickScheduler.advance(0.05, _world)
	assert_eq(_world.get_world_block(ORE_POS), Blocks.REDSTONE_ORE, "reverts on schedule")
	assert_eq(TickScheduler.pending_count(), 0, "queue drained")


func test_stale_revert_no_ops_when_the_cell_changed() -> void:
	Blocks.touch_redstone_ore(_world, ORE_POS)
	TickScheduler.cancel(ORE_POS, Blocks.GLOWING_REDSTONE_ORE)
	TickScheduler.schedule(ORE_POS, Blocks.GLOWING_REDSTONE_ORE, 5)
	# Mined mid-delay: the cell is air (or anything else) by fire time.
	_world.cells[ORE_POS] = Blocks.AIR
	for _i in range(5):
		TickScheduler.advance(0.05, _world)
	assert_eq(_world.get_world_block(ORE_POS), Blocks.AIR, "stale tick leaves the cell alone")


func test_full_glow_cycle_can_relight_after_revert() -> void:
	Blocks.touch_redstone_ore(_world, ORE_POS)
	TickScheduler.cancel(ORE_POS, Blocks.GLOWING_REDSTONE_ORE)
	TickScheduler.schedule(ORE_POS, Blocks.GLOWING_REDSTONE_ORE, 3)
	for _i in range(3):
		TickScheduler.advance(0.05, _world)
	assert_eq(_world.get_world_block(ORE_POS), Blocks.REDSTONE_ORE, "cycle 1 reverted")
	Blocks.touch_redstone_ore(_world, ORE_POS)
	assert_eq(
		_world.get_world_block(ORE_POS),
		Blocks.GLOWING_REDSTONE_ORE,
		"contact relights after revert"
	)
	assert_eq(TickScheduler.pending_count(), 1, "fresh revert scheduled for cycle 2")


# --- FX plumbing (real Node parent — exercises the pooled emitter) ---


func test_spawn_reddust_builds_a_particle_under_the_parent() -> void:
	var parent := Node3D.new()
	add_child_autofree(parent)
	BlockFx.spawn_reddust(parent, Vector3i(1, 2, 3), Vector3(0, 1, 0))
	var found: CPUParticles3D = null
	for child in parent.get_children():
		if child is CPUParticles3D:
			found = child
	assert_not_null(found, "reddust emitter attached to the parent")
	assert_true(found.one_shot and found.amount == 1, "one mote per contact event")
	assert_almost_eq(found.position.y, 2.0 + 0.5 + 0.57, 0.001, "sits just outside the +Y face")
	assert_eq(
		found.emission_box_extents, Vector3(0.35, 0.0, 0.35), "jitter spans the face plane only"
	)


func test_touch_with_node_manager_emits_fx_without_errors() -> void:
	# A Node-typed manager flips the `manager is Node` FX gate on — the
	# full touch path (swap + schedule + six spawns) must run clean.
	var manager := _NodeWorld.new()
	add_child_autofree(manager)
	manager.cells[ORE_POS] = Blocks.REDSTONE_ORE
	var emitted: int = Blocks.touch_redstone_ore(manager, ORE_POS)
	assert_eq(emitted, 6, "six exposed faces sparkle through the FX gate")
	assert_eq(manager.get_world_block(ORE_POS), Blocks.GLOWING_REDSTONE_ORE, "swap still happens")


class _NodeWorld:
	extends Node3D
	var cells: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return cells.get(pos, Blocks.AIR)

	func set_world_block(pos: Vector3i, id: int) -> void:
		cells[pos] = id
