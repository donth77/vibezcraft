extends SceneTree

# Generate a real chunk and report actual surface heights — what the player sees.
# Sample 64 chunks (8×8 area, 128×128 blocks) to characterize visible variety.


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed: int = args[0].to_int() if args.size() > 0 else 339031745
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)

	var all_heights: Array[int] = []
	var per_chunk_min: Array[int] = []
	var per_chunk_max: Array[int] = []
	var per_chunk_mean: Array[float] = []

	for cx in range(-4, 4):
		for cz in range(-4, 4):
			var chunk: Chunk = Worldgen.generate_chunk(cx, cz)
			var ch_heights: Array[int] = []
			for x in range(16):
				for z in range(16):
					# Walk top-down for first non-AIR, non-WATER cell
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
					if sy >= 0:
						ch_heights.append(sy)
						all_heights.append(sy)
			if ch_heights.is_empty():
				continue
			ch_heights.sort()
			per_chunk_min.append(ch_heights[0])
			per_chunk_max.append(ch_heights[-1])
			var sum: float = 0.0
			for h in ch_heights:
				sum += float(h)
			per_chunk_mean.append(sum / float(ch_heights.size()))

	all_heights.sort()
	var n: int = all_heights.size()
	var s: float = 0.0
	for h in all_heights:
		s += float(h)
	var mean: float = s / float(n)
	print("seed=%d, sampled %d chunks, %d total columns" % [seed, per_chunk_min.size(), n])
	print(
		(
			"Surface y: min=%d  max=%d  mean=%.1f  median=%d"
			% [all_heights[0], all_heights[-1], mean, all_heights[n / 2]]
		)
	)
	print("Chunk-level variance (per-chunk max - min):")
	var spans: Array[int] = []
	for i in range(per_chunk_min.size()):
		spans.append(per_chunk_max[i] - per_chunk_min[i])
	spans.sort()
	print("  min span=%d  median=%d  max=%d" % [spans[0], spans[spans.size() / 2], spans[-1]])
	print("Chunk-level mean variance:")
	per_chunk_mean.sort()
	print(
		(
			"  min=%.1f  median=%.1f  max=%.1f"
			% [
				per_chunk_mean[0],
				per_chunk_mean[per_chunk_mean.size() / 2],
				per_chunk_mean[-1]
			]
		)
	)

	# Histogram
	var buckets: Dictionary = {}
	for h in all_heights:
		var b: int = h / 5 * 5
		buckets[b] = buckets.get(b, 0) + 1
	var keys: Array = buckets.keys()
	keys.sort()
	print("Histogram (5-cell buckets):")
	for k in keys:
		var bar: String = "#".repeat(buckets[k] * 60 / n)
		print("  y=%2d-%2d: %5d  %s" % [k, k + 4, buckets[k], bar])
	quit(0)
