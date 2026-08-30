extends GutTest

# Alpha-source oracle parity (docs/nether-alpha-1.2.6-implementation-plan.md
# §12.1, Batch 0).
#
# tests/fixtures/alpha_source_facts.json is produced by compiling and
# RUNNING decompiled Alpha 1.2.6 classes plus the JDK's own
# java.util.Random — see scripts/dev/internal/alpha_oracle/. That makes it
# an independent oracle rather than a second translation of our own code,
# which is what the plan requires before any Nether generation lands.
#
# Batch 0's job is to prove the pipeline is real and load-bearing, so this
# file checks the fixture against the one port we already ship:
# scripts/world/java_random.gd. Batches 3-4 extend the same fixture with
# density, surface and population facts.
#
# Regenerate the fixture (needs the gitignored vendor tree + a JDK):
#   python3 scripts/dev/internal/alpha_oracle/emit_fixtures.py
#   python3 scripts/dev/internal/alpha_oracle/emit_fixtures.py --check

const _FIXTURE_PATH := "res://tests/fixtures/alpha_source_facts.json"

var _facts: Dictionary = {}
var _provenance: Dictionary = {}


func before_all() -> void:
	var f := FileAccess.open(_FIXTURE_PATH, FileAccess.READ)
	assert_not_null(f, "the oracle fixture is checked in")
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	assert_eq(typeof(parsed), TYPE_DICTIONARY, "the fixture parses as JSON")
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	_facts = (parsed as Dictionary).get("facts", {}) as Dictionary
	_provenance = (parsed as Dictionary).get("_provenance", {}) as Dictionary


# Raw IEEE-754 bits for a double, so parity is exact rather than
# approximate. Mirrors the driver's Double.doubleToRawLongBits.
func _double_bits(value: float) -> int:
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_double(0, value)
	return buf.decode_s64(0)


func _seed_keys() -> Array:
	var jr: Dictionary = _facts.get("java_random", {}) as Dictionary
	var keys: Array = jr.keys()
	keys.sort()
	return keys


# --- Provenance (plan §12.1 requires it travel with the fixture) ---


func test_fixture_records_its_provenance() -> void:
	for field: String in [
		"alpha_version",
		"decompiler",
		"decompiler_caveat",
		"driver_sha256",
		"jdk",
		"seeds",
		"source_chunk_layout",
		"project_chunk_layout",
		"population_rule",
	]:
		assert_true(_provenance.has(field), "provenance records %s" % field)
		assert_ne(str(_provenance.get(field, "")), "", "provenance %s is non-empty" % field)


func test_fixture_covers_the_plan_seed_matrix() -> void:
	# JSON widens every number to a float, so compare as ints.
	var seeds: Array = []
	for raw: Variant in _provenance.get("seeds", []) as Array:
		seeds.append(int(raw))
	for expected: int in [0, 1, -1, 12345, 987654321]:
		assert_true(seeds.has(expected), "seed %d is in the fixture matrix" % expected)
	assert_eq(_seed_keys().size(), 5, "all five seeds produced java_random facts")


# --- JavaRandom parity against the JDK ---


func test_next_int_matches_the_jdk() -> void:
	var jr: Dictionary = _facts.get("java_random", {}) as Dictionary
	for key: String in _seed_keys():
		var expected: Array = (jr[key] as Dictionary)["next_int"] as Array
		var rng := JavaRandom.new(int(key))
		for i: int in range(expected.size()):
			assert_eq(rng.next_int(), int(expected[i]), "seed %s next_int()[%d]" % [key, i])


func test_next_int_bounded_matches_the_jdk() -> void:
	# Bounded draws exercise the rejection loop; a port that skips it
	# drifts only for non-power-of-two bounds, which is exactly where the
	# Nether's nextInt(5)/nextInt(10)/nextInt(120) calls live.
	var jr: Dictionary = _facts.get("java_random", {}) as Dictionary
	for key: String in _seed_keys():
		var bounded: Dictionary = (jr[key] as Dictionary)["next_int_bounded"] as Dictionary
		for bound_key: String in bounded.keys():
			var expected: Array = bounded[bound_key] as Array
			var rng := JavaRandom.new(int(key))
			for i: int in range(expected.size()):
				assert_eq(
					rng.next_int_bounded(int(bound_key)),
					int(expected[i]),
					"seed %s next_int_bounded(%s)[%d]" % [key, bound_key, i]
				)


func test_next_double_matches_the_jdk_bit_for_bit() -> void:
	var jr: Dictionary = _facts.get("java_random", {}) as Dictionary
	for key: String in _seed_keys():
		var expected: Array = (jr[key] as Dictionary)["next_double"] as Array
		var rng := JavaRandom.new(int(key))
		for i: int in range(expected.size()):
			assert_eq(
				_double_bits(rng.next_double()),
				str(expected[i]).to_int(),
				"seed %s next_double()[%d] is bit-identical" % [key, i]
			)


func test_next_long_matches_the_jdk() -> void:
	var jr: Dictionary = _facts.get("java_random", {}) as Dictionary
	for key: String in _seed_keys():
		var expected: Array = (jr[key] as Dictionary)["next_long"] as Array
		var rng := JavaRandom.new(int(key))
		for i: int in range(expected.size()):
			assert_eq(
				rng.next_long(), str(expected[i]).to_int(), "seed %s next_long()[%d]" % [key, i]
			)


# --- Nether facts the later batches consume ---


func test_nether_noise_construction_order_is_recorded() -> void:
	# kj.java draws seven octave generators from one shared Random. The
	# order decides how many Perlin permutation tables each consumes, so
	# Batch 3 must reproduce it exactly; freezing it here means a later
	# edit to the fixture is a deliberate act, not a silent drift.
	var nnc: Dictionary = _facts.get("nether_noise_construction", {}) as Dictionary
	var octaves: Array = []
	for raw: Variant in nnc.get("octaves", []) as Array:
		octaves.append(int(raw))
	assert_eq(octaves, [16, 16, 8, 4, 4, 10, 16], "kj.java constructor octave order")
	var post: Dictionary = nnc.get("post_construction_next_int", {}) as Dictionary
	assert_eq(post.size(), 5, "a post-construction fingerprint per seed")


func test_nether_construction_fingerprint_is_reproducible_from_our_rng() -> void:
	# The fingerprint is "the value the shared Random yields after the
	# seven generators are built". Our JavaRandom can reproduce it once we
	# know how many draws each generator makes, which nf/z fix at
	# 3 doubles + a 256-entry shuffle per octave. Reproducing it here
	# proves our RNG and the JDK stay in step over ~40k draws, not just
	# the first handful.
	var nnc: Dictionary = _facts.get("nether_noise_construction", {}) as Dictionary
	var post: Dictionary = nnc.get("post_construction_next_int", {}) as Dictionary
	for key: String in post.keys():
		var rng := JavaRandom.new(int(key))
		for octaves: int in [16, 16, 8, 4, 4, 10, 16]:
			for _octave: int in range(octaves):
				_consume_one_perlin(rng)
		assert_eq(
			rng.next_int(), int(post[key]), "seed %s post-construction draw matches the JDK" % key
		)


# One z.java (Perlin) constructor: three nextDouble offsets, then a
# Fisher-Yates shuffle of a 256-entry permutation table using
# nextInt(256 - i). Ported here rather than in production code because
# only the oracle comparison needs it until Batch 3 lands the generator.
func _consume_one_perlin(rng: JavaRandom) -> void:
	rng.next_double()
	rng.next_double()
	rng.next_double()
	for i: int in range(256):
		rng.next_int_bounded(256 - i)


func test_perlin_samples_cover_positive_and_negative_chunks() -> void:
	# Negative coordinates are where Java's cast/floor semantics differ
	# from a naive port, so the fixture must carry at least one.
	var ps: Dictionary = _facts.get("perlin_samples", {}) as Dictionary
	var chunks: Array = ps.get("chunks", []) as Array
	assert_true(chunks.size() >= 3, "the fixture samples several chunks")
	var has_negative: bool = false
	for entry: Variant in chunks:
		var pair: Array = entry as Array
		if int(pair[0]) < 0 or int(pair[1]) < 0:
			has_negative = true
	assert_true(has_negative, "a negative-coordinate chunk is sampled")
	var grid: Dictionary = ps.get("grid", {}) as Dictionary
	assert_eq(int(grid.get("size_x", 0)), 5, "coarse grid is 5 wide")
	assert_eq(int(grid.get("size_y", 0)), 17, "coarse grid is 17 tall")
	assert_eq(int(grid.get("size_z", 0)), 5, "coarse grid is 5 deep")


func test_gaussian_facts_are_recorded_for_the_batches_that_need_them() -> void:
	# JavaRandom has no next_gaussian yet. The ghast fireball's 0.4 spread
	# (plan §8.3) and any Gaussian worldgen use will need it, and the
	# cached-pair behaviour is easy to get wrong — so the expected values
	# are captured now even though nothing consumes them yet.
	var jr: Dictionary = _facts.get("java_random", {}) as Dictionary
	for key: String in _seed_keys():
		var g: Array = (jr[key] as Dictionary).get("next_gaussian", []) as Array
		assert_eq(g.size(), 6, "seed %s records a gaussian sequence" % key)
	assert_false(
		JavaRandom.new(0).has_method("next_gaussian"),
		"next_gaussian is still unimplemented — see the Batch 3/9 handoff note"
	)
