extends GutTest


class CountingLightManager:
	extends Node
	var effective_light: int = 0
	var sample_count: int = 0
	var last_pos := Vector3i(999, 999, 999)

	func get_world_effective_light(pos: Vector3i, _sky_subtraction: int = -1) -> int:
		sample_count += 1
		last_pos = pos
		return effective_light


func test_particle_emitter_uses_one_lut_sample_without_material_allocation() -> void:
	var manager := CountingLightManager.new()
	add_child_autofree(manager)
	var particles := CPUParticles3D.new()
	autofree(particles)
	manager.effective_light = 7
	var sample_pos := Vector3i(12, 34, -9)

	var brightness: float = BlockFx._apply_voxel_light(particles, manager, sample_pos)

	var expected: float = EntityLighting.brightness_for_level(7)
	assert_almost_eq(brightness, expected, 0.0001)
	assert_almost_eq(particles.color.r, expected, 0.0001)
	assert_almost_eq(particles.color.g, expected, 0.0001)
	assert_almost_eq(particles.color.b, expected, 0.0001)
	assert_eq(particles.color.a, 1.0)
	assert_eq(manager.sample_count, 1, "one light query colors the entire burst")
	assert_eq(manager.last_pos, sample_pos)


func test_particle_light_does_not_mutate_shared_block_material() -> void:
	var manager := CountingLightManager.new()
	add_child_autofree(manager)
	var dark_particles := CPUParticles3D.new()
	var bright_particles := CPUParticles3D.new()
	autofree(dark_particles)
	autofree(bright_particles)
	var material: StandardMaterial3D = BlockFx.get_material(Blocks.STONE)
	var base_color: Color = material.albedo_color
	assert_true(
		material.vertex_color_use_as_albedo,
		"particle material must consume the emitter's voxel-light color"
	)

	manager.effective_light = 0
	BlockFx._apply_voxel_light(dark_particles, manager, Vector3i.ZERO)
	manager.effective_light = 15
	BlockFx._apply_voxel_light(bright_particles, manager, Vector3i.ZERO)

	assert_almost_eq(dark_particles.color.r, EntityLighting.brightness_for_level(0), 0.0001)
	assert_eq(bright_particles.color, Color.WHITE)
	assert_eq(
		material.albedo_color,
		base_color,
		"concurrent bursts retain independent light without touching the cached material"
	)
	assert_eq(base_color, Color(0.6, 0.6, 0.6, 1.0), "canonical digging tint is preserved")
