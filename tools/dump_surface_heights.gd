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
	var chunk: Chunk = Worldgen.generate_chunk(cx, cz)

	# Dump surface_y per (x, z) in 16x16 grid
	var heights: Array = []
	for x in range(16):
		var row: Array = []
		for z in range(16):
			var sy: int = -1
			for y in range(127, -1, -1):
				var b: int = chunk.get_block_unchecked(x, y, z)
				if (
					b != Blocks.AIR
					and b != Blocks.WATER_STILL
					and b != Blocks.WATER_FLOWING
				):
					sy = y
					break
			row.append(sy)
		heights.append(row)
	print("surface_y per (x, z) for chunk (%d, %d) seed %d:" % [cx, cz, seed])
	for x in range(16):
		var line: String = ""
		for z in range(16):
			line += "%3d " % heights[x][z]
		print(line)

	# Count cells that differ from 4 neighbors by >=1 (potential towers)
	var towers: int = 0
	var dips: int = 0
	for x in range(1, 15):
		for z in range(1, 15):
			var sy: int = heights[x][z]
			var n_xm: int = heights[x - 1][z]
			var n_xp: int = heights[x + 1][z]
			var n_zm: int = heights[x][z - 1]
			var n_zp: int = heights[x][z + 1]
			var nmax: int = max(max(n_xm, n_xp), max(n_zm, n_zp))
			var nmin: int = min(min(n_xm, n_xp), min(n_zm, n_zp))
			if sy > nmax:
				towers += 1
			if sy < nmin:
				dips += 1
	print(
		(
			"Cells higher than ALL 4 neighbors: %d  (lower than all: %d)  of %d interior"
			% [towers, dips, 14 * 14]
		)
	)
	quit(0)
