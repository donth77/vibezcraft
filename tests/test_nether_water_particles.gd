extends GutTest


class BrightWorld:
	extends Node3D

	func get_world_effective_light(_pos: Vector3i, _sky_subtraction: int = -1) -> int:
		return 15


const CELL := Vector3i(10, 20, 30)


func test_nether_water_evaporation_spawns_eight_source_largesmoke_motes() -> void:
	var world := BrightWorld.new()
	add_child_autofree(world)

	FluidFx.spawn_nether_water_evaporation(world, CELL)

	assert_eq(world.get_child_count(), 8, "ag.java creates exactly eight largesmoke motes")
	for child: Node in world.get_children():
		var smoke := child as Sprite3D
		assert_not_null(smoke, "each puff has an individual pi.java lifecycle")
		assert_gte(smoke.global_position.x, 10.0)
		assert_lt(smoke.global_position.x, 11.0)
		assert_gte(smoke.global_position.y, 20.0)
		assert_lt(smoke.global_position.y, 21.0)
		assert_gte(smoke.global_position.z, 30.0)
		assert_lt(smoke.global_position.z, 31.0)
		assert_eq(
			(smoke.texture as AtlasTexture).region,
			Rect2(56, 0, 8, 8),
			"largesmoke starts on pi.java frame 7"
		)
		assert_eq(smoke.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST)
		assert_between(int(smoke.get("_max_age_ticks")), 20, 100, "2.5x lifetime")
		assert_between(float(smoke.get("_base_scale")), 1.875, 3.75, "2.5x scale")


func test_largesmoke_uses_the_eight_real_atlas_frames_in_reverse_order() -> void:
	var world := BrightWorld.new()
	add_child_autofree(world)
	var smoke := FluidFx.spawn_largesmoke_particle(world, Vector3(CELL) + Vector3.ONE * 0.5)
	smoke.set("_max_age_ticks", 20)

	smoke.call("_process", 0.25)

	assert_eq(
		(smoke.texture as AtlasTexture).region,
		Rect2(40, 0, 8, 8),
		"after five of twenty ticks pi.java has stepped from frame 7 to frame 5"
	)


func test_lava_solidification_uses_eight_largesmoke_above_each_cell() -> void:
	var world := BrightWorld.new()
	add_child_autofree(world)

	FluidFx.spawn_fizz(world, CELL)

	assert_eq(world.get_child_count(), 8, "ld.java creates eight motes per conversion")
	for child: Node in world.get_children():
		var smoke := child as Sprite3D
		assert_gte(smoke.global_position.x, 10.0)
		assert_lt(smoke.global_position.x, 11.0)
		assert_almost_eq(smoke.global_position.y, 21.2, 0.0001, "fixed y + 1.2 origin")
		assert_gte(smoke.global_position.z, 30.0)
		assert_lt(smoke.global_position.z, 31.0)
		assert_eq((smoke.texture as AtlasTexture).region, Rect2(56, 0, 8, 8))


func test_batched_lava_conversions_keep_eight_particles_per_cell() -> void:
	var world := BrightWorld.new()
	add_child_autofree(world)
	var second := Vector3i(20, 25, 40)

	FluidFx.spawn_fizz_cluster(world, [CELL, second])

	assert_eq(world.get_child_count(), 16, "batching does not merge or cap Alpha's puffs")
	var first_count: int = 0
	var second_count: int = 0
	for child: Node in world.get_children():
		var p: Vector3 = (child as Node3D).global_position
		if p.x >= float(CELL.x) and p.x < float(CELL.x + 1):
			first_count += 1
			assert_almost_eq(p.y, float(CELL.y) + 1.2, 0.0001)
		elif p.x >= float(second.x) and p.x < float(second.x + 1):
			second_count += 1
			assert_almost_eq(p.y, float(second.y) + 1.2, 0.0001)
	assert_eq(first_count, 8)
	assert_eq(second_count, 8)


func test_bucket_evaporation_routes_around_the_gpu_fizz_emitter() -> void:
	var interaction: GDScript = load("res://scripts/player/interaction.gd") as GDScript
	assert_true(
		interaction.source_code.contains("FluidFx.spawn_nether_water_evaporation"),
		"the Nether bucket branch uses the source-sized Sprite3D smoke path"
	)
