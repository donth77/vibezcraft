extends SceneTree

# Count "water-edge" surface columns per chunk: columns where the surface
# block is grass/dirt/sand AND at least one cardinal neighbor cell at the
# same Y is water. These are the cells where sugar cane scatter can
# successfully place — high count = high sugar cane density.


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed: int = args[0].to_int() if args.size() > 0 else 1724433623
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)

	var n_chunks: int = 0
	var total_water_edge: int = 0
	var total_surface_cells: int = 0
	var total_water_cells: int = 0
	for cx in range(-4, 4):
		for cz in range(-4, 4):
			n_chunks += 1
			var chunk: Chunk = Worldgen.generate_chunk(cx, cz)
			# Find surface heights
			var heights: Array = []
			heights.resize(16 * 16)
			for x in range(16):
				for z in range(16):
					var sy: int = -1
					for y in range(127, -1, -1):
						var b: int = chunk.get_block_unchecked(x, y, z)
						if (
							b != Blocks.AIR
							and b != Blocks.WATER_STILL
							and b != Blocks.WATER_FLOWING
						):
							sy = y
							break
					heights[x * 16 + z] = sy
			# Count water-edge cells (within chunk only — cross-chunk
			# borders skipped, matching our sugar cane scatter)
			for x in range(1, 15):
				for z in range(1, 15):
					var sy: int = heights[x * 16 + z]
					if sy < 0:
						continue
					var top: int = chunk.get_block_unchecked(x, sy, z)
					# Surface must be grass/dirt/sand to be sugar-cane eligible
					if top != Blocks.GRASS and top != Blocks.DIRT and top != Blocks.SAND:
						continue
					total_surface_cells += 1
					# Check 4 cardinal neighbors at SAME y for water
					for off: Vector2i in [
						Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)
					]:
						var nx: int = x + off.x
						var nz: int = z + off.y
						var nb: int = chunk.get_block_unchecked(nx, sy, nz)
						if nb == Blocks.WATER_STILL or nb == Blocks.WATER_FLOWING:
							total_water_edge += 1
							break
			# Total water cells in chunk (any layer, for context)
			for i in range(Chunk.TOTAL_BLOCKS):
				if chunk.blocks[i] == Blocks.WATER_STILL:
					total_water_cells += 1
	print("=== OURS seed %d, %d chunks ===" % [seed, n_chunks])
	print("Total grass/dirt/sand surface cells: %d (%.1f per chunk)" % [
		total_surface_cells, float(total_surface_cells) / n_chunks
	])
	print("Of those, water-edge cells (≥1 water neighbor): %d (%.1f per chunk = %.1f%% of surface)" % [
		total_water_edge, float(total_water_edge) / n_chunks,
		100.0 * total_water_edge / max(total_surface_cells, 1)
	])
	print("Total WATER_STILL cells (all layers): %d (%.1f per chunk)" % [
		total_water_cells, float(total_water_cells) / n_chunks
	])
	quit(0)
