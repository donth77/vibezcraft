extends SceneTree

# Sample the e/f 3D density noise at every cell of a 5×17×5 grid for one
# chunk, and across multiple chunks. Report variance — if it's narrow
# per-chunk, terrain shape is uniform per chunk (boring).


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed: int = args[0].to_int() if args.size() > 0 else 691558733
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)
	Worldgen3D._ensure_noises(seed)

	var COORDINATE_SCALE: float = 684.412
	var HEIGHT_SCALE: float = 684.412

	# Sample e and f noise across one chunk's 5×17×5 grid
	for chunk_coord in [[0, 0], [10, 0], [0, 10], [50, 50]]:
		var cx: int = chunk_coord[0]
		var cz: int = chunk_coord[1]
		var noise_base_x: int = cx * 4
		var noise_base_z: int = cz * 4
		var e_grid: PackedFloat64Array = PackedFloat64Array()
		e_grid.resize(5 * 17 * 5)
		Worldgen3D._e_noise.sample_3d_grid(
			e_grid, float(noise_base_x), 0.0, float(noise_base_z),
			5, 17, 5, COORDINATE_SCALE, HEIGHT_SCALE, COORDINATE_SCALE
		)

		var lo: float = 1e30
		var hi: float = -1e30
		var sum: float = 0.0
		for v in e_grid:
			lo = min(lo, v)
			hi = max(hi, v)
			sum += v
		var mean: float = sum / float(e_grid.size())

		# Density at center column, all Y
		var center_idx_base: int = (2 * 17 + 0) * 5 + 2
		print("chunk (%d, %d): e_noise grid range=[%.1f, %.1f] mean=%.1f spread=%.1f" %
			[cx, cz, lo, hi, mean, hi - lo])
		print("  density at center column (x=2,z=2) per Y:")
		var line: String = "    "
		for iy in range(17):
			var v: float = e_grid[(2 * 17 + iy) * 5 + 2]
			line += "%6.1f " % v
		print(line)

	quit(0)
