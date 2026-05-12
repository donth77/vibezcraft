extends SceneTree


func _init() -> void:
	# Build the chained e noise stack for seed 2012828372
	var rng := JavaRandom.new(2012828372)
	var e := NoiseOctaves.create_vanilla_chained(rng, 16)

	# Manually sum across 16 octaves at coord (X=0, Y=8 grid, Z=0)
	# Per octave i with amp = 2^-i:
	#   coord = (X * scale * amp, Y * scale * amp, Z * scale * amp)
	# Sum: sample / amp = sample * 2^i
	var manual_sum: float = 0.0
	var amp: float = 1.0
	for i in range(16):
		var coord_x: float = 0.0  # X=0 always
		var coord_y: float = 8.0 * 684.412 * amp  # Y=8 in grid
		var coord_z: float = 0.0  # Z=0 always
		var s: float = e._vanilla_octaves[i].sample_3d(coord_x, coord_y, coord_z)
		manual_sum += s / amp
		print(
			(
				"# octave %2d: amp=%.6f sample=%.6f contribution=%.4f cumsum=%.4f"
				% [i, amp, s, s / amp, manual_sum]
			)
		)
		amp /= 2.0

	# Now extract the same cell from the bulk grid call
	var grid: PackedFloat64Array = PackedFloat64Array()
	grid.resize(5 * 17 * 5)
	e.sample_3d_grid(grid, 0.0, 0.0, 0.0, 5, 17, 5, 684.412, 684.412, 684.412)
	# Vanilla layout: idx = X * (Z*Y) + Z * Y + Y
	# For (X=0, Y=8, Z=0): idx = 0*85 + 0*17 + 8 = 8
	var bulk_val: float = grid[8]
	print("# manual sum across 16 octaves: %.4f" % manual_sum)
	print("# bulk grid [X=0,Y=8,Z=0]:      %.4f" % bulk_val)
	print("# diff: %.4f" % (manual_sum - bulk_val))
	quit(0)
