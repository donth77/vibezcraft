extends SceneTree


func _init() -> void:
	# Build NoisePerlin at seed 2012828372
	var rng := JavaRandom.new(2012828372)
	var p := NoisePerlin.new(rng)
	# For one octave, sample bulk grid + point sample at same coords.
	# They should match bit-exact.
	var grid: PackedFloat64Array = PackedFloat64Array()
	grid.resize(5 * 17 * 5)
	# Use vanilla scale parameters (octave 0 = amp 1.0)
	p.sample_3d_grid_additive(grid, 0.0, 0.0, 0.0, 5, 17, 5, 684.412, 684.412, 684.412, 1.0)
	# Read at (X=0, Y=8, Z=0) — vanilla layout idx = X*Z*Y + Z*Y + Y = 0*5*17 + 0*17 + 8 = 8
	var bulk_val: float = grid[8]
	# Direct point sample at same world coord
	var sx: float = 0.0 * 684.412
	var sy: float = 8.0 * 684.412
	var sz: float = 0.0 * 684.412
	var point_val: float = p.sample_3d(sx, sy, sz)
	print("Bulk grid[X=0,Y=8,Z=0] = %.6f" % bulk_val)
	print("Point sample(0, 5475, 0) = %.6f" % point_val)
	print("Difference: %.6f" % (bulk_val - point_val))

	# Test more cells
	for ty in [0, 1, 2, 8, 16]:
		var idx: int = ty
		var b: float = grid[idx]
		var pt: float = p.sample_3d(0.0, float(ty) * 684.412, 0.0)
		print("Y=%d: bulk=%.4f point=%.4f diff=%.4f" % [ty, b, pt, b - pt])
	quit(0)
