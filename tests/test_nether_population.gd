# gdlint: disable=max-public-methods
extends GutTest

# Nether decorations: ownership, seams and merge order
# (docs/nether-alpha-1.2.6-implementation-plan.md §6.5, Batch 4).
#
# tests/test_nether_worldgen_oracle.gd already proves the decorators
# themselves are right — its write lists come from running the real kf,
# pm, dt, lp and aj against the same canonical RNG state. What that
# cannot check is the part the plan CANONICALISES rather than copies:
# a source chunk owns its decorations, four sources merge into each
# target in a fixed order, and nothing depends on load order.
#
# Alpha gets all three wrong by construction — it decorates into the live
# world from an unreseeded RNG — so these are properties of this port,
# and the source cannot arbitrate them.

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


func _population_cells(chunk_x: int, chunk_z: int) -> Dictionary:
	# The difference between a decorated chunk and its bare terrain.
	var terrain: PackedByteArray = WorldgenNether.generate_terrain_only(chunk_x, chunk_z)
	var full: PackedByteArray = WorldgenNether.generate_raw(chunk_x, chunk_z)
	var cells: Dictionary = {}
	for i: int in range(terrain.size()):
		if terrain[i] != full[i]:
			cells[i] = full[i]
	return cells


# --- Source ownership ---


func test_a_sources_write_list_depends_only_on_its_own_coordinates() -> void:
	Worldgen.apply_world_seed(12345)
	var first: Array = WorldgenNetherPopulation.write_list(12345, 4, 4)
	# Generate a pile of unrelated chunks in between; in Alpha this would
	# shift the shared RNG and change what chunk (4, 4) decorates.
	for cx: int in range(-3, 4):
		WorldgenNetherPopulation.write_list(12345, cx, 9)
	WorldgenNether.reset()
	var second: Array = WorldgenNetherPopulation.write_list(12345, 4, 4)
	assert_eq(second, first, "the same source decorates identically regardless of history")


func test_write_lists_differ_between_sources_and_seeds() -> void:
	Worldgen.apply_world_seed(12345)
	var a: Array = WorldgenNetherPopulation.write_list(12345, 0, 0)
	var b: Array = WorldgenNetherPopulation.write_list(12345, 1, 0)
	assert_ne(a, b, "neighbouring sources decorate differently")
	Worldgen.apply_world_seed(1)
	WorldgenNether.reset()
	var c: Array = WorldgenNetherPopulation.write_list(1, 0, 0)
	assert_ne(c, a, "a different seed decorates differently")


func test_a_sources_writes_stay_within_its_two_by_two_window() -> void:
	# The window is only correct if every generator really does reach at
	# most 7 blocks from an anchor in [chunk*16+8, chunk*16+23]. If any
	# reached further, writes would be silently clipped and the chunk that
	# should have received them would come up empty.
	Worldgen.apply_world_seed(12345)
	for source: Vector2i in [Vector2i(0, 0), Vector2i(-1, -1), Vector2i(5, -3)]:
		var min_x: int = source.x * 16
		var min_z: int = source.y * 16
		for entry: Variant in WorldgenNetherPopulation.write_list(12345, source.x, source.y):
			var e: Array = entry as Array
			assert_between(
				int(e[0]) - min_x, 0, 31, "source %s write stays in its X window" % str(source)
			)
			assert_between(
				int(e[2]) - min_z, 0, 31, "source %s write stays in its Z window" % str(source)
			)
			assert_between(int(e[1]), 0, 127, "source %s write stays in the column" % str(source))


func test_decorations_actually_reach_across_a_chunk_boundary() -> void:
	# The whole reason four sources merge into each target: anchors start
	# at +8, so a source routinely decorates the chunk to its north-east.
	# If this were zero the merge would be untested dead weight.
	Worldgen.apply_world_seed(-1)
	var crossing: int = 0
	for source: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		for entry: Variant in WorldgenNetherPopulation.write_list(-1, source.x, source.y):
			var e: Array = entry as Array
			if int(e[0]) >= (source.x + 1) * 16 or int(e[2]) >= (source.y + 1) * 16:
				crossing += 1
	assert_gt(crossing, 0, "some decorations land outside their own source chunk")


# --- Merge and target assembly ---


func test_every_decorated_cell_traces_back_to_one_of_the_four_sources() -> void:
	# Decorations are sparse — plenty of individual chunks receive none —
	# so this scans a small region, requires that SOMETHING landed, and
	# then checks every landed cell is claimed by one of that target's
	# four sources. An unclaimed cell would mean the merge is inventing
	# writes or reading the wrong source set.
	Worldgen.apply_world_seed(-1)
	var decorated_targets: int = 0
	for tx: int in range(0, 2):
		for tz: int in range(0, 2):
			var cells: Dictionary = _population_cells(tx, tz)
			if cells.is_empty():
				continue
			decorated_targets += 1
			var claimed: Dictionary = {}
			for source_x: int in [tx - 1, tx]:
				for source_z: int in [tz - 1, tz]:
					for entry: Variant in WorldgenNetherPopulation.write_list(
						-1, source_x, source_z
					):
						var e: Array = entry as Array
						var lx: int = int(e[0]) - tx * 16
						var lz: int = int(e[2]) - tz * 16
						if lx < 0 or lx >= 16 or lz < 0 or lz >= 16:
							continue
						claimed[WorldgenNether.alpha_index(lx, int(e[1]), lz)] = int(e[3])
			for idx: int in cells.keys():
				assert_true(
					claimed.has(idx),
					"chunk (%d, %d): decorated cell %d traces to a source" % [tx, tz, idx]
				)
				if claimed.has(idx):
					assert_eq(
						int(cells[idx]),
						int(claimed[idx]),
						"chunk (%d, %d) cell %d: same block as its source wrote" % [tx, tz, idx]
					)
	assert_gt(decorated_targets, 0, "at least one target in the region was decorated")


func test_the_merge_order_is_fixed_and_reproducible() -> void:
	# Two sources can target the same cell. Whichever the fixed ascending
	# (x, z) walk visits last wins, and it must win every time.
	Worldgen.apply_world_seed(-1)
	var first: PackedByteArray = WorldgenNether.generate_raw(1, 1)
	WorldgenNether.reset()
	var second: PackedByteArray = WorldgenNether.generate_raw(1, 1)
	assert_eq(_hash(first), _hash(second), "the merge resolves identically across runs")


func test_decoration_never_disturbs_the_bedrock_shell() -> void:
	for world_seed: int in [-1, 12345]:
		Worldgen.apply_world_seed(world_seed)
		var raw: PackedByteArray = WorldgenNether.generate_raw(0, 0)
		for x: int in range(16):
			for z: int in range(16):
				assert_eq(
					raw[WorldgenNether.alpha_index(x, 0, z)],
					WorldgenNether.ALPHA_BEDROCK,
					"seed %d: floor intact after decoration" % world_seed
				)
				assert_eq(
					raw[WorldgenNether.alpha_index(x, 127, z)],
					WorldgenNether.ALPHA_BEDROCK,
					"seed %d: roof intact after decoration" % world_seed
				)


# --- Seams and load order ---


func test_a_seam_does_not_change_when_neighbours_generate_later() -> void:
	# Generate a chunk cold, then generate its whole neighbourhood, then
	# generate it again. In Alpha the second result would differ, because
	# the neighbours' decorations would have landed in the live world.
	Worldgen.apply_world_seed(-1)
	WorldgenNether.reset()
	var cold: String = _hash(WorldgenNether.generate_raw(0, 0))
	for cx: int in range(-1, 2):
		for cz: int in range(-1, 2):
			if cx == 0 and cz == 0:
				continue
			WorldgenNether.generate_raw(cx, cz)
	var warm: String = _hash(WorldgenNether.generate_raw(0, 0))
	assert_eq(warm, cold, "the chunk is unchanged by its neighbours arriving")


func test_all_four_seams_agree_from_either_side() -> void:
	# Decorations that cross a boundary have to appear identically whether
	# the target or the source was generated first.
	Worldgen.apply_world_seed(-1)
	var pairs: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)
	]
	var forward: Dictionary = {}
	for c: Vector2i in pairs:
		forward[c] = _hash(WorldgenNether.generate_raw(c.x, c.y))
	WorldgenNether.reset()
	var reversed_pairs: Array[Vector2i] = pairs.duplicate()
	reversed_pairs.reverse()
	for c: Vector2i in reversed_pairs:
		assert_eq(
			_hash(WorldgenNether.generate_raw(c.x, c.y)),
			forward[c],
			"chunk %s is identical generated in the other order" % str(c)
		)


func test_negative_coordinate_sources_decorate_correctly() -> void:
	Worldgen.apply_world_seed(12345)
	var a: Array = WorldgenNetherPopulation.write_list(12345, -1, -1)
	var b: Array = WorldgenNetherPopulation.write_list(12345, 1, 1)
	assert_ne(a, b, "negative and positive sources are distinct")
	for entry: Variant in a:
		var e: Array = entry as Array
		assert_between(int(e[0]), -16, 15, "negative-source X lands in its window")
		assert_between(int(e[2]), -16, 15, "negative-source Z lands in its window")


# --- Cache correctness ---


func test_clearing_the_cache_does_not_change_results() -> void:
	# The caches exist purely so a target does not regenerate its
	# neighbours' terrain nine times over. They must be invisible.
	Worldgen.apply_world_seed(12345)
	var cached: String = _hash(WorldgenNether.generate_raw(2, -2))
	WorldgenNetherPopulation.reset()
	var cold: String = _hash(WorldgenNether.generate_raw(2, -2))
	assert_eq(cold, cached, "a cold cache produces the same chunk")


func test_a_seed_change_invalidates_the_cache() -> void:
	Worldgen.apply_world_seed(12345)
	var at_12345: String = _hash(WorldgenNether.generate_raw(0, 0))
	Worldgen.apply_world_seed(1)
	var at_1: String = _hash(WorldgenNether.generate_raw(0, 0))
	assert_ne(at_1, at_12345, "the new seed is not served stale terrain")
	Worldgen.apply_world_seed(12345)
	assert_eq(
		_hash(WorldgenNether.generate_raw(0, 0)),
		at_12345,
		"and switching back restores the original"
	)


# --- Feature presence ---


func test_every_decoration_type_appears_somewhere() -> void:
	# A port that silently dropped one generator would still pass the
	# order and seam tests. This is the coverage check.
	var found: Dictionary = {}
	for world_seed: int in _SEEDS:
		Worldgen.apply_world_seed(world_seed)
		for source: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, -1)]:
			for entry: Variant in WorldgenNetherPopulation.write_list(
				world_seed, source.x, source.y
			):
				found[int((entry as Array)[3])] = true
	for id: int in [
		WorldgenNether.ALPHA_GLOWSTONE,
		WorldgenNether.ALPHA_FIRE,
		WorldgenNether.ALPHA_MUSHROOM_BROWN,
		WorldgenNether.ALPHA_MUSHROOM_RED,
		WorldgenNether.ALPHA_LAVA_FLOWING,
	]:
		assert_true(found.has(id), "decoration id %d is produced somewhere" % id)


func test_decorated_chunks_remap_to_registered_project_blocks() -> void:
	Worldgen.apply_world_seed(-1)
	var chunk: Chunk = WorldgenNether.generate_chunk(1, 1)
	var seen: Dictionary = {}
	for i: int in range(chunk.blocks.size()):
		seen[chunk.blocks[i]] = true
	for id: int in seen.keys():
		assert_true(Blocks.is_registered(id), "remapped block id %d is registered" % id)
