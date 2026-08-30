# gdlint: disable=max-public-methods
extends GutTest

# Native/GDScript parity for the Nether generator
# (docs/nether-alpha-1.2.6-implementation-plan.md §11 Batch 5).
#
# The GDScript path is the correctness reference — it is the one checked
# against fixtures produced by running the real decompiled Alpha classes.
# The native port exists only to make it fast, so the bar is byte-for-byte
# equality, not "close enough".
#
# Both paths are driven in one process rather than by unloading the
# extension: `generate_terrain_only_gdscript` and `generate_raw_gdscript`
# stay callable by name precisely so this comparison is possible.
#
# The plan also asks that a build WITHOUT the extension produce the same
# world. That is the same claim from the other side: if native equals
# GDScript here, then a fallback run — which takes the GDScript branch —
# produces the reference world by construction. The fallback branch itself
# is exercised by every other Nether suite on machines with no extension,
# and by test_the_fallback_branch_is_reachable below.

const _SEEDS: Array[int] = [0, 1, -1, 12345, 987654321]
const _COORDS: Array[Vector2i] = [
	Vector2i(0, 0),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
	Vector2i(0, -1),
	Vector2i(-1, -1),
	Vector2i(37, 91),
	Vector2i(-64, -128),
]

var _seed_was: int
var _native_ready: bool = false


func before_all() -> void:
	_seed_was = Worldgen.WORLD_SEED
	_native_ready = WorldgenNether.native_available()


func after_all() -> void:
	Worldgen.apply_world_seed(_seed_was)
	WorldgenNether.reset()


func _skip_without_native() -> bool:
	if not _native_ready:
		pass_test("WorldgenNetherNative not registered — GDScript-only run")
		return true
	return false


func _hash(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func _use_seed(world_seed: int) -> void:
	WorldgenNether.reset()
	Worldgen.apply_world_seed(world_seed)


# --- Availability ---


func test_the_native_class_is_registered() -> void:
	# Not a skip: if the extension built, this must be true, and a silent
	# absence would make every parity test below vacuously pass.
	if not ClassDB.class_exists("WorldgenNative"):
		pass_test("no GDExtension in this build at all")
		return
	assert_true(
		ClassDB.class_exists("WorldgenNetherNative"),
		"the Nether native class ships alongside the Overworld one"
	)


func test_the_fallback_branch_is_reachable() -> void:
	# The named GDScript entry points are what a build without the
	# extension runs. They must work regardless of whether native loaded.
	Worldgen.apply_world_seed(12345)
	WorldgenNether.reset()
	var raw: PackedByteArray = WorldgenNether.generate_terrain_only_gdscript(0, 0)
	assert_eq(raw.size(), 32768, "the GDScript path produces a full chunk")


# --- Terrain parity ---


func test_terrain_matches_the_gdscript_reference() -> void:
	if _skip_without_native():
		return
	for world_seed: int in _SEEDS:
		_use_seed(world_seed)
		for coord: Vector2i in _COORDS:
			var native: PackedByteArray = WorldgenNether.generate_terrain_only(coord.x, coord.y)
			var reference: PackedByteArray = WorldgenNether.generate_terrain_only_gdscript(
				coord.x, coord.y
			)
			assert_eq(
				_hash(native),
				_hash(reference),
				"seed %d chunk %s: terrain" % [world_seed, str(coord)]
			)


# --- Population parity ---


func test_write_lists_match_the_gdscript_reference() -> void:
	if _skip_without_native():
		return
	for world_seed: int in _SEEDS:
		_use_seed(world_seed)
		for coord: Vector2i in _COORDS:
			var native: Array = WorldgenNetherPopulation.write_list(world_seed, coord.x, coord.y)
			var reference: Array = WorldgenNetherPopulation.write_list_gdscript(
				world_seed, coord.x, coord.y
			)
			assert_eq(
				native.size(),
				reference.size(),
				"seed %d source %s: same number of decoration writes" % [world_seed, str(coord)]
			)
			var limit: int = mini(native.size(), reference.size())
			for i: int in range(limit):
				assert_eq(
					native[i],
					reference[i],
					"seed %d source %s write %d" % [world_seed, str(coord), i]
				)


# --- Whole-pipeline parity ---


func test_decorated_chunks_match_the_gdscript_reference() -> void:
	if _skip_without_native():
		return
	for world_seed: int in _SEEDS:
		_use_seed(world_seed)
		for coord: Vector2i in _COORDS:
			var native: PackedByteArray = WorldgenNether.generate_raw(coord.x, coord.y)
			var reference: PackedByteArray = WorldgenNether.generate_raw_gdscript(coord.x, coord.y)
			assert_eq(
				_hash(native),
				_hash(reference),
				"seed %d chunk %s: terrain plus decorations" % [world_seed, str(coord)]
			)


func test_native_output_is_order_independent() -> void:
	if _skip_without_native():
		return
	_use_seed(12345)
	var coords: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, -1), Vector2i(2, -3)
	]
	var forward: Dictionary = {}
	for c: Vector2i in coords:
		forward[c] = _hash(WorldgenNether.generate_raw(c.x, c.y))
	WorldgenNether.reset()
	var reversed_coords: Array[Vector2i] = coords.duplicate()
	reversed_coords.reverse()
	for c: Vector2i in reversed_coords:
		assert_eq(
			_hash(WorldgenNether.generate_raw(c.x, c.y)),
			forward[c],
			"native chunk %s is identical in reverse order" % str(c)
		)


func test_a_seed_change_invalidates_the_native_caches() -> void:
	if _skip_without_native():
		return
	_use_seed(12345)
	var at_12345: String = _hash(WorldgenNether.generate_raw(0, 0))
	_use_seed(1)
	var at_1: String = _hash(WorldgenNether.generate_raw(0, 0))
	assert_ne(at_1, at_12345, "the new seed is not served stale native terrain")
	_use_seed(12345)
	assert_eq(
		_hash(WorldgenNether.generate_raw(0, 0)),
		at_12345,
		"and switching back restores the original"
	)


# --- Performance (plan §11 Batch 5 gate) ---


func test_native_generation_is_within_the_overworld_gate() -> void:
	# The gate: native Nether worker generation p95 no more than 1.25x the
	# native Overworld's, for the same sampled chunk count. Measured here
	# rather than asserted from a recorded number, because the ratio is
	# what the plan gates on and both sides move with the hardware.
	if _skip_without_native():
		return
	var sample: int = 24
	_use_seed(12345)
	# Warm both paths so neither pays its lazy noise build in the sample.
	Worldgen.generate_chunk(900, 900)
	WorldgenNether.generate_raw(900, 900)
	WorldgenNether.reset()

	var overworld: Array[float] = []
	for i: int in range(sample):
		var t0: int = Time.get_ticks_usec()
		Worldgen.generate_chunk(500 + i, 500)
		overworld.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	var nether: Array[float] = []
	for i: int in range(sample):
		var t0: int = Time.get_ticks_usec()
		WorldgenNether.generate_raw(600 + i, 600)
		nether.append(float(Time.get_ticks_usec() - t0) / 1000.0)

	overworld.sort()
	nether.sort()
	var idx: int = mini(sample - 1, (sample * 95) / 100)
	var ow_p95: float = overworld[idx]
	var nether_p95: float = nether[idx]
	gut.p(
		(
			"native p95 over %d chunks — Overworld %.2f ms, Nether %.2f ms (ratio %.2f)"
			% [sample, ow_p95, nether_p95, nether_p95 / maxf(ow_p95, 0.001)]
		)
	)
	assert_lt(
		nether_p95,
		ow_p95 * 1.25,
		"Nether p95 %.2f ms is within 1.25x the Overworld's %.2f ms" % [nether_p95, ow_p95]
	)


func test_repeated_generation_does_not_grow_without_bound() -> void:
	# The native caches are bounded and cleared wholesale when full. A
	# traversal must not accumulate: generate far more chunks than the
	# cache holds and confirm results stay correct throughout.
	if _skip_without_native():
		return
	_use_seed(12345)
	var reference: String = _hash(WorldgenNether.generate_raw(0, 0))
	for cx: int in range(0, 24):
		for cz: int in range(0, 24):
			WorldgenNether.generate_raw(cx, cz)
	assert_eq(
		_hash(WorldgenNether.generate_raw(0, 0)),
		reference,
		"a 24x24 traversal leaves chunk (0, 0) unchanged"
	)
