extends SceneTree


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed: int = args[0].to_int() if args.size() > 0 else 806710720
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(seed)
	Worldgen.surface_height(0, 0)

	# Sample a 32x32 block region. Print biome per cell. Look for cell-to-
	# cell alternation that would cause patchy snow_layer.
	print("Biome map across 32×32 blocks at chunk (0,0). C=cold (TAIGA/TUNDRA/ICE_D)")
	var biome_chars: Dictionary = {
		Worldgen3D.Biome.RAINFOREST: "R",
		Worldgen3D.Biome.SWAMPLAND: "W",
		Worldgen3D.Biome.SEASONAL_FOREST: "S",
		Worldgen3D.Biome.FOREST: "F",
		Worldgen3D.Biome.SAVANNA: "V",
		Worldgen3D.Biome.SHRUBLAND: "H",
		Worldgen3D.Biome.TAIGA: "C",
		Worldgen3D.Biome.DESERT: "D",
		Worldgen3D.Biome.PLAINS: "P",
		Worldgen3D.Biome.ICE_DESERT: "C",
		Worldgen3D.Biome.TUNDRA: "C"
	}
	for x in range(32):
		var line: String = ""
		for z in range(32):
			var b: int = Worldgen3D.biome_at(float(x), float(z))
			line += biome_chars.get(b, "?")
		print(line)

	var counts: Dictionary = {}
	for x in range(-100, 100, 4):
		for z in range(-100, 100, 4):
			var b: int = Worldgen3D.biome_at(float(x), float(z))
			counts[b] = counts.get(b, 0) + 1
	print("\nBiome distribution across 200×200/4 area:")
	var keys = counts.keys()
	keys.sort_custom(func(a, b): return counts[a] > counts[b])
	for k: int in keys:
		var name: String = Worldgen3D.Biome.keys()[k]
		print("  %s: %d" % [name, counts[k]])
	quit(0)
