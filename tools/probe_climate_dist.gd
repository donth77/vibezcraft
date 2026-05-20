extends SceneTree


func _init() -> void:
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(1724433623)
	Worldgen.surface_height(0, 0)
	Worldgen3D._ensure_noises(1724433623)

	# Sample temp_raw and rain_raw across 1024 cells. Print distribution.
	var temp_min: float = 1e30
	var temp_max: float = -1e30
	var temp_sum: float = 0.0
	var n: int = 0
	var hist: Dictionary = {}
	for x in range(0, 200, 5):
		for z in range(0, 200, 5):
			var temp_raw: float = Worldgen3D._temp_noise.sample_2d(
				float(x), float(z), 0.025, 0.25
			)
			temp_min = min(temp_min, temp_raw)
			temp_max = max(temp_max, temp_raw)
			temp_sum += temp_raw
			n += 1
			# Bucket
			var bucket: int = int(temp_raw / 5.0) * 5
			hist[bucket] = hist.get(bucket, 0) + 1
	print("temp_raw distribution (200×200/5 = 1600 samples):")
	print("  min=%.2f max=%.2f mean=%.2f" % [temp_min, temp_max, temp_sum / n])
	var keys: Array = hist.keys()
	keys.sort()
	for k: int in keys:
		var bar: String = "#".repeat(hist[k] * 50 / n)
		print("  %4d..%4d: %4d  %s" % [k, k + 4, hist[k], bar])
	quit(0)
