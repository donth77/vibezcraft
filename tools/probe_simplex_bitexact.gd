extends SceneTree


func _init() -> void:
	# Compare at seed 1724433623 * 9871 (matches Java reference for temp noise)
	var seed: int = 1724433623 * 9871
	var rng := JavaRandom.new(seed)
	var ng := NoiseOctavesSimplex.create(rng, 4)
	# Sample at exact coords used by Java reference
	for c in [[0, 0], [-100, -100], [-100, 0], [50, 50], [100, 100]]:
		var v: float = ng.sample_2d(float(c[0]), float(c[1]), 0.025, 0.25)
		print("# OURS temp_raw at (%d, %d) = %.6f" % [c[0], c[1], v])
	quit(0)
