extends GutTest


func _source(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func test_terrain_uses_integer_sky_subtraction_contract() -> void:
	var source := _source("res://shaders/chunk_common.gdshaderinc")
	assert_true(source.contains("uniform float sky_subtraction"))
	assert_true(source.contains("v_light.x * 15.0 - sky_subtraction"))
	assert_false(source.contains("v_light.x * sky_factor"))


func test_opaque_terrain_gates_alpha_discard_away_from_msaa_edges() -> void:
	var source := _source("res://shaders/chunk_common.gdshaderinc")
	assert_true(source.contains("varying flat float v_alpha_test;"))
	assert_true(source.contains("v_alpha_test = COLOR.a;"))
	assert_true(source.contains("if (v_alpha_test > 0.5 && c.a < 0.5)"))
	assert_false(
		source.contains("if (c.a < 0.5)"),
		"opaque terrain must not discard an extrapolated atlas edge sample"
	)


func test_held_block_overlay_uses_the_same_msaa_safe_discard_gate() -> void:
	var source := _source("res://shaders/chunk_overlay.gdshader")
	assert_true(source.contains("varying flat float v_alpha_test;"))
	assert_true(source.contains("v_alpha_test = COLOR.a;"))
	assert_true(source.contains("if (v_alpha_test > 0.5 && c.a < 0.5)"))
	assert_false(source.contains("if (c.a < 0.5)"))


func test_water_is_unshaded_and_uses_alpha_brightness_lut() -> void:
	var source := _source("res://shaders/water.gdshader")
	assert_true(
		source.contains("render_mode cull_disabled, blend_mix, depth_draw_opaque, unshaded;")
	)
	assert_true(source.contains("v_sky * 15.0 - sky_subtraction"))
	assert_true(source.contains("float f2 = 0.05;"))
	assert_false(source.contains("mix(0.7, 1.0, light)"))


func test_lava_is_explicitly_unshaded_and_self_emissive() -> void:
	var source := _source("res://shaders/lava.gdshader")
	assert_true(source.contains("render_mode cull_back, depth_draw_opaque, unshaded;"))
	assert_true(source.contains("EMISSION = col * emission_strength;"))
	assert_false(source.contains("sky_factor"))


func test_day_night_driver_targets_only_light_consuming_materials() -> void:
	var source := _source("res://scripts/world/day_night_driver.gd")
	assert_true(source.contains('set_shader_parameter("sky_subtraction"'))
	assert_false(source.contains('lava_material().set_shader_parameter("sky_'))
