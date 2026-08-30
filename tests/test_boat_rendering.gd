extends GutTest

const _ALPHA_BOAT_PATH: String = "res://assets/textures/entities/packs/alpha_vanilla/boat.png"

var _previous_pack: String


func before_each() -> void:
	_previous_pack = BlockAtlas.active_pack


func after_each() -> void:
	BlockAtlas.active_pack = _previous_pack


func test_pixel_perfection_falls_back_to_textured_alpha_boat() -> void:
	BlockAtlas.active_pack = "pixel_perfection"
	var boat := Boat.new()
	autofree(boat)
	var texture: Texture2D = boat._load_boat_texture()

	assert_not_null(texture, "incomplete pack never produces an untextured hull")
	if texture == null:
		return
	assert_eq(texture.resource_path, _ALPHA_BOAT_PATH)
	assert_eq(texture.get_size(), Vector2(64, 32), "vanilla ModelBoat atlas dimensions")


func test_boat_material_receives_the_fallback_texture() -> void:
	BlockAtlas.active_pack = "pixel_perfection"
	var boat := Boat.new()
	autofree(boat)
	boat._build_visual_mesh()

	assert_not_null(boat._floor_mat)
	assert_not_null(boat._wall_mat)
	if boat._floor_mat != null and boat._wall_mat != null:
		assert_not_null(boat._floor_mat.albedo_texture, "floor is textured")
		assert_not_null(boat._wall_mat.albedo_texture, "walls are textured")
		assert_eq(boat._floor_mat.albedo_texture.resource_path, _ALPHA_BOAT_PATH)
		assert_eq(boat._wall_mat.albedo_texture.resource_path, _ALPHA_BOAT_PATH)
