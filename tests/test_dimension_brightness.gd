extends GutTest

# Per-dimension brightness floor — the single term vanilla's light LUT
# varies between the Overworld and the Nether, and the one this project
# carried on WorldProvider without ever pushing to the renderer.


func test_the_ambient_floor_is_per_dimension() -> void:
	# The one term vanilla's brightness LUT varies by dimension:
	# oz.java:23 = 0.05 (Overworld), om.java:21 = 0.1 (Nether). The
	# Nether has no sky channel, so most of it sits at the low end of
	# the curve where halving the floor is most visible — that was the
	# harsh light/dark staggering from playtest.
	var overworld: WorldProvider = DimensionContext.provider(DimensionContext.OVERWORLD)
	var nether: WorldProvider = DimensionContext.provider(DimensionContext.NETHER)
	assert_almost_eq(overworld.ambient_light_floor, 0.05, 0.0001, "oz.java:23")
	assert_almost_eq(nether.ambient_light_floor, 0.1, 0.0001, "om.java:21")
	# Level 0 renders AT the floor; level 15 saturates regardless of it.
	assert_almost_eq(overworld.brightness(0), 0.05, 0.0001, "unlit Overworld cell")
	assert_almost_eq(nether.brightness(0), 0.1, 0.0001, "unlit Nether cell is twice as bright")
	assert_almost_eq(overworld.brightness(15), 1.0, 0.0001, "full light saturates")
	assert_almost_eq(nether.brightness(15), 1.0, 0.0001, "full light saturates in both")


func test_entity_lighting_tracks_the_active_dimensions_floor() -> void:
	# Entities and the blocks under them must share one curve, or a mob
	# reads as lit differently from the floor it stands on. EntityLighting
	# was pinned to the Overworld floor while the terrain shader got the
	# dimension's own — a ghast crossing from lava-light into shadow swung
	# twice as far as vanilla.
	var was: float = EntityLighting.brightness_for_level(0)
	EntityLighting.set_ambient_floor(0.1)
	assert_almost_eq(EntityLighting.brightness_for_level(0), 0.1, 0.0001, "adopts the Nether floor")
	assert_almost_eq(
		EntityLighting.brightness_for_level(15), 1.0, 0.0001, "full light still saturates"
	)
	EntityLighting.set_ambient_floor(0.05)
	assert_almost_eq(
		EntityLighting.brightness_for_level(0), 0.05, 0.0001, "and back to the Overworld floor"
	)
	assert_almost_eq(EntityLighting.brightness_for_level(0), was, 0.0001, "restored")


func test_the_chunk_shader_exposes_the_ambient_floor_uniform() -> void:
	# The bug class this guards: the floor existed on WorldProvider for
	# the whole Nether build and NOTHING pushed it to the renderer, so
	# the value was right in the model and wrong on screen. A uniform
	# that is missing from the compiled shader makes set_shader_parameter
	# a silent no-op, which looks exactly like "the fix did nothing".
	BlockAtlas.reset()
	BlockAtlas.build()
	var mat: ShaderMaterial = BlockAtlas.material()
	assert_not_null(mat, "shared terrain material exists")
	var names: Array = []
	for u: Dictionary in mat.shader.get_shader_uniform_list():
		names.append(u["name"])
	assert_true(names.has("ambient_floor"), "the shader declares ambient_floor")
	assert_true(names.has("sky_subtraction"), "and still declares sky_subtraction")


func test_the_driver_pushes_the_active_dimensions_floor_to_the_renderer() -> void:
	BlockAtlas.reset()
	BlockAtlas.build()
	var was: int = DimensionContext.active()
	var driver: Node = load("res://scripts/world/day_night_driver.gd").new()
	add_child_autofree(driver)
	DimensionContext.set_active(DimensionContext.NETHER)
	driver.call("_push_ambient_floor")
	assert_almost_eq(
		float(BlockAtlas.material().get_shader_parameter("ambient_floor")),
		0.1,
		0.0001,
		"terrain gets the Nether floor"
	)
	assert_almost_eq(
		EntityLighting.brightness_for_level(0), 0.1, 0.0001, "and entities get the same one"
	)
	DimensionContext.set_active(DimensionContext.OVERWORLD)
	driver.call("_push_ambient_floor")
	assert_almost_eq(
		float(BlockAtlas.material().get_shader_parameter("ambient_floor")),
		0.05,
		0.0001,
		"and back to the Overworld floor on return"
	)
	assert_almost_eq(EntityLighting.brightness_for_level(0), 0.05, 0.0001, "entities follow")
	DimensionContext.set_active(was)
