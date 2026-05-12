extends SceneTree

# Probe h_grid + d4 distribution across MANY chunks. We need to know if
# the depth noise ever produces values > +5333 (the threshold to enter the
# 'land' branch in px.java). If h_grid is always in [-5333, +5333], every
# chunk is ocean → flat terrain.


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed: int = args[0].to_int() if args.size() > 0 else 339031745
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)
	Worldgen3D._ensure_noises(seed)

	var DEPTH_SCALE: float = 200.0
	var COARSE_STEP_X: int = 4
	var COARSE_STEP_Z: int = 4

	var land_chunks: int = 0
	var total_chunks: int = 0
	var h_min: float = 1e30
	var h_max: float = -1e30
	var positive_h_samples: int = 0
	var total_samples: int = 0
	# Sample 32×32 = 1024 chunks (a 512×512 block area), one h-grid sample
	# per chunk (center column).
	for cx in range(-16, 16):
		for cz in range(-16, 16):
			var noise_base_x: int = cx * COARSE_STEP_X
			var noise_base_z: int = cz * COARSE_STEP_Z
			# Sample chunk-center column (ix=2, iz=2 of the 5x5 grid)
			var nx: float = float(noise_base_x + 2)
			var nz: float = float(noise_base_z + 2)
			var h: float = Worldgen3D._depth_noise.sample_2d(
				nx * DEPTH_SCALE, nz * DEPTH_SCALE
			)
			h_min = min(h_min, h)
			h_max = max(h_max, h)
			if h > 0:
				positive_h_samples += 1
			total_samples += 1
			# d4 chain
			var d4: float = h / 8000.0
			if d4 < 0.0:
				d4 = -d4 * 0.3
			d4 = d4 * 3.0 - 2.0
			if d4 >= 0.0:
				land_chunks += 1
			total_chunks += 1

	print(
		"Sampled %d chunks (32×32 area): h_min=%.1f h_max=%.1f"
		% [total_chunks, h_min, h_max]
	)
	print(
		"  positive h: %d/%d = %.1f%%   land branch: %d/%d = %.1f%%"
		% [
			positive_h_samples,
			total_samples,
			100.0 * positive_h_samples / total_samples,
			land_chunks,
			total_chunks,
			100.0 * land_chunks / total_chunks,
		]
	)
	print("")
	print("Vanilla expected: h_grid ranges roughly [-30000, +30000] across worlds")
	print("Land threshold: h > +5333 (so d4_initial > 0.667 → d4 stays positive)")
	quit(0)
