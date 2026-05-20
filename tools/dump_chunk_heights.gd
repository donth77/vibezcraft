extends SceneTree


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed: int = args[0].to_int() if args.size() > 0 else 0
	var cx: int = args[1].to_int() if args.size() > 1 else 0
	var cz: int = args[2].to_int() if args.size() > 2 else 0
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)

	# Generate ONLY base terrain (skip ores, caves, surface, decorators)
	var chunk: Chunk = Chunk.new()
	Worldgen3D.fill_chunk(chunk, cx, cz)

	# Find topmost STONE per column
	print("# OURS terrain seed=%d chunk(%d,%d) — base STONE only:" % [seed, cx, cz])
	var min_h: int = 999
	var max_h: int = 0
	var sum_h: int = 0
	for x in range(16):
		var line: String = "# "
		for z in range(16):
			var h: int = -1
			for y in range(127, -1, -1):
				if chunk.get_block_unchecked(x, y, z) == Blocks.STONE:
					h = y
					break
			line += "%3d " % h
			if h < min_h:
				min_h = h
			if h > max_h:
				max_h = h
			sum_h += h
		print(line)
	print("# stats: min=%d max=%d mean=%.1f" % [min_h, max_h, sum_h / 256.0])
	quit(0)
