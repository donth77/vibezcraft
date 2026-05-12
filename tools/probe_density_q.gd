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
	# Get computed density grid via density_grid() — same as fill_chunk reads
	var grid: PackedFloat64Array = Worldgen3D.density_grid(cx, cz)
	# Print at iy=8
	for ix in range(5):
		for iz in range(5):
			var idx: int = (ix * 17 + 8) * 5 + iz  # Z-innermost layout
			print("# OURS q[%d,8,%d] = %.4f" % [ix, iz, grid[idx]])
	quit(0)
