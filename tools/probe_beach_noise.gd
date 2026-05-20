extends SceneTree


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed: int = args[0].to_int() if args.size() > 0 else 1724433623
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)
	Worldgen3D._ensure_noises(seed)

	# Sample s_noise (gravel band) and r_noise (sand band) across many cells.
	# Vanilla bl_gravel: s_noise + nextDouble*0.2 > 3.0 → GRAVEL placed
	# Vanilla bl_sand:   r_noise + nextDouble*0.2 > 0.0 → SAND placed (overrides gravel)
	#
	# Sample 32×32 = 1024 chunks via the same bulk grid call surface_layer uses.
	var s_total: int = 0
	var s_above_3: int = 0
	var r_total: int = 0
	var r_above_0: int = 0
	var both_true: int = 0  # gravel AND sand → sand wins
	var only_gravel: int = 0  # gravel WITHOUT sand → visible gravel
	var s_min: float = 1e30
	var s_max: float = -1e30
	for cx in range(-16, 16):
		for cz in range(-16, 16):
			# Same bulk-grid call as _apply_surface_layer_3d
			var r_noise: PackedFloat64Array = PackedFloat64Array()
			r_noise.resize(256)
			Worldgen3D._beach_noise.sample_3d_grid(
				r_noise, cx * 16.0, cz * 16.0, 0.0, 16, 16, 1, 0.03125, 0.03125, 1.0
			)
			var s_noise: PackedFloat64Array = PackedFloat64Array()
			s_noise.resize(256)
			Worldgen3D._beach_noise.sample_3d_grid(
				s_noise, cz * 16.0, 109.0134, cx * 16.0, 16, 1, 16, 0.03125, 1.0, 0.03125
			)
			for x in range(16):
				for z in range(16):
					var ni: int = x + z * 16
					var s: float = s_noise[ni]
					var r: float = r_noise[ni]
					s_total += 1
					r_total += 1
					if s > s_max:
						s_max = s
					if s < s_min:
						s_min = s
					var sand_likely: bool = r > 0.0
					var gravel_likely: bool = s > 3.0
					if gravel_likely:
						s_above_3 += 1
					if sand_likely:
						r_above_0 += 1
					if gravel_likely and sand_likely:
						both_true += 1
					if gravel_likely and not sand_likely:
						only_gravel += 1

	print("=== beach noise distribution at seed %d (1024 chunks) ===" % seed)
	print(
		"s_noise (gravel band): range=[%.2f, %.2f], > 3.0 in %d/%d = %.2f%%"
		% [s_min, s_max, s_above_3, s_total, 100.0 * s_above_3 / s_total]
	)
	print(
		"r_noise (sand band):   > 0.0 in %d/%d = %.2f%%"
		% [r_above_0, r_total, 100.0 * r_above_0 / r_total]
	)
	print(
		"gravel WITHOUT sand (visible underwater gravel): %d/%d = %.3f%%"
		% [only_gravel, s_total, 100.0 * only_gravel / s_total]
	)
	print("(only fires for cells in beach band y∈[60, 65])")
	quit(0)
