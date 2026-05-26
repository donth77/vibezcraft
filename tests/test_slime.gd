# gdlint: disable=max-public-methods
extends GutTest

# Slime mob + slime-chunk RNG tests. Slime.is_slime_chunk is the gate
# that decides which chunks can spawn slimes (vanilla 1-in-10 by
# world seed); it must be (1) deterministic per (seed, chunk_x,
# chunk_z), (2) split chunks ~10%, and (3) scatter evenly so a small
# area still has reachable slime chunks for the player.

const _SLIME: GDScript = preload("res://scripts/entities/slime.gd")


func test_is_slime_chunk_is_deterministic() -> void:
	# Same seed + coord must always return the same answer.
	for i in range(20):
		var x: int = randi_range(-100, 100)
		var z: int = randi_range(-100, 100)
		var first: bool = _SLIME.is_slime_chunk(12345, x, z)
		var second: bool = _SLIME.is_slime_chunk(12345, x, z)
		assert_eq(first, second, "is_slime_chunk(%d, %d) flipped on repeat" % [x, z])


func test_is_slime_chunk_changes_with_seed() -> void:
	# Switching the world seed should produce a DIFFERENT 1-in-10 set.
	# Not every chunk needs to flip; the test asserts that ~half do
	# (the two seeds are independent samples over the chunk space).
	var diffs: int = 0
	for x in range(-10, 10):
		for z in range(-10, 10):
			var a: bool = _SLIME.is_slime_chunk(12345, x, z)
			var b: bool = _SLIME.is_slime_chunk(54321, x, z)
			if a != b:
				diffs += 1
	# 400 chunks sampled. With both seeds at ~10% pass, ~18% should
	# flip on any one seed change (a XOR b). The actual diff count
	# depends on the hash mix — we only require some divergence so a
	# bug that ignored the seed entirely would fail.
	assert_gt(diffs, 20, "different seeds produce different slime chunks")


func test_is_slime_chunk_distribution() -> void:
	# Vanilla nextInt(10) == 0 → 1-in-10 chunks. Our hash isn't
	# bit-exact to JavaRandom, but it MUST split chunks roughly 10%.
	# A 50×50 (=2500) sample should land in [180, 320] passing
	# chunks — wider than ±3σ so the test isn't flaky.
	var passing: int = 0
	for x in range(0, 50):
		for z in range(0, 50):
			if _SLIME.is_slime_chunk(12345, x, z):
				passing += 1
	assert_between(passing, 180, 320, "slime chunk pass rate ~10%%, got %d/2500" % passing)


func test_is_slime_chunk_finds_at_least_one_in_small_area() -> void:
	# A player exploring a 7×7 chunk area (~112 m square) should find
	# at least one slime chunk most of the time. We assert across a
	# few different origin offsets to keep the test deterministic but
	# representative.
	var found: int = 0
	for origin in [Vector2i(0, 0), Vector2i(50, 50), Vector2i(-30, 100), Vector2i(7, -7)]:
		var hits: int = 0
		for dx in range(-3, 4):
			for dz in range(-3, 4):
				if _SLIME.is_slime_chunk(12345, origin.x + dx, origin.y + dz):
					hits += 1
		if hits > 0:
			found += 1
	assert_gte(found, 3, "≥3 of 4 sampled 7×7 areas should contain a slime chunk")
