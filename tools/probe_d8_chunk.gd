extends SceneTree


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed: int = args[0].to_int() if args.size() > 0 else 1475921578
	var cx: int = args[1].to_int() if args.size() > 1 else -3
	var cz: int = args[2].to_int() if args.size() > 2 else -3
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)
	Worldgen3D._ensure_noises(seed)

	# Re-run the exact d8 computation as density_grid (chunk-uniform climate)
	var chunk_center_x: float = float(cx * 16 + 8)
	var chunk_center_z: float = float(cz * 16 + 8)
	var climate: Vector2 = Worldgen3D.climate_at(chunk_center_x, chunk_center_z)
	var d6: float = climate.y * climate.x
	var d7: float = 1.0 - d6
	d7 *= d7
	d7 *= d7
	d7 = 1.0 - d7
	print("Chunk (%d, %d): temp=%.4f rain=%.4f d6=%.4f d7=%.4f" % [cx, cz, climate.x, climate.y, d6, d7])

	# Sample g_grid via the same bulk path as density_grid
	var noise_base_x: int = cx * 4
	var noise_base_z: int = cz * 4
	var g_grid: PackedFloat64Array = PackedFloat64Array()
	g_grid.resize(25)
	Worldgen3D._amplitude_noise.sample_3d_grid(
		g_grid, float(noise_base_x), 10.0, float(noise_base_z),
		5, 1, 5,
		Worldgen3D.AMPLITUDE_SCALE, 1.0, Worldgen3D.AMPLITUDE_SCALE
	)
	# Print d8 per coarse cell
	print("d8 per coarse column (chunk-uniform climate):")
	for ix in range(5):
		var line: String = ""
		for iz in range(5):
			var g: float = g_grid[ix * 5 + iz]
			var d8: float = (g + 256.0) / 512.0
			d8 *= d7
			if d8 > 1.0:
				d8 = 1.0
			if d8 < 0.0:
				d8 = 0.0
			d8 += 0.5
			line += "%6.3f " % d8
		print(line)
	quit(0)
