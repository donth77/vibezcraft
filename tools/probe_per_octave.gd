extends SceneTree

# Per-octave probe: for the depth noise (16 octaves), sample each octave
# individually at MANY positions and report mean / range. A vanilla-faithful
# Perlin should have mean ~0 (symmetric); a biased port will show DC offset.


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

	# Sample each of the 16 octaves at 256 distinct positions across a wide
	# area, replicating the per-octave coord scaling the reverse-FBM uses.
	print("Per-octave depth-noise statistics across 256 positions (32x32 chunks)")
	print(
		"%-7s %-12s %-12s %-12s %-12s %-12s"
		% ["octave", "amp_factor", "mean", "min", "max", "% positive"]
	)
	print("-".repeat(72))

	var sum_means: float = 0.0
	for oct in range(16):
		var amp: float = 1.0
		for _i in range(oct):
			amp /= 2.0
		var sum: float = 0.0
		var n: int = 0
		var lo: float = 1e30
		var hi: float = -1e30
		var pos: int = 0
		for cx in range(-8, 8):
			for cz in range(-8, 8):
				var noise_base_x: int = cx * COARSE_STEP_X
				var noise_base_z: int = cz * COARSE_STEP_Z
				var nx: float = float(noise_base_x + 2)
				var nz: float = float(noise_base_z + 2)
				# Each octave samples at coord * amp (matching nf.java pattern)
				var sample: float = Worldgen3D._depth_noise._vanilla_octaves[oct].sample_2d(
					nx * DEPTH_SCALE * amp, nz * DEPTH_SCALE * amp
				)
				sum += sample
				lo = min(lo, sample)
				hi = max(hi, sample)
				if sample > 0:
					pos += 1
				n += 1
		var mean: float = sum / n
		# Contribution to total: divided by amp = multiplied by 1/amp
		var contribution_mean: float = mean / amp
		sum_means += contribution_mean
		print(
			"%-7d %-12.6f %-12.4f %-12.4f %-12.4f %5.1f%%   contribution_mean=%.2f"
			% [oct, amp, mean, lo, hi, 100.0 * pos / n, contribution_mean]
		)

	print("-".repeat(72))
	print("Sum of contribution means: %.2f (should be near 0 for unbiased noise)" % sum_means)
	quit(0)
