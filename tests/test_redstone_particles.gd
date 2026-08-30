extends GutTest

const _RED_DUST_SCRIPT: GDScript = preload("res://scripts/world/alpha_reddust_particle.gd")
const _TORCH_PARTICLE_SCRIPT: GDScript = preload("res://scripts/world/alpha_torch_particle.gd")
const CELL := Vector3i(10, 20, 30)


class ParticleWorld:
	extends Node3D
	var blocks: Dictionary = {}
	var metas: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func get_world_effective_light(_pos: Vector3i, _sky_subtraction: int = -1) -> int:
		return 15

	func get_chunk_at_coord(_coord: Vector2i):
		return null


func _world() -> ParticleWorld:
	var world := ParticleWorld.new()
	add_child_autofree(world)
	return world


func test_reddust_uses_alpha_atlas_color_scale_lifetime_and_motion() -> void:
	seed(126)
	var world := _world()
	var origin := Vector3(CELL) + Vector3(0.5, 0.7, 0.5)
	var particle := BlockFx.spawn_reddust_at(world, origin)

	assert_not_null(particle)
	if particle == null:
		return
	assert_eq(particle.get_script(), _RED_DUST_SCRIPT)
	assert_eq(particle.global_position, origin)
	assert_eq((particle.texture as AtlasTexture).region, Rect2(56, 0, 8, 8))
	assert_eq(particle.texture_filter, BaseMaterial3D.TEXTURE_FILTER_NEAREST)
	assert_almost_eq(particle.pixel_size * 8.0, 0.2, 0.0001)
	assert_between(int(particle.get("_max_age_ticks")), 8, 40, "fh.java lifetime")
	assert_between(float(particle.get("_base_scale")), 0.75, 1.5, "fh.java scale")
	var color: Color = particle.get("_base_color") as Color
	assert_between(color.r, 0.7, 1.0, "red channel")
	assert_between(color.g, 0.0, 0.1, "green channel")
	assert_eq(color.g, color.b, "green and blue share one source roll")
	assert_gt((particle.get("_motion_per_tick") as Vector3).length(), 0.0)
	assert_eq(particle.scale, Vector3.ZERO, "fh.java starts its 1/32-life growth at zero")

	particle.call("_process", 0.05)
	assert_gt(particle.scale.x, 0.0, "first Alpha tick grows the sprite")
	var frame_region: Rect2 = (particle.texture as AtlasTexture).region
	assert_eq(frame_region.position.y, 0.0)
	assert_between(frame_region.position.x, 0.0, 56.0, "frame remains in smoke row 7..0")


func test_lit_redstone_torch_emits_one_jittered_dust_at_its_head() -> void:
	seed(127)
	var world := _world()
	world.blocks[CELL] = Blocks.REDSTONE_TORCH
	world.metas[CELL] = Redstone.MOUNT_NORTH_WALL
	var center: Vector3 = FluidFx.torch_particle_origin(CELL, Redstone.MOUNT_NORTH_WALL)

	AmbientFx._redstone_torch(world, CELL.x, CELL.y, CELL.z, center)

	assert_eq(world.get_child_count(), 1, "one reddust mote, not smoke/flame")
	var particle := world.get_child(0) as Sprite3D
	assert_not_null(particle)
	if particle != null:
		assert_eq(particle.get_script(), _RED_DUST_SCRIPT)
		assert_true(_inside_jitter_box(particle.global_position, center, Vector3.ONE * 0.1))


func test_redstone_torch_and_repeater_obey_sixteen_block_limit() -> void:
	var torch_world := _world()
	torch_world.metas[CELL] = Redstone.MOUNT_FLOOR
	var torch_center := FluidFx.torch_particle_origin(CELL, Redstone.MOUNT_FLOOR)
	AmbientFx._redstone_torch(
		torch_world, CELL.x, CELL.y, CELL.z, torch_center + Vector3(16.2, 0.0, 0.0)
	)
	assert_eq(torch_world.get_child_count(), 0, "distant torch dust rejected")

	var repeater_world := _world()
	repeater_world.metas[CELL] = 0
	var repeater_center := Vector3(CELL) + Vector3(0.5, 0.4, 0.5)
	(
		AmbientFx
		. _repeater(
			repeater_world,
			CELL.x,
			CELL.y,
			CELL.z,
			repeater_center + Vector3(16.6, 0.0, 0.0),
		)
	)
	assert_eq(repeater_world.get_child_count(), 0, "distant repeater dust rejected")


func test_powered_wire_emits_at_one_sixteenth_with_xz_jitter_only() -> void:
	seed(128)
	var world := _world()
	world.blocks[CELL] = Blocks.REDSTONE_WIRE
	world.metas[CELL] = 0
	var center := Vector3(CELL) + Vector3(0.5, 0.0625, 0.5)

	AmbientFx._redstone_wire(world, CELL.x, CELL.y, CELL.z, center)
	assert_eq(world.get_child_count(), 0, "unpowered wire emits nothing")
	world.metas[CELL] = 15
	AmbientFx._redstone_wire(world, CELL.x, CELL.y, CELL.z, center)

	assert_eq(world.get_child_count(), 1, "powered wire emits one mote")
	var particle := world.get_child(0) as Sprite3D
	assert_not_null(particle)
	if particle != null:
		assert_almost_eq(particle.global_position.y, center.y, 0.00001, "wire Y never jitters")
		assert_true(
			_inside_jitter_box(
				particle.global_position,
				center,
				Vector3(0.1, 0.00001, 0.1),
			)
		)


func test_powered_repeater_chooses_one_of_its_two_torch_tips() -> void:
	seed(129)
	var world := _world()
	var meta: int = 1 | (2 << 2)
	world.blocks[CELL] = Blocks.REDSTONE_REPEATER_ON
	world.metas[CELL] = meta
	var output := Vector3(Redstone.repeater_output_offset(meta))
	var base := Vector3(CELL) + Vector3(0.5, 0.4, 0.5)
	var fixed_center: Vector3 = base + output * 0.3125
	var delay_center: Vector3 = base - output * Redstone.repeater_torch_offset(meta)

	AmbientFx._repeater(world, CELL.x, CELL.y, CELL.z, base)

	assert_eq(world.get_child_count(), 1)
	var particle := world.get_child(0) as Sprite3D
	assert_not_null(particle)
	if particle != null:
		var at_fixed := _inside_jitter_box(
			particle.global_position, fixed_center, Vector3.ONE * 0.1
		)
		var at_delay := _inside_jitter_box(
			particle.global_position, delay_center, Vector3.ONE * 0.1
		)
		assert_true(at_fixed or at_delay, "mote belongs to one rendered miniature torch")
		var color: Color = particle.get("_base_color") as Color
		assert_between(color.r, 0.48, 1.0, "Beta constructor's randomized pure red")
		assert_eq(color.g, 0.0)
		assert_eq(color.b, 0.0)


func test_redstone_torch_burnout_uses_five_real_smoke_particles() -> void:
	seed(130)
	var world := _world()
	var viewer := Vector3(CELL) + Vector3(0.5, 0.5, 0.5)
	var particles: Array[Sprite3D] = FluidFx.spawn_redstone_torch_burnout_smoke(world, CELL, viewer)

	assert_eq(particles.size(), 5)
	assert_eq(world.get_child_count(), 5)
	for particle: Sprite3D in particles:
		assert_eq(particle.get_script(), _TORCH_PARTICLE_SCRIPT)
		assert_eq(int(particle.get("_kind")), 1, "ordinary smoke, never reddust")
		assert_eq((particle.texture as AtlasTexture).region, Rect2(56, 0, 8, 8))
		var local: Vector3 = particle.global_position - Vector3(CELL)
		assert_between(local.x, 0.2, 0.8)
		assert_between(local.y, 0.2, 0.8)
		assert_between(local.z, 0.2, 0.8)


func test_ore_dust_uses_exact_one_sixteenth_face_offset() -> void:
	seed(131)
	var world := _world()
	var particle := BlockFx.spawn_reddust(world, CELL, Vector3.UP)

	assert_not_null(particle)
	if particle == null:
		return
	assert_almost_eq(particle.global_position.y, float(CELL.y + 1) + 0.0625, 0.00001)
	assert_between(particle.global_position.x, float(CELL.x), float(CELL.x + 1))
	assert_between(particle.global_position.z, float(CELL.z), float(CELL.z + 1))


func _inside_jitter_box(point: Vector3, center: Vector3, extents: Vector3) -> bool:
	var delta: Vector3 = (point - center).abs()
	return delta.x <= extents.x and delta.y <= extents.y and delta.z <= extents.z
