extends GutTest


class EffectiveLightManager:
	extends Node
	var effective: int = 0

	func get_world_effective_light(_pos: Vector3i, _sky_subtraction: int = -1) -> int:
		return effective

	func get_world_sky_light(_pos: Vector3i) -> int:
		return effective

	func get_world_block_light(_pos: Vector3i) -> int:
		return 0


var _parent: Node3D
var _manager: EffectiveLightManager


func before_each() -> void:
	BlockAtlas.reset()
	BlockAtlas.build()
	WorldTime.set_time_ticks(6000)
	_parent = Node3D.new()
	add_child_autofree(_parent)
	_manager = EffectiveLightManager.new()
	add_child_autofree(_manager)


func _assert_instance_levels(mesh: MeshInstance3D, owner: Node, update_method: String) -> void:
	_manager.effective = 0
	owner.call(update_method)
	assert_almost_eq(
		float(mesh.get_instance_shader_parameter("entity_brightness")),
		EntityLighting.brightness_for_level(0),
		0.0001
	)
	_manager.effective = 15
	owner.set("_last_light_brightness", -1.0)
	owner.call(update_method)
	assert_almost_eq(float(mesh.get_instance_shader_parameter("entity_brightness")), 1.0, 0.0001)


func test_chest_body_and_lid_use_per_instance_light() -> void:
	var chest := ChestNode.new()
	_parent.add_child(chest)
	chest._chunk_manager = _manager
	chest._last_light_brightness = -1.0
	_assert_instance_levels(chest._body, chest, "_update_entity_lighting")
	assert_eq(
		chest._lid.get_instance_shader_parameter("entity_brightness"),
		chest._body.get_instance_shader_parameter("entity_brightness")
	)
	assert_eq(chest._body.material_override, BlockAtlas.entity_material())


func test_falling_block_uses_entity_material_and_instance_light() -> void:
	var falling := FallingBlock.new()
	_parent.add_child(falling)
	falling.setup(Blocks.SAND)
	falling._chunk_manager = _manager
	_assert_instance_levels(falling._mesh, falling, "_update_entity_lighting")
	assert_eq(falling._mesh.material_override, BlockAtlas.entity_material())


func test_primed_tnt_body_is_lit_but_flash_stays_private_fullbright() -> void:
	var tnt := PrimedTNT.new()
	_parent.add_child(tnt)
	tnt.setup()
	tnt._chunk_manager = _manager
	_assert_instance_levels(tnt._mesh, tnt, "_update_entity_lighting")
	var flash_mat := tnt._flash_mesh.material_override as StandardMaterial3D
	assert_eq(flash_mat.albedo_color, Color.WHITE)
	assert_eq(flash_mat.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)


func test_furnace_minecart_payload_uses_cart_light_without_mutating_shared_material() -> void:
	var cart := Minecart.new()
	cart.variant = Minecart.VARIANT_FURNACE
	_parent.add_child(cart)
	cart._chunk_manager = _manager
	_assert_instance_levels(cart._furnace_mi, cart, "_update_entity_lighting")
	assert_eq(cart._furnace_mi.material_override, BlockAtlas.entity_material())


func test_painting_duplicates_cached_front_material_before_tinting() -> void:
	var painting := Painting.new()
	_parent.add_child(painting)
	painting._chunk_manager = _manager
	var cached: StandardMaterial3D = Painting._get_variant_material(painting.variant)
	var cached_color: Color = cached.albedo_color
	_manager.effective = 0
	painting._last_light_brightness = -1.0
	painting._update_entity_lighting()
	assert_ne(painting._front_material, cached)
	assert_eq(cached.albedo_color, cached_color, "shared cached material remains immutable")
	assert_almost_eq(
		painting._front_material.albedo_color.r,
		painting._front_base_color.r * EntityLighting.brightness_for_level(0),
		0.0001
	)


func test_arrow_private_materials_follow_voxel_light() -> void:
	var arrow := Arrow.new()
	_parent.add_child(arrow)
	arrow._chunk_manager = _manager
	assert_false(arrow._light_materials.is_empty())
	_manager.effective = 0
	arrow._last_light_brightness = -1.0
	arrow._update_entity_lighting()
	var entry: Array = arrow._light_materials[0]
	var material: StandardMaterial3D = entry[0]
	var base: Color = entry[1]
	assert_almost_eq(
		material.albedo_color.r, base.r * EntityLighting.brightness_for_level(0), 0.0001
	)


func test_snowball_and_bobber_sprite_modulation_follow_voxel_light() -> void:
	var snowball := SnowballProjectile.new()
	_parent.add_child(snowball)
	snowball._chunk_manager = _manager
	_manager.effective = 0
	snowball._last_light_brightness = -1.0
	snowball._update_entity_lighting()
	assert_almost_eq(snowball._sprite.modulate.r, EntityLighting.brightness_for_level(0), 0.0001)

	var bobber := FishingBobber.new()
	_parent.add_child(bobber)
	bobber.setup(null, _manager, Vector3.ZERO, Vector3.FORWARD)
	bobber._last_light_brightness = -1.0
	bobber._update_entity_lighting()
	assert_almost_eq(bobber._sprite.modulate.r, EntityLighting.brightness_for_level(0), 0.0001)
	assert_false(bobber._sprite.shaded)
