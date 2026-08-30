extends GutTest


class WaterWorld:
	extends Node3D

	var block_id: int = Blocks.WATER_STILL
	var block_meta: int = 0

	func get_world_effective_light(_pos: Vector3i, _sky_subtraction: int = -1) -> int:
		return 15

	func get_world_block(_pos: Vector3i) -> int:
		return block_id

	func get_world_block_meta(_pos: Vector3i) -> int:
		return block_meta

	func get_chunk_at_coord(_coord: Vector2i):
		return null


const ORIGIN := Vector3(10.5, 20.5, 30.5)


func test_bubble_uses_alpha_tile_scale_lifetime_and_motion_ranges() -> void:
	var world := WaterWorld.new()
	add_child_autofree(world)
	var source_motion := Vector3(1.0, 2.0, 3.0)
	var bubble: Sprite3D = FluidFx.spawn_water_bubble(world, ORIGIN, source_motion)[0]

	assert_eq((bubble.texture as AtlasTexture).region, Rect2(0, 16, 8, 8))
	assert_eq(bubble.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST)
	assert_almost_eq(bubble.pixel_size * 8.0, 0.2, 0.0001, "pp.java quad width")
	assert_between(float(bubble.get("_base_scale")), 0.2, 1.6, "bh.java scale")
	assert_between(int(bubble.get("_max_age_ticks")), 8, 40, "bh.java lifetime")
	var motion: Vector3 = bubble.get("_motion_per_tick") as Vector3
	assert_between(motion.x, 0.18, 0.22, "20% source X plus +/-0.02")
	assert_between(motion.y, 0.38, 0.42, "20% source Y plus +/-0.02")
	assert_between(motion.z, 0.58, 0.62, "20% source Z plus +/-0.02")


func test_bubble_tick_applies_buoyancy_movement_and_drag_in_source_order() -> void:
	var world := WaterWorld.new()
	add_child_autofree(world)
	var bubble: Sprite3D = FluidFx.spawn_water_bubble(world, ORIGIN)[0]
	bubble.set("_motion_per_tick", Vector3(0.1, 0.2, 0.3))

	bubble.call("_process", 0.05)

	var moved := Vector3(0.1, 0.202, 0.3)
	assert_eq(bubble.get("_current_position") as Vector3, ORIGIN + moved)
	assert_eq(bubble.get("_motion_per_tick") as Vector3, moved * 0.85)


func test_bubble_dies_as_soon_as_its_center_is_not_in_water() -> void:
	var world := WaterWorld.new()
	world.block_id = Blocks.AIR
	add_child_autofree(world)
	var bubble: Sprite3D = FluidFx.spawn_water_bubble(world, ORIGIN)[0]

	bubble.call("_process", 0.05)

	assert_true(bubble.is_queued_for_deletion(), "bh.java rejects a non-water material")


func test_splash_uses_tiles_20_through_23_and_source_ranges() -> void:
	var world := WaterWorld.new()
	world.block_id = Blocks.AIR
	add_child_autofree(world)
	var splash: Sprite3D = FluidFx.spawn_water_splash(world, ORIGIN)[0]
	var region: Rect2 = (splash.texture as AtlasTexture).region

	assert_eq(region.size, Vector2(8, 8))
	assert_eq(region.position.y, 8.0)
	assert_between(region.position.x, 32.0, 56.0, "mf.java tiles 20..23")
	assert_eq(int(region.position.x) % 8, 0)
	assert_between(float(splash.get("_base_scale")), 1.0, 2.0, "pc.java scale")
	assert_between(int(splash.get("_max_age_ticks")), 8, 40, "pc.java lifetime")


func test_splash_only_honors_a_horizontal_only_supplied_velocity() -> void:
	var world := WaterWorld.new()
	world.block_id = Blocks.AIR
	add_child_autofree(world)
	var horizontal := Vector3(0.25, 0.0, -0.125)
	var splash: Sprite3D = FluidFx.spawn_water_splash(world, ORIGIN, horizontal)[0]
	assert_eq(
		splash.get("_motion_per_tick") as Vector3,
		Vector3(0.25, 0.1, -0.125),
		"mf.java replaces motion only when supplied Y is exactly zero"
	)

	var ignored: Sprite3D = FluidFx.spawn_water_splash(world, ORIGIN, Vector3(99.0, 0.01, 99.0))[0]
	var randomized: Vector3 = ignored.get("_motion_per_tick") as Vector3
	assert_between(randomized.y, 0.1, 0.3, "pc.java replaces vertical motion")
	assert_lt(absf(randomized.x), 1.0, "nonzero supplied Y makes mf ignore caller X")
	assert_lt(absf(randomized.z), 1.0, "nonzero supplied Y makes mf ignore caller Z")


func test_splash_tick_applies_gravity_before_movement_then_drag() -> void:
	var world := WaterWorld.new()
	world.block_id = Blocks.AIR
	add_child_autofree(world)
	var splash: Sprite3D = FluidFx.spawn_water_splash(world, ORIGIN)[0]
	splash.set("_motion_per_tick", Vector3(0.1, 0.2, 0.3))

	splash.call("_process", 0.05)

	var moved := Vector3(0.1, 0.16, 0.3)
	assert_eq(splash.get("_current_position") as Vector3, ORIGIN + moved)
	assert_eq(splash.get("_motion_per_tick") as Vector3, moved * 0.98)


func test_splash_fluid_surface_height_matches_block_metadata() -> void:
	assert_almost_eq(AlphaWaterParticle.source_surface_height(20, 0), 20.888889, 0.00001)
	assert_almost_eq(AlphaWaterParticle.source_surface_height(20, 7), 20.111111, 0.00001)
	assert_almost_eq(
		AlphaWaterParticle.source_surface_height(20, 8),
		20.888889,
		0.00001,
		"falling-water metadata is treated as level zero"
	)


func test_player_width_entry_creates_thirteen_of_each_at_aabb_surface() -> void:
	var world := WaterWorld.new()
	add_child_autofree(world)
	var entity_position := Vector3(10.0, 21.4, 30.0)
	var particles: Array[Sprite3D] = FluidFx.spawn_water_entry(
		world, entity_position, 20.5, 0.6, Vector3.ZERO
	)

	assert_eq(particles.size(), 26, "lw.java creates 13 bubbles then 13 splashes")
	for i in range(particles.size()):
		var particle: Sprite3D = particles[i]
		assert_eq(particle.global_position.y, 21.0)
		assert_between(particle.global_position.x, 9.4, 10.6)
		assert_between(particle.global_position.z, 29.4, 30.6)
		var expected_kind: int = (
			AlphaWaterParticle.Kind.BUBBLE if i < 13 else AlphaWaterParticle.Kind.SPLASH
		)
		assert_eq(int(particle.get("_kind")), expected_kind)


func test_drowning_pulse_creates_eight_bubbles_in_triangular_cube() -> void:
	var world := WaterWorld.new()
	add_child_autofree(world)
	var particles: Array[Sprite3D] = FluidFx.spawn_drowning_bubbles(world, ORIGIN, Vector3.ZERO)

	assert_eq(particles.size(), 8, "hf.java drowning pulse")
	for particle: Sprite3D in particles:
		var offset: Vector3 = particle.global_position - ORIGIN
		assert_between(offset.x, -1.0, 1.0)
		assert_between(offset.y, -1.0, 1.0)
		assert_between(offset.z, -1.0, 1.0)
		assert_eq(int(particle.get("_kind")), AlphaWaterParticle.Kind.BUBBLE)


func test_boat_wake_uses_source_threshold_count_and_height() -> void:
	var world := WaterWorld.new()
	world.block_id = Blocks.AIR
	add_child_autofree(world)
	assert_true(
		FluidFx.spawn_boat_wake(world, ORIGIN, 0.0, Vector3(0.149, 0.0, 0.0)).is_empty(),
		"dp.java rejects motion below its 0.15 threshold"
	)
	var wake: Array[Sprite3D] = FluidFx.spawn_boat_wake(world, ORIGIN, 0.0, Vector3(0.19, 0.0, 0.0))
	assert_eq(wake.size(), 13, "ceil(1 + 0.19*60) splash droplets")
	for splash: Sprite3D in wake:
		assert_eq(splash.global_position.y, ORIGIN.y - 0.125)
		assert_eq(int(splash.get("_kind")), AlphaWaterParticle.Kind.SPLASH)


func test_named_water_particles_obey_alphas_sixteen_block_visibility_sphere() -> void:
	var world := WaterWorld.new()
	add_child_autofree(world)
	var rejected: Array[Sprite3D] = FluidFx.spawn_water_bubble(
		world, ORIGIN, Vector3.ZERO, 4, ORIGIN + Vector3(16.01, 0.0, 0.0)
	)
	assert_true(rejected.is_empty())
	assert_eq(world.get_child_count(), 0)

	var accepted: Array[Sprite3D] = FluidFx.spawn_water_splash(
		world, ORIGIN, Vector3.ZERO, 1, ORIGIN + Vector3(16.0, 0.0, 0.0)
	)
	assert_eq(accepted.size(), 1)
