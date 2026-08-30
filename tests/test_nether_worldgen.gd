# gdlint: disable=max-public-methods
extends GutTest

# Nether generation properties that are NOT about matching the oracle
# (docs/nether-alpha-1.2.6-implementation-plan.md §6, Batch 3).
#
# tests/test_nether_worldgen_oracle.gd proves the bytes are right.
# This file proves the things the oracle cannot: that generation is
# deterministic and order-independent, that it is safe to run on a worker
# thread, that the Alpha->project remap is correct and total, and that
# the terrain has the structural properties the dimension depends on —
# a sealed bedrock shell, a lava sea, and no Overworld blocks leaking in.

const _SEEDS: Array[int] = [0, 1, -1, 12345, 987654321]

var _seed_was: int


func before_all() -> void:
	_seed_was = Worldgen.WORLD_SEED


func after_all() -> void:
	Worldgen.apply_world_seed(_seed_was)
	WorldgenNether.reset()


func _hash(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


# --- Determinism and order independence ---


func test_the_same_chunk_generates_identically_twice() -> void:
	Worldgen.apply_world_seed(12345)
	var a: PackedByteArray = WorldgenNether.generate_raw(3, -7)
	var b: PackedByteArray = WorldgenNether.generate_raw(3, -7)
	assert_eq(a, b, "repeat generation is byte-identical")


func test_generation_is_independent_of_request_order() -> void:
	# The plan's hard requirement: a chunk must not depend on which of its
	# neighbours happened to generate first. Nether caves reach eight
	# chunks in every direction, so this is where it would break.
	Worldgen.apply_world_seed(12345)
	var coords: Array[Vector2i] = [
		Vector2i(0, 0),
		Vector2i(1, 0),
		Vector2i(0, 1),
		Vector2i(-1, 0),
		Vector2i(0, -1),
		Vector2i(-1, -1),
		Vector2i(2, 2),
		Vector2i(-3, 4),
	]
	var forward: Dictionary = {}
	for c: Vector2i in coords:
		forward[c] = _hash(WorldgenNether.generate_raw(c.x, c.y))

	var reversed_coords: Array[Vector2i] = coords.duplicate()
	reversed_coords.reverse()
	for c: Vector2i in reversed_coords:
		assert_eq(
			_hash(WorldgenNether.generate_raw(c.x, c.y)),
			forward[c],
			"chunk %s is identical in reverse order" % str(c)
		)

	# A deliberately scrambled order, not just the reverse.
	for c: Vector2i in [
		Vector2i(2, 2), Vector2i(0, 1), Vector2i(-3, 4), Vector2i(0, 0), Vector2i(-1, -1)
	]:
		assert_eq(
			_hash(WorldgenNether.generate_raw(c.x, c.y)),
			forward[c],
			"chunk %s is identical in scrambled order" % str(c)
		)


func test_a_five_by_five_region_is_order_independent() -> void:
	# Row-major against spiral, over a region wide enough that cave worms
	# from every source chunk overlap.
	Worldgen.apply_world_seed(1)
	var row_major: Dictionary = {}
	for cx: int in range(-2, 3):
		for cz: int in range(-2, 3):
			row_major[Vector2i(cx, cz)] = _hash(WorldgenNether.generate_raw(cx, cz))
	var spiral: Array[Vector2i] = []
	for ring: int in range(0, 3):
		for cx: int in range(-ring, ring + 1):
			for cz: int in range(-ring, ring + 1):
				var c := Vector2i(cx, cz)
				if maxi(absi(cx), absi(cz)) == ring and not spiral.has(c):
					spiral.append(c)
	assert_eq(spiral.size(), 25, "the spiral covers the whole region")
	for c: Vector2i in spiral:
		assert_eq(
			_hash(WorldgenNether.generate_raw(c.x, c.y)),
			row_major[c],
			"chunk %s matches its row-major result" % str(c)
		)


func test_different_seeds_produce_different_terrain() -> void:
	var seen: Dictionary = {}
	for world_seed: int in _SEEDS:
		Worldgen.apply_world_seed(world_seed)
		var h: String = _hash(WorldgenNether.generate_raw(0, 0))
		assert_false(seen.has(h), "seed %d produces its own terrain" % world_seed)
		seen[h] = world_seed


func test_negative_coordinates_generate_without_wrapping() -> void:
	# Java's cast/floor semantics differ from a naive port at negative
	# coordinates, and the per-chunk seed multiplies by them directly.
	Worldgen.apply_world_seed(12345)
	var positive: String = _hash(WorldgenNether.generate_raw(64, 128))
	var negative: String = _hash(WorldgenNether.generate_raw(-64, -128))
	assert_ne(positive, negative, "mirrored coordinates are not the same chunk")
	var mixed: String = _hash(WorldgenNether.generate_raw(-64, 128))
	assert_ne(mixed, positive, "sign of X matters")
	assert_ne(mixed, negative, "sign of Z matters")


# --- Structure ---


func test_the_bedrock_shell_seals_the_floor_and_roof() -> void:
	# The dimension is unplayable without this: y=0 and y=127 must never
	# be open, or the player falls out of the world.
	for world_seed: int in _SEEDS:
		Worldgen.apply_world_seed(world_seed)
		var raw: PackedByteArray = WorldgenNether.generate_raw(0, 0)
		for x: int in range(16):
			for z: int in range(16):
				assert_eq(
					raw[WorldgenNether.alpha_index(x, 0, z)],
					WorldgenNether.ALPHA_BEDROCK,
					"seed %d: floor at (%d, %d)" % [world_seed, x, z]
				)
				assert_eq(
					raw[WorldgenNether.alpha_index(x, 127, z)],
					WorldgenNether.ALPHA_BEDROCK,
					"seed %d: roof at (%d, %d)" % [world_seed, x, z]
				)


func test_caves_never_breach_the_bedrock_bands() -> void:
	# ju.java clamps carving to Y 1..119. Anything outside that would eat
	# into the shell the test above depends on.
	Worldgen.apply_world_seed(987654321)
	for coord: Vector2i in [Vector2i(0, 0), Vector2i(5, -3), Vector2i(-9, 12)]:
		var raw: PackedByteArray = WorldgenNether.generate_raw(coord.x, coord.y)
		for x: int in range(16):
			for z: int in range(16):
				assert_ne(
					raw[WorldgenNether.alpha_index(x, 0, z)],
					WorldgenNether.ALPHA_AIR,
					"chunk %s: no hole in the floor" % str(coord)
				)


func test_terrain_contains_only_the_ids_the_nether_defines() -> void:
	# A stray Overworld id here would mean the port picked up the wrong
	# block constant somewhere.
	var allowed: Array[int] = [
		# Terrain.
		WorldgenNether.ALPHA_AIR,
		WorldgenNether.ALPHA_BEDROCK,
		WorldgenNether.ALPHA_LAVA_STILL,
		WorldgenNether.ALPHA_GRAVEL,
		WorldgenNether.ALPHA_NETHERRACK,
		WorldgenNether.ALPHA_SOUL_SAND,
		# Population (Batch 4).
		WorldgenNether.ALPHA_LAVA_FLOWING,
		WorldgenNether.ALPHA_FIRE,
		WorldgenNether.ALPHA_GLOWSTONE,
		WorldgenNether.ALPHA_MUSHROOM_BROWN,
		WorldgenNether.ALPHA_MUSHROOM_RED,
	]
	for world_seed: int in _SEEDS:
		Worldgen.apply_world_seed(world_seed)
		for coord: Vector2i in [Vector2i(0, 0), Vector2i(-1, -1), Vector2i(37, 91)]:
			var raw: PackedByteArray = WorldgenNether.generate_raw(coord.x, coord.y)
			for b: int in raw:
				assert_true(
					allowed.has(b),
					"seed %d chunk %s: unexpected Alpha id %d" % [world_seed, str(coord), b]
				)


func test_a_lava_sea_forms_below_the_lava_level() -> void:
	# kj.java fills empty cells below Y 32 with lava rather than air.
	#
	# Lava is genuinely sparse: plenty of individual chunks contain none
	# at all, which is why this scans a region rather than a single chunk
	# and uses seed -1, where the oracle fixture shows lava in all eight
	# of its sampled chunks. An earlier version of this test scanned five
	# chunks at seed 12345 and found zero — the generator was right and
	# the expectation was wrong.
	Worldgen.apply_world_seed(-1)
	var lava_total: int = 0
	var above_level: int = 0
	for cx: int in range(-1, 2):
		for cz: int in range(-1, 2):
			var raw: PackedByteArray = WorldgenNether.generate_raw(cx, cz)
			for x: int in range(16):
				for z: int in range(16):
					for y: int in range(128):
						if (
							raw[WorldgenNether.alpha_index(x, y, z)]
							!= (WorldgenNether.ALPHA_LAVA_STILL)
						):
							continue
						lava_total += 1
						if y >= 64:
							above_level += 1
	assert_gt(lava_total, 0, "the lava sea exists across a 3x3 region")
	assert_eq(above_level, 0, "and none of it sits above the surface pivot")


# --- The Alpha -> project remap ---


func test_remap_converts_both_ids_and_layout() -> void:
	var raw := PackedByteArray()
	raw.resize(32768)
	raw[WorldgenNether.alpha_index(1, 2, 3)] = WorldgenNether.ALPHA_NETHERRACK
	raw[WorldgenNether.alpha_index(4, 5, 6)] = WorldgenNether.ALPHA_SOUL_SAND
	raw[WorldgenNether.alpha_index(7, 8, 9)] = WorldgenNether.ALPHA_LAVA_STILL
	raw[WorldgenNether.alpha_index(10, 11, 12)] = WorldgenNether.ALPHA_BEDROCK
	raw[WorldgenNether.alpha_index(13, 14, 15)] = WorldgenNether.ALPHA_GRAVEL
	var chunk := Chunk.new()
	WorldgenNether.remap_to_chunk(raw, chunk)
	assert_eq(chunk.get_block(1, 2, 3), Blocks.NETHERRACK, "netherrack lands at its own cell")
	assert_eq(chunk.get_block(4, 5, 6), Blocks.SOUL_SAND, "soul sand")
	assert_eq(chunk.get_block(7, 8, 9), Blocks.LAVA_STILL, "lava")
	assert_eq(chunk.get_block(10, 11, 12), Blocks.BEDROCK, "bedrock")
	assert_eq(chunk.get_block(13, 14, 15), Blocks.GRAVEL, "gravel")


func test_remap_does_not_transpose_the_chunk() -> void:
	# The failure this guards is subtle: a transposed remap still produces
	# a full chunk of plausible terrain, just mirrored. Asymmetric probes
	# catch it; symmetric ones would not.
	var raw := PackedByteArray()
	raw.resize(32768)
	raw[WorldgenNether.alpha_index(1, 0, 0)] = WorldgenNether.ALPHA_NETHERRACK
	var chunk := Chunk.new()
	WorldgenNether.remap_to_chunk(raw, chunk)
	assert_eq(chunk.get_block(1, 0, 0), Blocks.NETHERRACK, "X stays X")
	assert_eq(chunk.get_block(0, 0, 1), Blocks.AIR, "X did not become Z")
	assert_eq(chunk.get_block(0, 1, 0), Blocks.AIR, "X did not become Y")


func test_remap_sets_max_y_from_the_topmost_solid_cell() -> void:
	var raw := PackedByteArray()
	raw.resize(32768)
	raw[WorldgenNether.alpha_index(5, 90, 5)] = WorldgenNether.ALPHA_NETHERRACK
	var chunk := Chunk.new()
	WorldgenNether.remap_to_chunk(raw, chunk)
	assert_eq(chunk.max_y, 90, "max_y tracks the highest non-air cell")


func test_remap_restores_chunk_bookkeeping_after_bulk_writes() -> void:
	# Nether remapping writes the PackedByteArray directly for speed, so it
	# must explicitly reproduce the derived state that Chunk.set_block would
	# normally maintain. Missing either field caused a shipped failure:
	# generated FIRE stayed hazardous but invisible, and the zero heightmap
	# made border relighting inject sky=15 along every Nether chunk seam.
	var raw := PackedByteArray()
	raw.resize(32768)
	raw[WorldgenNether.alpha_index(4, 63, 4)] = WorldgenNether.ALPHA_NETHERRACK
	raw[WorldgenNether.alpha_index(4, 64, 4)] = WorldgenNether.ALPHA_FIRE
	raw[WorldgenNether.alpha_index(4, 127, 4)] = WorldgenNether.ALPHA_BEDROCK
	var chunk := Chunk.new()
	WorldgenNether.remap_to_chunk(raw, chunk)
	assert_true(chunk.has_non_cube_blocks, "generated FIRE enables the non-cube appendix")
	assert_true(chunk._height_map_dirty, "bulk-written blocks invalidate the empty heightmap")
	assert_false(chunk.is_sky_exposed(4, 64, 4), "the bedrock roof blocks sky queries")
	assert_eq(chunk.height_map[4 * Chunk.SIZE_X + 4], 128, "the rebuilt column reaches the roof")


func test_generated_chunks_carry_only_registered_project_blocks() -> void:
	Worldgen.apply_world_seed(12345)
	var chunk: Chunk = WorldgenNether.generate_chunk(2, -2)
	for i: int in range(chunk.blocks.size()):
		var id: int = chunk.blocks[i]
		assert_true(Blocks.is_registered(id), "generated block id %d is registered" % id)


# --- Provider integration ---


func test_the_nether_provider_serves_the_real_generator() -> void:
	Worldgen.apply_world_seed(12345)
	var provider: WorldProvider = DimensionContext.provider(DimensionContext.NETHER)
	var via_provider: Chunk = provider.generate_chunk(4, 4)
	var direct: Chunk = WorldgenNether.generate_chunk(4, 4)
	assert_eq(via_provider.blocks, direct.blocks, "the provider is not a placeholder any more")
	assert_gt(via_provider.max_y, 0, "and it produced real terrain")


func test_the_overworld_provider_is_untouched() -> void:
	Worldgen.apply_world_seed(12345)
	var overworld: WorldProvider = DimensionContext.provider(DimensionContext.OVERWORLD)
	var via_provider: Chunk = overworld.generate_chunk(0, 0)
	var direct: Chunk = Worldgen.generate_chunk(0, 0)
	assert_eq(via_provider.blocks, direct.blocks, "dimension 0 still routes to Worldgen")


func test_the_two_dimensions_disagree_at_the_same_coordinate() -> void:
	Worldgen.apply_world_seed(12345)
	var nether: Chunk = DimensionContext.provider(DimensionContext.NETHER).generate_chunk(0, 0)
	var overworld: Chunk = DimensionContext.provider(DimensionContext.OVERWORLD).generate_chunk(
		0, 0
	)
	assert_ne(nether.blocks, overworld.blocks, "same coordinate, different worlds")


# --- Worker-thread safety ---


func test_generation_runs_correctly_on_worker_threads() -> void:
	# The plan forbids scene/resource access from generation, and the
	# whole pipeline is dispatched through WorkerThreadPool in production.
	# Generate the same set on the main thread and on workers, then
	# compare — a hidden shared buffer or lazy-init race shows up as a
	# mismatch rather than a crash.
	Worldgen.apply_world_seed(12345)
	var coords: Array[Vector2i] = [
		Vector2i(0, 0),
		Vector2i(1, 0),
		Vector2i(0, 1),
		Vector2i(-1, -1),
		Vector2i(3, 3),
		Vector2i(-4, 2),
		Vector2i(7, -5),
		Vector2i(-8, -8),
	]
	var expected: Array[String] = []
	for c: Vector2i in coords:
		expected.append(_hash(WorldgenNether.generate_raw(c.x, c.y)))

	# Warm the noise generators first: building them is the one lazy
	# step, and production warms it on the main thread in Game._ready for
	# exactly this reason.
	var results: Array[String] = []
	results.resize(coords.size())
	var mutex := Mutex.new()
	var task_ids: Array[int] = []
	for i: int in range(coords.size()):
		var idx: int = i
		var coord: Vector2i = coords[i]
		var job: Callable = func() -> void:
			var h: String = _hash(WorldgenNether.generate_raw(coord.x, coord.y))
			mutex.lock()
			results[idx] = h
			mutex.unlock()
		task_ids.append(WorkerThreadPool.add_task(job))
	for id: int in task_ids:
		WorkerThreadPool.wait_for_task_completion(id)
	for i: int in range(coords.size()):
		assert_eq(
			results[i], expected[i], "worker result for %s matches the main thread" % str(coords[i])
		)
