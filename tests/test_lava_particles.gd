extends GutTest


class BrightWorld:
	extends Node3D

	func get_world_effective_light(_pos: Vector3i, _sky_subtraction: int = -1) -> int:
		return 15

	func get_world_block(_pos: Vector3i) -> int:
		return Blocks.AIR

	func get_chunk_at_coord(_coord: Vector2i):
		return null


const CELL := Vector3i(10, 20, 30)
const SURFACE_CENTER := Vector3(10.5, 21.0, 30.5)


func test_origin_covers_the_full_exposed_lava_surface() -> void:
	for _i in range(128):
		var origin: Vector3 = FluidFx.lava_particle_origin(CELL)
		assert_gte(origin.x, 10.0, "ld.java starts inside the cell")
		assert_lt(origin.x, 11.0, "the X roll stays below the far edge")
		assert_eq(origin.y, 21.0, "the popper starts exactly at the block top")
		assert_gte(origin.z, 30.0, "ld.java starts inside the cell")
		assert_lt(origin.z, 31.0, "the Z roll stays below the far edge")


func test_spawn_uses_entity_lava_fx_sprite_and_source_ranges() -> void:
	var world := BrightWorld.new()
	add_child_autofree(world)
	var spark: Sprite3D = FluidFx.spawn_lava_spark(world, CELL, SURFACE_CENTER)

	assert_not_null(spark)
	assert_eq(world.get_child_count(), 1, "no fixed surface smoke burst")
	assert_eq(spark.get_class(), "Sprite3D", "the popper has a per-tick entity lifecycle")
	var atlas := spark.texture as AtlasTexture
	assert_not_null(atlas)
	assert_eq(atlas.region, Rect2(8, 24, 8, 8), "db.java uses particles tile 49")
	assert_eq(spark.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST)
	assert_almost_eq(spark.pixel_size * 8.0, 0.2, 0.0001, "pp.java's base quad width")
	assert_eq(spark.modulate, Color.WHITE, "lava poppers are fullbright")
	assert_between(int(spark.get("_max_age_ticks")), 16, 80, "db.java lifetime")
	assert_between(float(spark.get("_base_scale")), 0.2, 4.4, "db.java scale")
	var motion: Vector3 = spark.get("_motion_per_tick") as Vector3
	assert_between(motion.y, 0.05, 0.45, "db.java replaces inherited Y motion")


func test_first_tick_applies_gravity_before_movement_and_then_drag() -> void:
	var world := BrightWorld.new()
	add_child_autofree(world)
	var spark: Sprite3D = FluidFx.spawn_lava_spark(world, CELL, SURFACE_CENTER)
	var origin: Vector3 = spark.get("_current_position") as Vector3
	var initial_motion: Vector3 = spark.get("_motion_per_tick") as Vector3
	var moved := Vector3(initial_motion.x, initial_motion.y - 0.03, initial_motion.z)

	spark.call("_process", 0.05)

	assert_eq(
		spark.get("_current_position") as Vector3,
		origin + moved,
		"db.java subtracts 0.03 before moving"
	)
	assert_eq(
		spark.get("_motion_per_tick") as Vector3,
		moved * 0.999,
		"all three axes retain db.java's 0.999 drag"
	)


func test_lava_smoke_is_an_ordinary_animated_smoke_mote_on_the_arc() -> void:
	var world := BrightWorld.new()
	add_child_autofree(world)
	var spark: Sprite3D = FluidFx.spawn_lava_spark(world, CELL, SURFACE_CENTER)
	var trail_point := Vector3(10.25, 22.75, 30.8)
	spark.set("_current_position", trail_point)

	spark.call("_spawn_smoke")

	assert_eq(world.get_child_count(), 2, "one successful roll creates one smoke mote")
	var smoke := world.get_child(1) as Sprite3D
	assert_not_null(smoke)
	assert_eq(smoke.global_position, trail_point, "smoke starts at the popper's current point")
	assert_eq(
		(smoke.texture as AtlasTexture).region,
		Rect2(56, 0, 8, 8),
		"pi.java smoke starts on frame 7"
	)
	assert_between(int(smoke.get("_max_age_ticks")), 8, 40, "ordinary smoke lifetime")
	assert_between(float(smoke.get("_base_scale")), 0.75, 1.5, "ordinary smoke scale")


func test_initial_and_child_particles_obey_alphas_visibility_sphere() -> void:
	var world := BrightWorld.new()
	add_child_autofree(world)
	var far_viewer := SURFACE_CENTER + Vector3(17.0, 0.0, 0.0)
	var rejected: Sprite3D = FluidFx.spawn_lava_spark(world, CELL, far_viewer)
	assert_null(rejected)
	assert_eq(world.get_child_count(), 0, "f.java rejects the initial distant popper")

	var spark: Sprite3D = FluidFx.spawn_lava_spark(world, CELL, SURFACE_CENTER)
	assert_not_null(spark)
	var point: Vector3 = spark.get("_current_position") as Vector3
	spark.set("_viewer_position", point + Vector3(16.01, 0.0, 0.0))
	spark.call("_spawn_smoke")
	assert_eq(world.get_child_count(), 1, "f.java also rejects a distant child smoke request")
