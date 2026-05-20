extends SceneTree

# Dump density values for column (8, *, 8) of chunk (0, 0) at seed=0,
# matching the format of vanilla TerrainRef.java's PER-CELL DENSITY DUMP.
# Side-by-side compare to find where our trilerp diverges from vanilla.


func _init() -> void:
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(0)
	Worldgen.surface_height(0, 0)
	Worldgen3D._ensure_noises(0)

	var grid: PackedFloat64Array = Worldgen3D.density_grid(0, 0)
	var GRID_X: int = 5
	var GRID_Y: int = 17
	var GRID_Z: int = 5

	var target_x: int = 8
	var target_z: int = 8
	var i2: int = target_x / 4  # 2
	var i3: int = target_z / 4  # 2
	var i6: int = target_x % 4  # 0
	var i7: int = target_z % 4  # 0

	print("# === OUR PER-CELL DENSITY DUMP for column (8, *, 8) of chunk ===")
	for i4 in range(16):
		# Same trilerp algo as vanilla
		var d3: float = grid[((i2 + 0) * GRID_Y + (i4 + 0)) * GRID_Z + (i3 + 0)]
		var d4: float = grid[((i2 + 0) * GRID_Y + (i4 + 0)) * GRID_Z + (i3 + 1)]
		var d5: float = grid[((i2 + 1) * GRID_Y + (i4 + 0)) * GRID_Z + (i3 + 0)]
		var d6: float = grid[((i2 + 1) * GRID_Y + (i4 + 0)) * GRID_Z + (i3 + 1)]
		var d7: float = (
			(grid[((i2 + 0) * GRID_Y + (i4 + 1)) * GRID_Z + (i3 + 0)] - d3) * 0.125
		)
		var d8: float = (
			(grid[((i2 + 0) * GRID_Y + (i4 + 1)) * GRID_Z + (i3 + 1)] - d4) * 0.125
		)
		var d9: float = (
			(grid[((i2 + 1) * GRID_Y + (i4 + 0)) * GRID_Z + (i3 + 0)] - d5) * 0.125
		)
		var d10: float = (
			(grid[((i2 + 1) * GRID_Y + (i4 + 1)) * GRID_Z + (i3 + 1)] - d6) * 0.125
		)
		for i5 in range(8):
			var d12: float = d3
			var d13: float = d4
			var d14: float = (d5 - d3) * 0.25
			var d15: float = (d6 - d4) * 0.25
			# Step to i6 (X sub-cell)
			var d12i: float = d12 + i6 * d14
			var d13i: float = d13 + i6 * d15
			var d18: float = (d13i - d12i) * 0.25
			var d17: float = d12i + i7 * d18
			var y: int = i4 * 8 + i5
			print(
				"# y=%3d density=%.3f %s" % [y, d17, "STONE" if d17 > 0 else "AIR"]
			)
			d3 += d7
			d4 += d8
			d5 += d9
			d6 += d10
	quit(0)
