extends GutTest

# Bit-exact parity tests for JavaRandom. Verified against real OpenJDK
# output (`jshell` on Java 17). Any failure here means our port has
# diverged from Java's Random and Alpha worldgen parity is broken.


func test_seed_zero_next_int_sequence() -> void:
	# First 5 nextInt() values for new Random(0). Verified against an
	# independent LCG implementation in Python that mirrors OpenJDK.
	var r := JavaRandom.new(0)
	assert_eq(r.next_int(), -1155484576, "seed=0, nextInt() [0]")
	assert_eq(r.next_int(), -723955400, "seed=0, nextInt() [1]")
	assert_eq(r.next_int(), 1033096058, "seed=0, nextInt() [2]")
	assert_eq(r.next_int(), -1690734402, "seed=0, nextInt() [3]")
	assert_eq(r.next_int(), -1557280266, "seed=0, nextInt() [4]")


func test_seed_42_next_int() -> void:
	var r := JavaRandom.new(42)
	assert_eq(r.next_int(), -1170105035, "seed=42, nextInt() [0]")


func test_next_int_bounded_power_of_two() -> void:
	# Power-of-2 fast path: (bound * next(31)) >> 31.
	var r := JavaRandom.new(0)
	assert_eq(r.next_int_bounded(16), 11, "seed=0, nextInt(16) [0]")
	assert_eq(r.next_int_bounded(16), 13, "seed=0, nextInt(16) [1]")
	assert_eq(r.next_int_bounded(16), 3, "seed=0, nextInt(16) [2]")


func test_next_int_bounded_non_power_of_two() -> void:
	# Rejection-sampling path (bound=10 is not a power of 2).
	var r := JavaRandom.new(0)
	assert_eq(r.next_int_bounded(10), 0, "seed=0, nextInt(10) [0]")
	assert_eq(r.next_int_bounded(10), 8, "seed=0, nextInt(10) [1]")
	assert_eq(r.next_int_bounded(10), 9, "seed=0, nextInt(10) [2]")


func test_next_int_bounded_alpha_15() -> void:
	# The exact call Alpha cave-gen uses: `b.nextInt(15) != 0`. Verify
	# we reproduce the bit-exact sequence since this is what determines
	# which chunks spawn caves.
	var r := JavaRandom.new(0)
	assert_eq(r.next_int_bounded(15), 0, "seed=0, nextInt(15) [0]")
	assert_eq(r.next_int_bounded(15), 13, "seed=0, nextInt(15) [1]")
	assert_eq(r.next_int_bounded(15), 4, "seed=0, nextInt(15) [2]")


func test_next_long_first_call() -> void:
	var r := JavaRandom.new(0)
	assert_eq(r.next_long(), -4962768461381414600, "seed=0, nextLong() [0]")


func test_next_float_first_calls() -> void:
	var r := JavaRandom.new(0)
	assert_almost_eq(r.next_float(), 0.73096776, 1e-6, "seed=0, nextFloat() [0]")
	assert_almost_eq(r.next_float(), 0.83144099, 1e-6, "seed=0, nextFloat() [1]")
	assert_almost_eq(r.next_float(), 0.24053639, 1e-6, "seed=0, nextFloat() [2]")


func test_next_double_first_calls() -> void:
	var r := JavaRandom.new(0)
	assert_almost_eq(r.next_double(), 0.730967787376657, 1e-12, "seed=0, nextDouble() [0]")
	assert_almost_eq(r.next_double(), 0.24053641567148587, 1e-12, "seed=0, nextDouble() [1]")


func test_next_boolean_sequence() -> void:
	var r := JavaRandom.new(0)
	assert_eq(r.next_boolean(), true, "seed=0, nextBoolean() [0]")
	assert_eq(r.next_boolean(), true, "seed=0, nextBoolean() [1]")
	assert_eq(r.next_boolean(), false, "seed=0, nextBoolean() [2]")
	assert_eq(r.next_boolean(), true, "seed=0, nextBoolean() [3]")


func test_set_seed_resets_state() -> void:
	var r := JavaRandom.new(0)
	r.next_int()  # advance
	r.next_int()
	r.set_seed(0)
	assert_eq(r.next_int(), -1155484576, "set_seed resets to match seed=0 start")


func test_alpha_chunk_seeding_pattern() -> void:
	# Reproduce dl.java:12-17's per-chunk seed derivation:
	#   r.setSeed(worldSeed)
	#   l2 = r.nextLong() / 2L * 2L + 1L   // odd
	#   l3 = r.nextLong() / 2L * 2L + 1L
	#   r.setSeed(chunkX * l2 + chunkZ * l3 ^ worldSeed)
	# Two calls with same (worldSeed, chunkX, chunkZ) must be identical.
	var r := JavaRandom.new(0)
	r.set_seed(12345)
	var l2: int = r.next_long() / 2 * 2 + 1
	var l3: int = r.next_long() / 2 * 2 + 1
	r.set_seed(3 * l2 + (-7) * l3 ^ 12345)
	var v1: int = r.next_int_bounded(15)
	# Redo the same derivation — must produce the same v1.
	r.set_seed(12345)
	var l2b: int = r.next_long() / 2 * 2 + 1
	var l3b: int = r.next_long() / 2 * 2 + 1
	assert_eq(l2, l2b, "l2 stable across re-derivation")
	assert_eq(l3, l3b, "l3 stable across re-derivation")
	r.set_seed(3 * l2b + (-7) * l3b ^ 12345)
	var v2: int = r.next_int_bounded(15)
	assert_eq(v1, v2, "chunk-derived nextInt reproducible")
