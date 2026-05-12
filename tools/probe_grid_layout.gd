extends SceneTree

# Verify that sample_3d_grid writes values to the indices that
# density_grid expects. If we sample noise directly at coord (X, Y, Z)
# and that value equals e_grid[(X * GRID_Y + Y) * GRID_Z + Z]
# (vanilla layout, used by density_grid), the layout matches.


func _init() -> void:
	BlockAtlas.build()
	Worldgen.terrain_3d_enabled = true
	Worldgen.apply_world_seed(0)
	Worldgen.surface_height(0, 0)
	Worldgen3D._ensure_noises(0)

	var GRID_X: int = 5
	var GRID_Y: int = 17
	var GRID_Z: int = 5
	var COORDINATE_SCALE: float = 684.412
	var HEIGHT_SCALE: float = 684.412

	# Fill e_grid via the bulk sample_3d_grid (what density_grid uses)
	var e_grid: PackedFloat64Array = PackedFloat64Array()
	e_grid.resize(GRID_X * GRID_Y * GRID_Z)
	Worldgen3D._e_noise.sample_3d_grid(
		e_grid, 0.0, 0.0, 0.0,
		GRID_X, GRID_Y, GRID_Z,
		COORDINATE_SCALE, HEIGHT_SCALE, COORDINATE_SCALE
	)

	# Check 4 specific (x, y, z) cells. For each, compute index BOTH ways:
	# vanilla layout: (X * GRID_Y + Y) * GRID_Z + Z
	# our-FastNoiseLite layout: (X * GRID_Y + Y) * GRID_Z + Z   (same as vanilla)
	# Z-inner layout: (X * GRID_Z + Z) * GRID_Y + Y  (different)
	#
	# The grid was sampled at sx = (base_x + x) * scale_x, etc.
	# For base=0, scale=684.412: sx at x=0 is 0; at x=1 is 684.412
	#
	# To check layout: sample noise directly at the world coord for cell
	# (X, Y, Z) and compare to grid[index].
	for cell in [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0),
				 Vector3i(0, 0, 1), Vector3i(2, 5, 3), Vector3i(4, 16, 4)]:
		var x: int = cell.x
		var y: int = cell.y
		var z: int = cell.z
		var sx: float = float(x) * COORDINATE_SCALE
		var sy: float = float(y) * HEIGHT_SCALE
		var sz: float = float(z) * COORDINATE_SCALE
		# Compute the 16-octave reverse-FBM noise directly at this coord
		var direct: float = 0.0
		var amp: float = 1.0
		for i in range(16):
			direct += Worldgen3D._e_noise._vanilla_octaves[i].sample_3d(
				sx * amp, sy * amp, sz * amp
			) / amp
			amp /= 2.0
		# Read grid at TWO possible layouts:
		# (a) Y-innermost (matches sample_3d_grid_additive write order: X-Z-Y)
		var idx_a: int = (x * GRID_Z + z) * GRID_Y + y
		# (b) Z-innermost (matches density_grid OUTPUT layout: X-Y-Z)
		var idx_b: int = (x * GRID_Y + y) * GRID_Z + z
		var val_a: float = e_grid[idx_a]
		var val_b: float = e_grid[idx_b]
		print(
			(
				"(X=%d, Y=%d, Z=%d): direct=%.4f  Y-inner[%d]=%.4f (diff=%.4f)  Z-inner[%d]=%.4f (diff=%.4f)"
				% [
					x, y, z, direct,
					idx_a, val_a, direct - val_a,
					idx_b, val_b, direct - val_b
				]
			)
		)
	quit(0)
