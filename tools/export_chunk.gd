extends SceneTree

# Export a generated Chunk to a binary file matching vanilla Alpha 1.2.6's
# NBT "Blocks" byte order (16×16×128 = 32768 bytes, indexed
# (x*16 + z)*128 + y).
#
# Usage:
#   godot --headless --path . -s tools/export_chunk.gd -- <seed> <cx> <cz> <out_path>
#
# Example:
#   godot --headless --path . -s tools/export_chunk.gd -- 12345 0 0 /tmp/our_chunk_0_0.raw


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 4:
		printerr("Usage: export_chunk.gd <seed> <cx> <cz> <out_path>")
		quit(1)
		return
	var seed: int = args[0].to_int()
	var cx: int = args[1].to_int()
	var cz: int = args[2].to_int()
	var out_path: String = args[3]

	# Warm + apply seed to all generators (must be on main thread).
	BlockAtlas.build()
	# 3D mode follows the same default as the game: ON unless explicitly
	# disabled with MC_CLONE_TERRAIN_3D=0. (Previously this read
	# has_environment(), which was an opt-in check that no longer matches
	# the runtime default.)
	Worldgen.terrain_3d_enabled = OS.get_environment("MC_CLONE_TERRAIN_3D") != "0"
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)  # forces noise warm

	var chunk: Chunk = Worldgen.generate_chunk(cx, cz)
	if Worldgen.terrain_3d_enabled:
		print("[export] using 3D density terrain")

	# Vanilla layout: Blocks[(x*16 + z)*128 + y]
	# Our layout: blocks[y*16*16 + z*16 + x]
	var out: PackedByteArray = PackedByteArray()
	out.resize(32768)
	for x in range(16):
		for z in range(16):
			for y in range(128):
				var our_idx: int = y * 256 + z * 16 + x
				var vanilla_idx: int = (x * 16 + z) * 128 + y
				out[vanilla_idx] = chunk.blocks[our_idx]

	var f: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		printerr("Failed to open %s for write" % out_path)
		quit(1)
		return
	f.store_buffer(out)
	f.close()
	print("Wrote %s (32768 bytes, seed=%d cx=%d cz=%d)" % [out_path, seed, cx, cz])
	quit(0)
