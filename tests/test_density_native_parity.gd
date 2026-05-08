extends GutTest

# Slice 3-D parity test: native build_density_terrain must produce
# byte-identical chunks vs the GDScript fallback for the same inputs.
# The native path is the production code; this test guards against
# silent algorithmic divergence between the two.


func before_each() -> void:
	BlockAtlas.reset()
	BlockAtlas.build()
	if Mesher._native_mesher == null:
		Mesher.enable_native()
	Worldgen.enable_native()
	Worldgen.apply_world_seed(12345)


func after_each() -> void:
	# Always restore default terrain mode so other test files aren't affected.
	Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_2D_HEIGHTMAP


# Generate the same chunk twice — once with native disabled, once
# enabled — and compare the resulting blocks. The terrain density,
# selector blend, Y-bias, and trilerp must all agree byte-for-byte.
func test_density_terrain_native_matches_gdscript() -> void:
	Worldgen.terrain_mode = Worldgen.TerrainMode.MODE_3D_DENSITY
	# GDScript path — temporarily nuke the cached native handle so
	# WorldgenDensity falls through to the GDScript trilerp.
	var saved_native: RefCounted = Worldgen._native_worldgen
	Worldgen._native_worldgen = null
	WorldgenDensity.reset()
	Worldgen.apply_world_seed(12345)
	var gds_chunk := Worldgen.generate_chunk(2, -3)
	# Native path — restore handle, reset noise caches so seed reapplies.
	Worldgen._native_worldgen = saved_native
	WorldgenDensity.reset()
	Worldgen.apply_world_seed(12345)
	var nat_chunk := Worldgen.generate_chunk(2, -3)
	assert_eq(
		nat_chunk.blocks,
		gds_chunk.blocks,
		"native build_density_terrain should match GDScript byte-for-byte"
	)
	assert_eq(nat_chunk.max_y, gds_chunk.max_y, "max_y should match")
