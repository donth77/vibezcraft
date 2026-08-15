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

	func get_world_effective_light(_pos: Vector3i, _sky_subtraction: int = -1) -> int:
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
