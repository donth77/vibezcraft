extends SceneTree

# Sample NoisePerlin + NoiseOctaves at the same coords as the Java
# reference (NoiseRef.java) and dump values. Side-by-side diff tells us
# exactly where our port diverges from vanilla.


func _init() -> void:
	# === Block 1: NoisePerlin offsets for seed=0 ===
	var rng := JavaRandom.new(0)
	var p := NoisePerlin.new(rng)
	print("# z(seed=0): a=%.17f b=%.17f c=%.17f" % [p._x_offset, p._y_offset, p._z_offset])

	# === Block 2: NoisePerlin sample at known coords ===
	# Re-create with fresh RNG so the perm table is the same as Block 1.
	var rng1 := JavaRandom.new(0)
	var p1 := NoisePerlin.new(rng1)
	var test_coords: Array = [0.0, 0.1, 0.5, 1.0, 1.5, 100.0, 100.5, 200.7, -50.3]
	for x: float in test_coords:
		for y: float in test_coords:
			var v: float = p1.sample_3d(x, y, 0.0)
			print("# z(0).a(%.4f, %.4f, 0.0) = %.17f" % [x, y, v])

	# === Block 3: NoiseOctaves single-point, 16-octave ===
	var rng2 := JavaRandom.new(0)
	var depth := NoiseOctaves.create_vanilla_chained(rng2, 16)
	var xs: Array = [0.0, 200.0, 800.0, 3200.0, 16000.0, -200.0]
	for x: float in xs:
		for y: float in xs:
			var v: float = depth.sample_2d(x, y)
			print("# nf(seed=0,16oct).a(%.1f, %.1f) = %.17f" % [x, y, v])

	# === Block 4: Full vanilla 8-noise stack chained ===
	var rng3 := JavaRandom.new(0)
	var k := NoiseOctaves.create_vanilla_chained(rng3, 16)  # e
	var l := NoiseOctaves.create_vanilla_chained(rng3, 16)  # f
	var m := NoiseOctaves.create_vanilla_chained(rng3, 8)  # selector
	var n := NoiseOctaves.create_vanilla_chained(rng3, 4)  # beach
	var o := NoiseOctaves.create_vanilla_chained(rng3, 4)  # soil
	var a := NoiseOctaves.create_vanilla_chained(rng3, 10)  # amp
	var b := NoiseOctaves.create_vanilla_chained(rng3, 16)  # depth
	var c := NoiseOctaves.create_vanilla_chained(rng3, 8)  # forest
	print("# CHAINED seed=0:")
	print("#   e.a(0,0) = %.17f" % k.sample_2d(0.0, 0.0))
	print("#   e.a(200,200) = %.17f" % k.sample_2d(200.0, 200.0))
	print("#   f.a(0,0) = %.17f" % l.sample_2d(0.0, 0.0))
	print("#   selector.a(0,0) = %.17f" % m.sample_2d(0.0, 0.0))
	print("#   beach.a(0,0) = %.17f" % n.sample_2d(0.0, 0.0))
	print("#   soil.a(0,0) = %.17f" % o.sample_2d(0.0, 0.0))
	print("#   amplitude.a(0,0) = %.17f" % a.sample_2d(0.0, 0.0))
	print("#   depth.a(0,0) = %.17f" % b.sample_2d(0.0, 0.0))
	print("#   depth.a(200,200) = %.17f" % b.sample_2d(200.0, 200.0))
	print("#   depth.a(800,800) = %.17f" % b.sample_2d(800.0, 800.0))
	print("#   forest.a(0,0) = %.17f" % c.sample_2d(0.0, 0.0))

	# === Block 5: Depth wide sample (same as Java) ===
	var rng4 := JavaRandom.new(0)
	var k2 := NoiseOctaves.create_vanilla_chained(rng4, 16)
	var l2 := NoiseOctaves.create_vanilla_chained(rng4, 16)
	var m2 := NoiseOctaves.create_vanilla_chained(rng4, 8)
	var n2 := NoiseOctaves.create_vanilla_chained(rng4, 4)
	var o2 := NoiseOctaves.create_vanilla_chained(rng4, 4)
	var a2 := NoiseOctaves.create_vanilla_chained(rng4, 10)
	var b2 := NoiseOctaves.create_vanilla_chained(rng4, 16)
	var dmin: float = INF
	var dmax: float = -INF
	var dsum: float = 0.0
	var count: int = 0
	var positive: int = 0
	for cx in range(-16, 16):
		for cz in range(-16, 16):
			var nx: float = float(cx * 4 + 2) * 200.0
			var nz: float = float(cz * 4 + 2) * 200.0
			var v: float = b2.sample_2d(nx, nz)
			if v < dmin:
				dmin = v
			if v > dmax:
				dmax = v
			dsum += v
			count += 1
			if v > 0:
				positive += 1
	print("# DEPTH WIDE SAMPLE seed=0, 32x32 chunks, scale 200:")
	print(
		(
			"#   min=%.4f max=%.4f mean=%.4f positive=%d/%d (%.1f%%)"
			% [dmin, dmax, dsum / count, positive, count, 100.0 * positive / count]
		)
	)
	quit(0)
