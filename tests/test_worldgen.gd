extends GutTest


func test_surface_height_is_deterministic() -> void:
	var h1 := Worldgen.surface_height(42, 17)
	var h2 := Worldgen.surface_height(42, 17)
	assert_eq(h1, h2, "same coord gives same height")


func test_surface_height_in_expected_range() -> void:
	for x in range(0, 64, 8):
		for z in range(0, 64, 8):
			var h := Worldgen.surface_height(x, z)
			var min_h := Worldgen.SEA_LEVEL - Worldgen.HEIGHT_AMPLITUDE
			var max_h := Worldgen.SEA_LEVEL + Worldgen.HEIGHT_AMPLITUDE
			assert_between(
				h, min_h, max_h, "height (%d,%d)=%d in [%d,%d]" % [x, z, h, min_h, max_h]
			)


func test_generate_chunk_is_deterministic() -> void:
	var c1 := Worldgen.generate_chunk(0, 0)
	var c2 := Worldgen.generate_chunk(0, 0)
	assert_eq(c1.blocks, c2.blocks, "same chunk coord gives same blocks")


func test_chunk_layering() -> void:
	var c := Worldgen.generate_chunk(0, 0)
	# At every (x, z), bedrock at y=0, grass at top, dirt just below grass, stone deeper
	for x: int in [0, 7, 15]:
		for z: int in [0, 7, 15]:
			var world_x: int = x
			var world_z: int = z
			var h := Worldgen.surface_height(world_x, world_z)
			assert_eq(c.get_block(x, 0, z), Blocks.BEDROCK, "(%d,0,%d) is bedrock" % [x, z])
			assert_eq(c.get_block(x, h, z), Blocks.GRASS, "(%d,%d,%d) is grass" % [x, h, z])
			assert_eq(c.get_block(x, h - 1, z), Blocks.DIRT, "(%d,%d,%d) is dirt" % [x, h - 1, z])
			assert_eq(c.get_block(x, h - 4, z), Blocks.STONE, "(%d,%d,%d) is stone" % [x, h - 4, z])
			# Above surface = air
			assert_eq(c.get_block(x, h + 1, z), Blocks.AIR, "above surface is air")


func test_neighboring_chunks_have_continuous_terrain() -> void:
	# Surface heights at the boundary between chunk (0,0) and chunk (1,0) should be
	# computed from continuous noise, so adjacent world coords give close heights.
	var h_at_15 := Worldgen.surface_height(15, 8)
	var h_at_16 := Worldgen.surface_height(16, 8)
	assert_almost_eq(float(h_at_15), float(h_at_16), 3.0, "adjacent worldgen heights are close")
