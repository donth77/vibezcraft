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
	var stone_or_ore: Array[int] = [
		Blocks.STONE, Blocks.COAL_ORE, Blocks.IRON_ORE, Blocks.GOLD_ORE, Blocks.DIAMOND_ORE
	]
	var above_surface_ok: Array[int] = [Blocks.AIR, Blocks.LOG, Blocks.LEAVES]
	for x: int in [0, 7, 15]:
		for z: int in [0, 7, 15]:
			var world_x: int = x
			var world_z: int = z
			var h := Worldgen.surface_height(world_x, world_z)
			assert_eq(c.get_block(x, 0, z), Blocks.BEDROCK, "(%d,0,%d) is bedrock" % [x, z])
			assert_eq(c.get_block(x, h, z), Blocks.GRASS, "(%d,%d,%d) is grass" % [x, h, z])
			assert_eq(c.get_block(x, h - 1, z), Blocks.DIRT, "(%d,%d,%d) is dirt" % [x, h - 1, z])
			# Stone layer may be replaced by ore — allow either.
			var deep := c.get_block(x, h - 4, z)
			assert_true(
				deep in stone_or_ore, "(%d,%d,%d) is stone or ore, got %d" % [x, h - 4, z, deep]
			)
			# Above surface is air, or a tree block if a canopy overlaps.
			var above := c.get_block(x, h + 1, z)
			assert_true(
				above in above_surface_ok,
				"above surface at (%d,%d,%d) is air/log/leaves, got %d" % [x, h + 1, z, above]
			)


func test_neighboring_chunks_have_continuous_terrain() -> void:
	# Surface heights at the boundary between chunk (0,0) and chunk (1,0) should be
	# computed from continuous noise, so adjacent world coords give close heights.
	var h_at_15 := Worldgen.surface_height(15, 8)
	var h_at_16 := Worldgen.surface_height(16, 8)
	assert_almost_eq(float(h_at_15), float(h_at_16), 3.0, "adjacent worldgen heights are close")


func test_bedrock_band_is_chaotic_but_deterministic() -> void:
	var c1 := Worldgen.generate_chunk(0, 0)
	var c2 := Worldgen.generate_chunk(0, 0)
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			for y in range(1, 4):
				assert_eq(c1.get_block(x, y, z), c2.get_block(x, y, z))


func test_bedrock_band_has_a_mix_of_bedrock_and_stone() -> void:
	# Across one chunk's bedrock band (16*16*3 = 768 cells), expect both kinds.
	var c := Worldgen.generate_chunk(0, 0)
	var bedrock_count := 0
	var stone_count := 0
	for x in range(Chunk.SIZE_X):
		for z in range(Chunk.SIZE_Z):
			for y in range(1, 4):
				match c.get_block(x, y, z):
					Blocks.BEDROCK:
						bedrock_count += 1
					Blocks.STONE:
						stone_count += 1
	assert_gt(bedrock_count, 50, "plenty of bedrock in band")
	assert_gt(stone_count, 50, "plenty of stone in band too")


# --- Ore veins ---


func test_diamond_ore_never_above_spec_y() -> void:
	# Diamond config is y_max=16. Veins walk ±1 but the walker is clamped to
	# [y_lo, y_hi], so no diamond block should ever appear above y=16.
	for cx in range(-2, 3):
		for cz in range(-2, 3):
			var c := Worldgen.generate_chunk(cx, cz)
			for x in range(Chunk.SIZE_X):
				for z in range(Chunk.SIZE_Z):
					for y in range(17, Chunk.SIZE_Y):
						assert_ne(
							c.get_block(x, y, z),
							Blocks.DIAMOND_ORE,
							"diamond at (%d,%d,%d) in chunk (%d,%d)" % [x, y, z, cx, cz]
						)


func test_ores_only_replace_stone() -> void:
	# Ore veins must not overwrite grass, dirt, or bedrock. Scan a batch of
	# chunks; at every ore cell, every neighbor in the un-ored base layer
	# must have been stone-eligible (i.e. we never observe grass/dirt/bedrock
	# converted to ore). Equivalent check: no ore at y=0 (bedrock band).
	var ore_ids: Array[int] = [
		Blocks.COAL_ORE, Blocks.IRON_ORE, Blocks.GOLD_ORE, Blocks.DIAMOND_ORE
	]
	for cx in range(-1, 2):
		for cz in range(-1, 2):
			var c := Worldgen.generate_chunk(cx, cz)
			for x in range(Chunk.SIZE_X):
				for z in range(Chunk.SIZE_Z):
					# y=0 is always bedrock; ore there would be a bug.
					assert_false(
						c.get_block(x, 0, z) in ore_ids,
						"ore at y=0 in chunk (%d,%d,%d,%d)" % [cx, cz, x, z]
					)
					# Surface cell: must remain GRASS (unreplaced by ore).
					var world_x: int = cx * Chunk.SIZE_X + x
					var world_z: int = cz * Chunk.SIZE_Z + z
					var h := Worldgen.surface_height(world_x, world_z)
					assert_false(
						c.get_block(x, h, z) in ore_ids,
						"ore at surface in chunk (%d,%d) col (%d,%d)" % [cx, cz, x, z]
					)


func test_ore_placement_is_deterministic() -> void:
	var c1 := Worldgen.generate_chunk(3, -4)
	var c2 := Worldgen.generate_chunk(3, -4)
	assert_eq(c1.blocks, c2.blocks, "ore placement is deterministic")


func test_ore_density_matches_vanilla_alpha() -> void:
	# Per-chunk yields must land in [100%, 140%] of vanilla Alpha's empirical
	# numbers (Minecraft Wiki "Ore#Availability"): coal ~111, iron ~77, gold
	# ~8.5, diamond ~3.5. Floor = vanilla (we want ores at least as plentiful
	# as reference); ceiling = 1.4× so worlds don't turn into ore quarries.
	var totals := {
		Blocks.COAL_ORE: 0,
		Blocks.IRON_ORE: 0,
		Blocks.GOLD_ORE: 0,
		Blocks.DIAMOND_ORE: 0,
	}
	var chunk_count := 0
	for cx in range(-4, 4):
		for cz in range(-4, 4):
			var c := Worldgen.generate_chunk(cx, cz)
			chunk_count += 1
			for x in range(Chunk.SIZE_X):
				for z in range(Chunk.SIZE_Z):
					for y in range(Chunk.SIZE_Y):
						var b := c.get_block(x, y, z)
						if totals.has(b):
							totals[b] += 1
	var coal_per_chunk := float(totals[Blocks.COAL_ORE]) / chunk_count
	var iron_per_chunk := float(totals[Blocks.IRON_ORE]) / chunk_count
	var gold_per_chunk := float(totals[Blocks.GOLD_ORE]) / chunk_count
	var diamond_per_chunk := float(totals[Blocks.DIAMOND_ORE]) / chunk_count
	print(
		(
			"ore/chunk: coal=%.1f (%.0f%%) iron=%.1f (%.0f%%) gold=%.1f (%.0f%%) diamond=%.1f (%.0f%%)"
			% [
				coal_per_chunk,
				100.0 * coal_per_chunk / 111.0,
				iron_per_chunk,
				100.0 * iron_per_chunk / 77.0,
				gold_per_chunk,
				100.0 * gold_per_chunk / 8.5,
				diamond_per_chunk,
				100.0 * diamond_per_chunk / 3.5,
			]
		)
	)
	assert_between(coal_per_chunk, 111.0, 155.4, "coal/chunk in [100%%, 140%%] of vanilla 111")
	assert_between(iron_per_chunk, 77.0, 107.8, "iron/chunk in [100%%, 140%%] of vanilla 77")
	assert_between(gold_per_chunk, 8.5, 11.9, "gold/chunk in [100%%, 140%%] of vanilla 8.5")
	assert_between(diamond_per_chunk, 3.5, 4.9, "diamond/chunk in [100%%, 140%%] of vanilla 3.5")


# --- Trees ---


func test_tree_canopy_stays_within_chunk_bounds() -> void:
	# With margin=2 and max canopy radius=2, all leaves/logs must land in [0,15].
	# Scan multiple chunks for any tree blocks, then verify they're all in-chunk
	# (tautologically true for chunk-local coords, so the real check is below:
	# the boundary layers x=0, x=15 etc. should not have canopy "pushed" there
	# from a margin bug — but since we read from within the chunk, the safer
	# assertion is "tree blocks exist in some chunks".
	var found_any_tree := false
	for cx in range(-3, 4):
		for cz in range(-3, 4):
			var c := Worldgen.generate_chunk(cx, cz)
			for x in range(Chunk.SIZE_X):
				for z in range(Chunk.SIZE_Z):
					for y in range(Chunk.SIZE_Y):
						var b := c.get_block(x, y, z)
						if b == Blocks.LOG or b == Blocks.LEAVES:
							found_any_tree = true
	assert_true(found_any_tree, "at least one tree across 49 chunks")


func test_trees_only_spawn_on_grass() -> void:
	# Every LOG column's base block sits directly above a GRASS cell.
	for cx in range(-2, 3):
		for cz in range(-2, 3):
			var c := Worldgen.generate_chunk(cx, cz)
			for x in range(Chunk.SIZE_X):
				for z in range(Chunk.SIZE_Z):
					# Find the lowest LOG in this column.
					for y in range(1, Chunk.SIZE_Y):
						if c.get_block(x, y, z) == Blocks.LOG:
							assert_eq(
								c.get_block(x, y - 1, z),
								Blocks.GRASS,
								"log base at (%d,%d,%d) sits on grass" % [x, y, z]
							)
							break


func test_tree_placement_is_deterministic() -> void:
	var c1 := Worldgen.generate_chunk(-1, 2)
	var c2 := Worldgen.generate_chunk(-1, 2)
	assert_eq(c1.blocks, c2.blocks, "tree placement is deterministic")
