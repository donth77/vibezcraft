extends GutTest

# Tests for the WaterFXNative GDExtension class — the C++ port of
# vanilla Alpha 1.2.6's TextureWaterFX (oe.java). The visual effect is
# subjective ("does it look like Alpha water?"), so we test for the
# *structural* properties that matter:
#   1. The native class registers and can be instantiated.
#   2. tick() returns a 256-cell RGBA buffer (16×16 × 4 bytes).
#   3. With a fixed seed, the buffer is byte-deterministic across runs —
#      this is the regression guard if anyone reorders the algorithm.
#   4. After enough ticks, the field becomes non-trivial (the random
#      impulse path actually fires; a flat-zero output would hide bugs).


func test_class_is_registered() -> void:
	assert_true(
		ClassDB.class_exists("WaterFXNative"),
		"WaterFXNative not registered — did the .gdextension load? Rebuild via `scons`."
	)


func test_tick_returns_full_rgba_buffer() -> void:
	var fx = ClassDB.instantiate("WaterFXNative")
	var bytes: PackedByteArray = fx.tick()
	assert_eq(bytes.size(), 16 * 16 * 4, "16×16 RGBA = 1024 bytes")


func test_first_tick_with_zero_buffers_has_constant_blue_channel() -> void:
	# Phase-4 encoding writes B=255 unconditionally regardless of cell
	# value. This catches accidental swaps of the channel order.
	var fx = ClassDB.instantiate("WaterFXNative")
	var bytes: PackedByteArray = fx.tick()
	for i in range(256):
		assert_eq(bytes[i * 4 + 2], 255, "channel B (index 2) is constant 255 at cell %d" % i)


func test_seeded_tick_stream_is_deterministic() -> void:
	var a = ClassDB.instantiate("WaterFXNative")
	var b = ClassDB.instantiate("WaterFXNative")
	a.set_seed(0xDEADBEEF)
	b.set_seed(0xDEADBEEF)
	# Run 20 ticks — long enough that random-impulse paths have fired
	# many times and any divergence in RNG / float math would show up.
	for n in range(20):
		var ba: PackedByteArray = a.tick()
		var bb: PackedByteArray = b.tick()
		assert_eq(ba, bb, "tick %d: identical seeds must produce byte-equal output" % n)


func test_different_seeds_diverge() -> void:
	var a = ClassDB.instantiate("WaterFXNative")
	var b = ClassDB.instantiate("WaterFXNative")
	a.set_seed(1)
	b.set_seed(2)
	# Run a few ticks so the random impulses have time to differ.
	for n in range(15):
		a.tick()
		b.tick()
	var ba: PackedByteArray = a.tick()
	var bb: PackedByteArray = b.tick()
	assert_ne(ba, bb, "different seeds must eventually diverge (RNG actually wired)")


func test_field_becomes_non_zero_after_warmup() -> void:
	# Cold start = all zeros, so first ticks will have R/G near their
	# minimum values (32 / 50). After 100 ticks the random impulses
	# should have populated the field; some cells must read meaningfully
	# above the zero-state encoding.
	var fx = ClassDB.instantiate("WaterFXNative")
	fx.set_seed(42)
	var bytes: PackedByteArray
	for n in range(100):
		bytes = fx.tick()
	var max_r: int = 0
	for i in range(256):
		var r: int = bytes[i * 4 + 0]
		if r > max_r:
			max_r = r
	# Cold-state R is exactly 32. After warmup at least one cell must
	# have read meaningfully above that — proves the impulse → velocity →
	# field path actually moves the buffer off zero.
	assert_gt(max_r, 35, "after warmup, at least one cell shows non-trivial intensity")


func test_reset_returns_field_to_baseline() -> void:
	var fx = ClassDB.instantiate("WaterFXNative")
	fx.set_seed(7)
	for n in range(50):
		fx.tick()
	fx.reset()
	# Resetting wipes all 4 buffers but leaves the RNG seed alone — so
	# the first post-reset tick lands on the cold-start RGB pattern.
	var bytes: PackedByteArray = fx.tick()
	# After one tick from all-zero, every cell's R is still 32 (the
	# 1-tick blur of zeros stays at zero, and cells that haven't received
	# their first impulse stay zero). Any cell deviating means reset()
	# didn't clear all buffers.
	var any_nonzero: bool = false
	for i in range(256):
		if bytes[i * 4 + 0] != 32:
			any_nonzero = true
			break
	assert_false(any_nonzero, "reset() then tick() leaves R=32 (zero-state encoding)")
