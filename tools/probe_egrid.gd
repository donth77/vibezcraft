extends SceneTree


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed: int = args[0].to_int() if args.size() > 0 else 2012828372
	var cx: int = args[1].to_int() if args.size() > 1 else 0
	var cz: int = args[2].to_int() if args.size() > 2 else 0
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)
	Worldgen3D._ensure_noises(seed)

	# Sample e_grid the same way density_grid does
	var noise_base_x: int = cx * 4
	var noise_base_z: int = cz * 4
	var e_grid: PackedFloat64Array = PackedFloat64Array()
	e_grid.resize(5 * 17 * 5)
	Worldgen3D._e_noise.sample_3d_grid(
		e_grid,
		float(noise_base_x), 0.0, float(noise_base_z),
		5, 17, 5,
		Worldgen3D.COORDINATE_SCALE,
		Worldgen3D.HEIGHT_SCALE,
		Worldgen3D.COORDINATE_SCALE
	)
	# Our layout: idx = (ix * GRID_Y + iy) * GRID_Z + iz
	# Vanilla layout: idx = (ix * 5 + iz) * 17 + iy
	# Print at iy=8 corners
	# CORRECT layout: sample_3d_grid_additive writes vanilla layout
	# (Y innermost): idx = X * (Z_size * Y_size) + Z * Y_size + Y
	for ix in range(5):
		for iz in range(5):
			var idx_ours: int = (ix * 5 + iz) * 17 + 8
			var v: float = e_grid[idx_ours]
			print("# OURS e[ix=%d,iy=8,iz=%d] = %.4f" % [ix, iz, v])
	quit(0)
