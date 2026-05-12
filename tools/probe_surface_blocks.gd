extends SceneTree

# Dump every NON-GRASS block placed at or 1-above the surface across many
# chunks. If we see FLOWER_RED everywhere, it's flower over-placement.
# If we see GRASS at unexpected y, it's terrain spikes.


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed: int = args[0].to_int() if args.size() > 0 else 806710720
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)

	var counts_surface: Dictionary = {}  # block ID at surface (top non-air)
	var counts_above: Dictionary = {}  # block ID at surface+1 (plants)
	var heights_per_chunk: Array[int] = []  # range per chunk
	var cells_per_chunk: int = 16 * 16
	var n_chunks: int = 0
	for cx in range(-3, 3):
		for cz in range(-3, 3):
			n_chunks += 1
			var chunk: Chunk = Worldgen.generate_chunk(cx, cz)
			var chunk_min: int = 999
			var chunk_max: int = 0
			for x in range(16):
				for z in range(16):
					# Find topmost cell that's not AIR/WATER
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
					if sy < 0:
						continue
					var b_surf: int = chunk.get_block_unchecked(x, sy, z)
					counts_surface[b_surf] = counts_surface.get(b_surf, 0) + 1
					if sy < 127:
						var b_above: int = chunk.get_block_unchecked(x, sy + 1, z)
						if b_above != Blocks.AIR:
							counts_above[b_above] = counts_above.get(b_above, 0) + 1
					if sy < chunk_min:
						chunk_min = sy
					if sy > chunk_max:
						chunk_max = sy
			heights_per_chunk.append(chunk_max - chunk_min)

	var total: int = n_chunks * cells_per_chunk
	print("seed=%d, %d chunks (%d columns)" % [seed, n_chunks, total])
	print("\nSURFACE BLOCKS (top non-AIR/WATER per column):")
	var keys = counts_surface.keys()
	keys.sort_custom(func(a, b): return counts_surface[a] > counts_surface[b])
	for k: int in keys:
		var name = Blocks.name_of(k) if k < 100 else "item-%d" % k
		print(
			(
				"  %3d %s: %d (%.1f%%)"
				% [k, name, counts_surface[k], 100.0 * counts_surface[k] / total]
			)
		)
	print("\nABOVE-SURFACE BLOCKS (plants / decorations on top):")
	var keys2 = counts_above.keys()
	keys2.sort_custom(func(a, b): return counts_above[a] > counts_above[b])
	for k: int in keys2:
		var name = Blocks.name_of(k) if k < 100 else "item-%d" % k
		print("  %3d %s: %d (%.1f%%)" % [k, name, counts_above[k], 100.0 * counts_above[k] / total])
	# Per-chunk variance
	heights_per_chunk.sort()
	print(
		(
			"\nPer-chunk height span (max-min): min=%d median=%d max=%d"
			% [
				heights_per_chunk[0],
				heights_per_chunk[heights_per_chunk.size() / 2],
				heights_per_chunk[-1]
			]
		)
	)
	quit(0)
