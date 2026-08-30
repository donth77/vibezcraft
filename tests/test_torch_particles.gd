extends GutTest


class BrightWorld:
	extends Node3D

	func get_world_effective_light(_pos: Vector3i, _sky_subtraction: int = -1) -> int:
		return 15

	func get_world_block_meta(_pos: Vector3i) -> int:
		return Redstone.MOUNT_FLOOR


const CELL := Vector3i(10, 20, 30)


func test_particle_origins_match_block_torch_random_display_tick() -> void:
	var expected: Dictionary = {
		0: Vector3(10.5, 20.7, 30.5),
		Redstone.MOUNT_FLOOR: Vector3(10.5, 20.7, 30.5),
		Redstone.MOUNT_WEST_WALL: Vector3(10.23, 20.92, 30.5),
		Redstone.MOUNT_EAST_WALL: Vector3(10.77, 20.92, 30.5),
		Redstone.MOUNT_NORTH_WALL: Vector3(10.5, 20.92, 30.23),
		Redstone.MOUNT_SOUTH_WALL: Vector3(10.5, 20.92, 30.77),
	}
	for meta: int in expected:
		assert_eq(
			FluidFx.torch_particle_origin(CELL, meta),
			expected[meta],
			"metadata %d uses ob.java's exact smoke/flame origin" % meta
		)


func test_each_display_tick_spawns_one_smoke_then_one_flame() -> void:
	var world := BrightWorld.new()
	add_child_autofree(world)
	var origin: Vector3 = FluidFx.torch_particle_origin(CELL, Redstone.MOUNT_NORTH_WALL)

	FluidFx.spawn_torch_particles(world, CELL, Redstone.MOUNT_NORTH_WALL)

	assert_eq(world.get_child_count(), 2, "one smoke plus one flame")
	var smoke := world.get_child(0) as Sprite3D
	var flame := world.get_child(1) as Sprite3D
	assert_not_null(smoke, "smoke is a source-style billboard")
	assert_not_null(flame, "flame is a source-style billboard")
	assert_eq(smoke.global_position, origin, "smoke starts at the torch origin")
	assert_eq(flame.global_position, origin, "flame starts at the same origin")
	assert_eq((smoke.texture as AtlasTexture).region, Rect2(56, 0, 8, 8), "smoke starts at tile 7")
	assert_eq((flame.texture as AtlasTexture).region, Rect2(0, 24, 8, 8), "flame stays on tile 48")
	assert_eq(smoke.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST)
	assert_eq(flame.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST)


func test_display_particles_obey_alphas_sixteen_block_visibility_limit() -> void:
	var world := BrightWorld.new()
	add_child_autofree(world)
	var origin: Vector3 = FluidFx.torch_particle_origin(CELL, Redstone.MOUNT_FLOOR)

	AmbientFx._torch(world, CELL.x, CELL.y, CELL.z, origin + Vector3(16.01, 0.0, 0.0))
	assert_eq(world.get_child_count(), 0, "f.java rejects a distant pair")
	AmbientFx._torch(world, CELL.x, CELL.y, CELL.z, origin + Vector3(16.0, 0.0, 0.0))
	assert_eq(world.get_child_count(), 2, "a selected visible torch emits exactly one pair")


func test_wall_particle_origins_sit_directly_over_the_rendered_heads() -> void:
	var expected_heads: Dictionary = {
		Redstone.MOUNT_WEST_WALL: Vector3(10.25, 20.825, 30.5),
		Redstone.MOUNT_EAST_WALL: Vector3(10.75, 20.825, 30.5),
		Redstone.MOUNT_NORTH_WALL: Vector3(10.5, 20.825, 30.25),
		Redstone.MOUNT_SOUTH_WALL: Vector3(10.5, 20.825, 30.75),
	}
	for meta: int in expected_heads:
		var chunk := Chunk.new()
		chunk.set_block(CELL.x & 15, CELL.y, CELL.z & 15, Blocks.TORCH)
		chunk.set_block_meta(CELL.x & 15, CELL.y, CELL.z & 15, meta)
		var vertices: PackedVector3Array = Mesher.mesh_chunk(chunk).vertices
		# _emit_torch_box emits its top face second, at vertices 4..7.
		var head_center := Vector3.ZERO
		for i in range(4, 8):
			head_center += vertices[i]
		head_center /= 4.0
		# Chunk-local X/Z need the world chunk origin added back for CELL.z=30.
		head_center += Vector3(CELL.x & ~15, 0.0, CELL.z & ~15)
		assert_eq(head_center, expected_heads[meta], "rendered head follows bk.java")
		var particle: Vector3 = FluidFx.torch_particle_origin(CELL, meta)
		assert_lt(
			Vector2(particle.x - head_center.x, particle.z - head_center.z).length(),
			0.021,
			"particle stays horizontally over the head"
		)
		assert_almost_eq(particle.y - head_center.y, 0.095, 0.001, "sprite overlaps tip")


func test_particle_lifetimes_and_base_sizes_follow_the_source_ranges() -> void:
	var world := BrightWorld.new()
	add_child_autofree(world)
	FluidFx.spawn_torch_particles(world, CELL, Redstone.MOUNT_FLOOR)
	var smoke: Sprite3D = world.get_child(0) as Sprite3D
	var flame: Sprite3D = world.get_child(1) as Sprite3D

	assert_between(int(smoke.get("_max_age_ticks")), 8, 40, "pi.java smoke lifetime")
	assert_between(int(flame.get("_max_age_ticks")), 12, 44, "ko.java flame lifetime")
	assert_between(float(smoke.get("_base_scale")), 0.75, 1.5, "smoke scale range")
	assert_between(float(flame.get("_base_scale")), 1.0, 2.0, "flame scale range")
	assert_almost_eq(smoke.pixel_size * 8.0, 0.2, 0.0001, "pp.java base quad width")
	assert_almost_eq(flame.pixel_size * 8.0, 0.2, 0.0001, "pp.java base quad width")
