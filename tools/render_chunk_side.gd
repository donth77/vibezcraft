extends SceneTree

# Render a side-view PNG of a chunk's surface — what the player would
# see standing at one edge looking across. Shows actual block boundaries,
# so 1-block elevation outliers are immediately visible as 'towers'.


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

	# Color per block. PROJECT each X column onto image, painting top
	# 32 cells of terrain so 1-cell towers are unmissable.
	var img := Image.create(16 * 16, 32 * 8, false, Image.FORMAT_RGB8)
	var colors: Dictionary = {
		Blocks.STONE: Color(0.5, 0.5, 0.5),
		Blocks.DIRT: Color(0.55, 0.35, 0.2),
		Blocks.GRASS: Color(0.3, 0.7, 0.3),
		Blocks.SAND: Color(0.9, 0.85, 0.5),
		Blocks.GRAVEL: Color(0.6, 0.55, 0.5),
		Blocks.BEDROCK: Color(0.15, 0.15, 0.15),
		Blocks.WATER_STILL: Color(0.2, 0.4, 0.8),
		Blocks.LEAVES: Color(0.2, 0.5, 0.15),
		Blocks.LOG: Color(0.4, 0.25, 0.1),
		Blocks.SNOW_LAYER: Color(0.95, 0.95, 1.0),
		Blocks.SNOW_BLOCK: Color(0.95, 0.95, 1.0),
		Blocks.FLOWER_RED: Color(0.9, 0.1, 0.2),
	}
	# Also dump what's at the surface of each column for the WHOLE chunk
	# so we can see the actual block distribution numerically.
	print("Surface map (top block per (x,z)):")
	var name_map: Dictionary = {
		Blocks.GRASS: ".", Blocks.DIRT: "d", Blocks.SAND: "s",
		Blocks.STONE: "S", Blocks.SNOW_LAYER: "n", Blocks.SNOW_BLOCK: "N",
		Blocks.LEAVES: "L", Blocks.LOG: "l", Blocks.FLOWER_RED: "R",
		Blocks.FLOWER_YELLOW: "Y", Blocks.GRAVEL: "g", Blocks.BEDROCK: "B",
		Blocks.MUSHROOM_BROWN: "m", Blocks.MUSHROOM_RED: "r",
		Blocks.WATER_STILL: "~", Blocks.AIR: " ",
	}
	for x in range(16):
		var row: String = ""
		for z in range(16):
			var sy: int = -1
			for y in range(127, -1, -1):
				var b: int = chunk.get_block_unchecked(x, y, z)
				if b != Blocks.AIR:
					sy = y
					break
			if sy < 0:
				row += " "
				continue
			var b_top: int = chunk.get_block_unchecked(x, sy, z)
			row += name_map.get(b_top, "?")
		print("  " + row)

	# For each X column, render one Z slice (z=8) showing top 32 cells
	for x in range(16):
		var sy: int = -1
		for y in range(127, -1, -1):
			var b: int = chunk.get_block_unchecked(x, y, 8)
			if b != Blocks.AIR and b != Blocks.WATER_STILL and b != Blocks.WATER_FLOWING:
				sy = y
				break
		if sy < 0:
			continue
		var top_y: int = sy + 4  # render 4 cells of sky above
		var bottom_y: int = top_y - 32
		for y in range(bottom_y, top_y):
			if y < 0 or y >= 128:
				continue
			var b: int = chunk.get_block_unchecked(x, y, 8)
			var c: Color
			if b == Blocks.AIR:
				c = Color(0.7, 0.85, 1.0)  # sky
			elif b == Blocks.WATER_STILL or b == Blocks.WATER_FLOWING:
				c = Color(0.2, 0.4, 0.8)
			else:
				c = colors.get(b, Color(0.4, 0.4, 0.4))
			# 16-pixel-wide blocks for visibility
			var px: int = x * 16
			var py: int = (top_y - y - 1) * 8
			for dx in range(16):
				for dy in range(8):
					if px + dx < img.get_width() and py + dy < img.get_height():
						img.set_pixel(px + dx, py + dy, c)
	img.save_png("/tmp/chunk_side_%d_%d_%d.png" % [seed, cx, cz])
	print("Wrote /tmp/chunk_side_%d_%d_%d.png" % [seed, cx, cz])
	quit(0)
