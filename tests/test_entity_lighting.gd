extends GutTest


class RawLightManager:
	extends Node
	var sky: int = 0
	var block: int = 0

	func get_world_sky_light(_pos: Vector3i) -> int:
		return sky

	func get_world_block_light(_pos: Vector3i) -> int:
		return block


class EffectiveLightManager:
	extends RawLightManager
	var effective: int = 0
	var last_sampled_cell := Vector3i.ZERO

	func get_world_effective_light(pos: Vector3i, _sky_subtraction: int = -1) -> int:
		last_sampled_cell = pos
		return effective


func before_each() -> void:
	WorldTime.set_time_ticks(6000)


func test_brightness_lut_uses_alpha_floor_and_endpoints() -> void:
	assert_almost_eq(EntityLighting.brightness_for_level(0), 0.05, 0.0001)
	assert_almost_eq(EntityLighting.brightness_for_level(15), 1.0, 0.0001)
	assert_eq(
		EntityLighting.brightness_for_level(-20),
		EntityLighting.brightness_for_level(0),
		"levels clamp below zero"
	)
	assert_eq(
		EntityLighting.brightness_for_level(99),
		EntityLighting.brightness_for_level(15),
		"levels clamp above fifteen"
	)


func test_sample_brightness_uses_manager_effective_light_contract() -> void:
	var manager := EffectiveLightManager.new()
	autofree(manager)
	manager.sky = 15
	manager.block = 15
	manager.effective = 0
	assert_almost_eq(
		EntityLighting.sample_brightness(manager, Vector3i.ZERO),
		EntityLighting.brightness_for_level(0),
		0.0001
	)
	manager.effective = 15
	assert_almost_eq(EntityLighting.sample_brightness(manager, Vector3i.ZERO), 1.0, 0.0001)


func test_sample_brightness_fallback_uses_integer_sky_subtraction() -> void:
	var manager := RawLightManager.new()
	autofree(manager)
	manager.sky = 15
	manager.block = 0
	WorldTime.set_time_ticks(18000)
	assert_almost_eq(
		EntityLighting.sample_brightness(manager, Vector3i.ZERO),
		EntityLighting.brightness_for_level(4),
		0.0001
	)
	manager.block = 12
	assert_almost_eq(
		EntityLighting.sample_brightness(manager, Vector3i.ZERO),
		EntityLighting.brightness_for_level(12),
		0.0001,
		"block light is not attenuated by time"
	)


func test_pigman_samples_at_alpha_source_height_and_tints_every_material() -> void:
	# `lw.java::a(float)` samples at 66% of the entity bounding-box
	# height. This fractional position distinguishes it from the old
	# body-centre sample: 64.8 + 1.95*0.66 floors to 66, while *0.5
	# floors to 65.
	var manager := EffectiveLightManager.new()
	add_child_autofree(manager)
	manager.effective = 0
	var floor_was: float = EntityLighting.brightness_for_level(0)
	EntityLighting.set_ambient_floor(0.1)
	var pigman: Node = MobRegistry.script_for("zombie_pigman").new()
	add_child_autofree(pigman)
	(pigman as Node3D).global_position = Vector3(2.25, 64.8, -3.25)
	pigman.set("_chunk_manager", manager)
	pigman.call("_tick_world_brightness")

	assert_eq(manager.last_sampled_cell, Vector3i(2, 66, -4), "uses the source 0.66 sample")
	var expected_bucket := int(round(EntityLighting.brightness_for_level(0) * 31.0))
	var expected_tint := float(expected_bucket) / 31.0
	var head_mat := (
		(pigman.get("_head_mesh") as MeshInstance3D).material_override as StandardMaterial3D
	)
	var sword_mat := (
		(pigman.get("_sword_mesh") as MeshInstance3D).material_override as StandardMaterial3D
	)
	assert_almost_eq(head_mat.albedo_color.r, expected_tint, 0.0001, "body follows Nether light")
	assert_almost_eq(sword_mat.albedo_color.r, expected_tint, 0.0001, "held sword follows it too")
	EntityLighting.set_ambient_floor(floor_was)


func test_runtime_material_replacement_can_reapply_the_current_mob_light() -> void:
	var manager := EffectiveLightManager.new()
	add_child_autofree(manager)
	manager.effective = 0
	var pigman: Node = MobRegistry.script_for("zombie_pigman").new()
	add_child_autofree(pigman)
	pigman.set("_chunk_manager", manager)
	pigman.call("_tick_world_brightness")
	var head := pigman.get("_head_mesh") as MeshInstance3D
	var replacement := MobBase.get_shared_material(ZombiePigman._TEXTURE_PATH, false)
	head.material_override = replacement

	pigman.call("_refresh_world_brightness")

	var expected_bucket := int(round(EntityLighting.brightness_for_level(0) * 31.0))
	var expected_tint := float(expected_bucket) / 31.0
	var relit := head.material_override as StandardMaterial3D
	assert_ne(relit, replacement, "a runtime swap does not bypass the cached light bucket")
	assert_almost_eq(relit.albedo_color.r, expected_tint, 0.0001)
