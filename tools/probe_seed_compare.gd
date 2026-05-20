extends SceneTree


func _init() -> void:
	# Sanity check at seed=2012828372 — compare to Java values
	var rng := JavaRandom.new(2012828372)
	var p := NoisePerlin.new(rng)
	print(
		(
			"# z(seed=2012828372): a=%.17f b=%.17f c=%.17f"
			% [p._x_offset, p._y_offset, p._z_offset]
		)
	)
	# Re-create with fresh RNG for sample test
	var rng1 := JavaRandom.new(2012828372)
	var p1 := NoisePerlin.new(rng1)
	print("# z(seed=2012828372).a(0,0,0) = %.17f" % p1.sample_3d(0.0, 0.0, 0.0))

	# Chained 16-octave depth at chunk (0,0)
	var rng2 := JavaRandom.new(2012828372)
	var k := NoiseOctaves.create_vanilla_chained(rng2, 16)
	var l := NoiseOctaves.create_vanilla_chained(rng2, 16)
	var m := NoiseOctaves.create_vanilla_chained(rng2, 8)
	var n := NoiseOctaves.create_vanilla_chained(rng2, 4)
	var o := NoiseOctaves.create_vanilla_chained(rng2, 4)
	var a := NoiseOctaves.create_vanilla_chained(rng2, 10)
	var b := NoiseOctaves.create_vanilla_chained(rng2, 16)  # depth
	print("# CHAINED seed=2012828372: depth.a(0,0) = %.17f" % b.sample_2d(0.0, 0.0))

	# Single 16-octave e
	var rng3 := JavaRandom.new(2012828372)
	var e := NoiseOctaves.create_vanilla_chained(rng3, 16)
	print("# CHAINED seed=2012828372: e.a(0,0) = %.17f" % e.sample_2d(0.0, 0.0))
	quit(0)
