extends SceneTree

# Export a top-down heightmap PNG and a side-view cross-section PNG for a
# region of the world at the given seed. Lets us literally LOOK at what
# the worldgen produces without firing up the game.


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed: int = args[0].to_int() if args.size() > 0 else 691558733
	var radius: int = args[1].to_int() if args.size() > 1 else 8  # chunks
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)

	var size: int = radius * 2 * 16  # blocks per side
	print("Generating %d×%d block region (%d chunks) at seed %d..." % [size, size, radius * 2 * radius * 2, seed])

	# Heightmap (top-down). Each pixel is one column, value = surface y.
	var heightmap := Image.create(size, size, false, Image.FORMAT_RGB8)
	# Side cross-section through z=0 row. width=size, height=128.
	var cross := Image.create(size, 128, false, Image.FORMAT_RGB8)

	# Block colors for the side view
	var colors: Dictionary = {
		Blocks.STONE: Color(0.5, 0.5, 0.5),
		Blocks.DIRT: Color(0.55, 0.35, 0.2),
		Blocks.GRASS: Color(0.3, 0.7, 0.3),
		Blocks.SAND: Color(0.9, 0.85, 0.5),
		Blocks.GRAVEL: Color(0.6, 0.55, 0.5),
		Blocks.BEDROCK: Color(0.15, 0.15, 0.15),
		Blocks.WATER_STILL: Color(0.2, 0.4, 0.8),
		Blocks.WATER_FLOWING: Color(0.3, 0.5, 0.85),
		Blocks.LAVA_STILL: Color(0.95, 0.4, 0.1),
		Blocks.COAL_ORE: Color(0.2, 0.2, 0.2),
		Blocks.IRON_ORE: Color(0.8, 0.6, 0.4),
		Blocks.LOG: Color(0.4, 0.25, 0.1),
		Blocks.LEAVES: Color(0.2, 0.5, 0.15),
	}

	for cx in range(-radius, radius):
		for cz in range(-radius, radius):
			var chunk: Chunk = Worldgen.generate_chunk(cx, cz)
			for x in range(16):
				for z in range(16):
					# Find surface
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
					var px_x: int = (cx + radius) * 16 + x
					var px_z: int = (cz + radius) * 16 + z
					# Heightmap shading: color by elevation (blue=low/water, green=mid, brown=hill, white=peak)
					var h_norm: float = (float(sy) - 50.0) / 50.0  # 50..100 → 0..1
					h_norm = clamp(h_norm, 0.0, 1.0)
					var top_block: int = chunk.get_block_unchecked(x, sy, z)
					var c: Color
					if sy < 64:
						c = Color(0.1, 0.2, 0.5 + h_norm * 0.3)  # underwater
					elif top_block == Blocks.SAND:
						c = Color(0.9, 0.85, 0.5).lerp(Color(1, 1, 1), h_norm * 0.3)
					elif top_block == Blocks.GRASS:
						c = Color(0.2, 0.6, 0.2).lerp(Color(0.7, 0.7, 0.7), h_norm * 0.6)
					elif top_block == Blocks.SNOW_BLOCK or top_block == Blocks.SNOW_LAYER:
						c = Color(0.95, 0.95, 1)
					else:
						c = Color(0.5, 0.4, 0.3)
					heightmap.set_pixel(px_x, px_z, c)

					# Cross-section: only z=0 row (one Z value across all X)
					if cz == 0 and z == 0:
						for y in range(128):
							var b2: int = chunk.get_block_unchecked(x, y, 0)
							var col: Color = colors.get(b2, Color(0, 0, 0))
							if b2 == Blocks.AIR:
								col = Color(0.7, 0.85, 1.0) if y >= 64 else Color(0.05, 0.05, 0.1)
							cross.set_pixel(px_x, 127 - y, col)

	var out_dir: String = "/tmp"
	heightmap.save_png("%s/terrain_topdown_%d.png" % [out_dir, seed])
	cross.save_png("%s/terrain_cross_%d.png" % [out_dir, seed])
	print("Wrote /tmp/terrain_topdown_%d.png  (top-down heightmap)" % seed)
	print("Wrote /tmp/terrain_cross_%d.png  (side cross-section z=0)" % seed)
	quit(0)
