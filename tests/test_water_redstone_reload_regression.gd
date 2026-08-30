extends GutTest

# Regression for the World1 field report: a redstone build beside a 2x2
# source pool disappeared after reload while a nearby animal repeatedly
# emitted the water-entry sound.

const POOL_Y: int = 64
const ChunkManagerScript := preload("res://scripts/world/chunk_manager.gd")


class ChunkHolder:
	extends Node3D
	var chunk: Chunk


class FluidWorld:
	extends RefCounted
	var chunk := Chunk.new()
	var metas: Dictionary = {}

	func get_chunk_at_coord(coord: Vector2i) -> Chunk:
		return chunk if coord == Vector2i.ZERO else null

	func get_world_block(pos: Vector3i) -> int:
		if pos.x < 0 or pos.x >= 16 or pos.z < 0 or pos.z >= 16:
			return Blocks.AIR
		return chunk.get_block(pos.x, pos.y, pos.z)

	func get_world_block_meta(pos: Vector3i) -> int:
		if pos.x < 0 or pos.x >= 16 or pos.z < 0 or pos.z >= 16:
			return 0
		return chunk.get_block_meta(pos.x, pos.y, pos.z)


class SampleWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var meta: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return int(blocks.get(pos, Blocks.AIR))

	func get_world_block_meta(pos: Vector3i) -> int:
		return int(meta.get(pos, 0))


func before_each() -> void:
	TickScheduler.reset_for_tests()


func after_each() -> void:
	TickScheduler.reset_for_tests()


func test_checked_block_state_has_a_sticky_persistence_signal() -> void:
	var chunk := Chunk.new()
	assert_false(chunk.modified_since_save, "fresh generated data is a clean baseline")
	chunk.set_block(2, POOL_Y, 2, Blocks.REDSTONE_WIRE)
	assert_true(chunk.modified_since_save, "id change arms persistence")
	chunk.modified_since_save = false
	chunk.set_block_with_meta(3, POOL_Y, 2, Blocks.WATER_FLOWING, 4)
	assert_true(chunk.modified_since_save, "atomic id/meta change arms persistence")
	chunk.modified_since_save = false
	chunk.set_block_meta(3, POOL_Y, 2, 5)
	assert_true(chunk.modified_since_save, "metadata-only change arms persistence")


func test_direct_fluid_state_swaps_cannot_escape_the_save_queue() -> void:
	var world := FluidWorld.new()
	var pos := Vector3i(4, POOL_Y, 4)
	world.chunk.set_block_with_meta(pos.x, pos.y, pos.z, Blocks.WATER_STILL, 0)
	world.chunk.modified_since_save = false
	BlockFluids.on_neighbor_changed(world, pos)
	assert_eq(world.get_world_block(pos), Blocks.WATER_FLOWING, "still water wakes")
	assert_true(world.chunk.modified_since_save, "direct demotion remains persistable")

	world.chunk.modified_since_save = false
	BlockFluids._promote_to_still(world, pos, Blocks.WATER_FLOWING)
	assert_eq(world.get_world_block(pos), Blocks.WATER_STILL, "flowing water settles")
	assert_true(world.chunk.modified_since_save, "direct promotion remains persistable")


func test_save_collection_recovers_a_missed_manager_dirty_entry() -> void:
	var manager: Node3D = ChunkManagerScript.new()
	var holder := ChunkHolder.new()
	holder.chunk = Chunk.new()
	var coord := Vector2i(1, -4)
	manager._chunks[coord] = holder
	holder.chunk.set_block(14, 72, 12, Blocks.WATER_STILL)
	manager._dirty_loaded.clear()  # fault injection: the old loss condition
	assert_true(
		manager._collect_chunks_needing_save().has(coord),
		"chunk data's sticky signal repairs a missed manager-side flag"
	)
	holder.free()
	manager.free()


func test_vanilla_inset_aabb_stops_swim_lift_before_an_animal_can_hover() -> void:
	var world := SampleWorld.new()
	world.blocks[Vector3i.ZERO] = Blocks.WATER_STILL
	world.meta[Vector3i.ZERO] = 0
	# Alpha pig BB = 0.9 × 0.9. `aG.b(0, -0.4, 0)` insets its lower
	# face to feet+0.4; it does not shift the box down. Wet clears when
	# that inset lower face crosses into cell y=1, while the real feet
	# are still below the source surface. This prevents another swim
	# impulse from launching the animal visibly above the pool.
	assert_true(
		MobBase.body_touches_fluid(world, Vector3(0.5, 0.599, 0.5), 0.9, 0.9, true),
		"the inset lower face still scans the source cell just below feet y=0.6"
	)
	assert_false(
		MobBase.body_touches_fluid(world, Vector3(0.5, 0.6, 0.5), 0.9, 0.9, true),
		"the wet state clears at Alpha's exact inset boundary"
	)


func test_fluid_probe_uses_the_whole_width_and_vanilla_scan_bounds() -> void:
	var world := SampleWorld.new()
	world.blocks[Vector3i.ZERO] = Blocks.WATER_FLOWING
	world.meta[Vector3i.ZERO] = 0
	assert_true(
		MobBase.body_touches_fluid(world, Vector3(1.449, 0.2, 0.5), 0.9, 0.9, true),
		"an edge-overlapping body is wet even when its centre is in the next cell"
	)
	assert_false(
		MobBase.body_touches_fluid(world, Vector3(1.45, 0.2, 0.5), 0.9, 0.9, true),
		"the AABB no longer reaches the source cell past the width boundary"
	)


func test_eye_submersion_uses_alpha_fluid_height_not_only_block_id() -> void:
	var world := SampleWorld.new()
	world.blocks[Vector3i.ZERO] = Blocks.WATER_FLOWING
	world.meta[Vector3i.ZERO] = 7
	assert_true(
		MobBase.point_is_submerged_in_fluid(world, Vector3(0.5, 0.2, 0.5), true),
		"an eye below the metadata-7 surface (2/9 block) is submerged"
	)
	assert_false(
		MobBase.point_is_submerged_in_fluid(world, Vector3(0.5, 0.23, 0.5), true),
		"an eye in the dry portion of the same water voxel can breathe"
	)


func test_fluid_fall_delta_matches_one_alpha_tick_at_any_frame_split() -> void:
	var one_step: float = MobBase._alpha_fluid_fall_delta(0.8, 0.8)
	assert_almost_eq(one_step, -0.4, 0.000001, "0.02 blocks/tick becomes -0.4 m/s")
	var third_tick_drag: float = pow(0.8, 1.0 / 3.0)
	var third_step: float = MobBase._alpha_fluid_fall_delta(0.8, third_tick_drag)
	var velocity_y: float = 0.0
	for _frame: int in range(3):
		velocity_y = velocity_y * third_tick_drag + third_step
	assert_almost_eq(velocity_y, -0.4, 0.000001, "three 60 Hz frames equal one Alpha tick")


func test_alpha_mobs_inherit_fifteen_seconds_of_air() -> void:
	assert_eq(MobBase._MAX_AIR_TICKS, 300, "lw.java initializes max air to 300 ticks")
