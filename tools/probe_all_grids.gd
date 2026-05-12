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

	# Sample all grids at iy=8 (mid)
	var noise_base_x: int = cx * 4
	var noise_base_z: int = cz * 4
	for nname in ["e", "f", "selector"]:
		var noise: NoiseOctaves
		var scale_xz: float = 684.412
		var scale_y: float = 684.412
		match nname:
			"e":
				noise = Worldgen3D._e_noise
			"f":
				noise = Worldgen3D._f_noise
			"selector":
				noise = Worldgen3D._selector_noise
				scale_xz = 684.412 / 80.0
				scale_y = 684.412 / 160.0
		var grid: PackedFloat64Array = PackedFloat64Array()
		grid.resize(5 * 17 * 5)
		noise.sample_3d_grid(
			grid, float(noise_base_x), 0.0, float(noise_base_z),
			5, 17, 5, scale_xz, scale_y, scale_xz
		)
		for ix in range(5):
			for iz in range(5):
				var idx: int = (ix * 5 + iz) * 17 + 8
				print(
					"# OURS %s[%d,8,%d] = %.4f" % [nname, ix, iz, grid[idx]]
				)
	quit(0)
