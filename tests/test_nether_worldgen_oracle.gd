# gdlint: disable=max-public-methods
extends GutTest

# Nether terrain against the Alpha source oracle
# (docs/nether-alpha-1.2.6-implementation-plan.md §6, Batch 3).
#
# tests/fixtures/alpha_nether_terrain.json is produced by COMPILING AND
# RUNNING the real decompiled `kj.java` (ChunkProviderHell), `ju.java`
# (Nether caves), `dl.java`, the real noise stack and Alpha's own
# MathHelper sine table under a JDK. See
# scripts/dev/internal/alpha_oracle/. Nothing about the terrain algorithm
# is re-implemented on that side, so this is a genuine independent oracle
# rather than a second translation of our own port.
#
# The fixture records each stage separately — after density, after
# surface, after caves — so a mismatch says WHICH stage broke instead of
# only that the chunk differs. It also carries a block-id histogram and
# two full vertical columns, which turn "the hash differs" into "you put
# netherrack where lava belongs".
#
# Regenerate (needs the gitignored vendor tree + a JDK):
#   python3 scripts/dev/internal/alpha_oracle/emit_fixtures.py
#   python3 scripts/dev/internal/alpha_oracle/emit_fixtures.py --check

const _FIXTURE_PATH := "res://tests/fixtures/alpha_nether_terrain.json"

var _terrain: Dictionary = {}
var _seed_was: int


func before_all() -> void:
	_seed_was = Worldgen.WORLD_SEED
	var f := FileAccess.open(_FIXTURE_PATH, FileAccess.READ)
	assert_not_null(f, "the Nether terrain fixture is checked in")
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) == TYPE_DICTIONARY:
		_terrain = ((parsed as Dictionary).get("terrain", {}) as Dictionary)


func after_all() -> void:
	Worldgen.apply_world_seed(_seed_was)
	WorldgenNether.reset()


func _chunks_for(seed_key: String) -> Dictionary:
	var all: Dictionary = _terrain.get("chunks", {}) as Dictionary
	return all.get(seed_key, {}) as Dictionary


func _seed_keys() -> Array:
	var all: Dictionary = _terrain.get("chunks", {}) as Dictionary
	var keys: Array = all.keys()
	keys.sort()
	return keys


func _sha256(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func _use_seed(seed_key: String) -> void:
	WorldgenNether.reset()
	Worldgen.apply_world_seed(int(seed_key))


func _coords(key: String) -> Vector2i:
	var parts: PackedStringArray = key.split(",")
	return Vector2i(int(parts[0]), int(parts[1]))


# --- Fixture sanity ---


func test_the_fixture_covers_the_planned_matrix() -> void:
	assert_eq(_seed_keys().size(), 5, "five seeds")
	for seed_key: String in _seed_keys():
		assert_eq(_chunks_for(seed_key).size(), 8, "eight chunks for seed %s" % seed_key)
	assert_eq(
		_terrain.get("layout", ""),
		"(x * 16 + z) * 128 + y, raw Alpha block ids",
		"the fixture is in the source's own layout, before any remap"
	)


func test_the_oracles_staged_and_whole_runs_agree() -> void:
	# The driver decomposes kj into stages AND runs kj's own entry point,
	# then compares. If those ever disagree the fixture is measuring the
	# driver rather than the provider.
	for seed_key: String in _seed_keys():
		for chunk_key: String in _chunks_for(seed_key).keys():
			var facts: Dictionary = _chunks_for(seed_key)[chunk_key]
			assert_true(
				bool(facts.get("staged_matches_provider", false)),
				"seed %s chunk %s: oracle stages match kj.b()" % [seed_key, chunk_key]
			)


# --- Index helpers ---


func test_the_two_chunk_layouts_are_distinct_and_correct() -> void:
	# Confusing these silently transposes the world, which is why they are
	# named functions rather than inline arithmetic.
	assert_eq(WorldgenNether.alpha_index(0, 0, 0), 0)
	assert_eq(WorldgenNether.alpha_index(1, 0, 0), 2048, "Alpha X stride is 16 * 128")
	assert_eq(WorldgenNether.alpha_index(0, 0, 1), 128, "Alpha Z stride is 128")
	assert_eq(WorldgenNether.alpha_index(0, 1, 0), 1, "Alpha Y stride is 1")
	assert_eq(WorldgenNether.project_index(0, 0, 0), 0)
	assert_eq(WorldgenNether.project_index(1, 0, 0), 1, "project X stride is 1")
	assert_eq(WorldgenNether.project_index(0, 0, 1), 16, "project Z stride is 16")
	assert_eq(WorldgenNether.project_index(0, 1, 0), 256, "project Y stride is 256")


func test_every_alpha_cell_maps_to_exactly_one_project_cell() -> void:
	var seen: Dictionary = {}
	for y: int in range(Chunk.SIZE_Y):
		for z: int in range(Chunk.SIZE_Z):
			for x: int in range(Chunk.SIZE_X):
				var a: int = WorldgenNether.alpha_index(x, y, z)
				var p: int = WorldgenNether.project_index(x, y, z)
				assert_between(a, 0, 32767, "alpha index in range")
				assert_between(p, 0, 32767, "project index in range")
				assert_false(seen.has(a), "alpha index %d is unique" % a)
				seen[a] = p
	assert_eq(seen.size(), 32768, "the remap is a bijection over the whole chunk")


# --- Stage 1: density + base fill ---


func test_base_fill_matches_the_oracle() -> void:
	for seed_key: String in _seed_keys():
		_use_seed(seed_key)
		for chunk_key: String in _chunks_for(seed_key).keys():
			var facts: Dictionary = _chunks_for(seed_key)[chunk_key]
			var coord: Vector2i = _coords(chunk_key)
			var blocks: PackedByteArray = WorldgenNether.new_chunk_buffer()
			WorldgenNether.fill_base(blocks, coord.x, coord.y)
			assert_eq(
				_sha256(blocks),
				str(facts.get("after_density", "")),
				"seed %s chunk %s: density + base fill" % [seed_key, chunk_key]
			)


# --- Stage 2: surface replacement + bedrock ---


func test_surface_pass_matches_the_oracle() -> void:
	for seed_key: String in _seed_keys():
		_use_seed(seed_key)
		for chunk_key: String in _chunks_for(seed_key).keys():
			var facts: Dictionary = _chunks_for(seed_key)[chunk_key]
			var coord: Vector2i = _coords(chunk_key)
			var blocks: PackedByteArray = WorldgenNether.new_chunk_buffer()
			var rng: JavaRandom = WorldgenNether.chunk_rng(coord.x, coord.y)
			WorldgenNether.fill_base(blocks, coord.x, coord.y)
			WorldgenNether.apply_surface(blocks, coord.x, coord.y, rng)
			assert_eq(
				_sha256(blocks),
				str(facts.get("after_surface", "")),
				"seed %s chunk %s: surface + bedrock" % [seed_key, chunk_key]
			)


# --- Stage 3: caves, and the whole pipeline ---


func test_full_terrain_matches_the_oracle() -> void:
	for seed_key: String in _seed_keys():
		_use_seed(seed_key)
		for chunk_key: String in _chunks_for(seed_key).keys():
			var facts: Dictionary = _chunks_for(seed_key)[chunk_key]
			var coord: Vector2i = _coords(chunk_key)
			var raw: PackedByteArray = WorldgenNether.generate_terrain_only(coord.x, coord.y)
			assert_eq(
				_sha256(raw),
				str(facts.get("full", "")),
				"seed %s chunk %s: full terrain including caves" % [seed_key, chunk_key]
			)


func test_block_histograms_match_the_oracle() -> void:
	# Diagnostic depth: a hash mismatch says "different", a histogram
	# mismatch says "you emitted 1500 netherrack where lava belongs".
	for seed_key: String in _seed_keys():
		_use_seed(seed_key)
		for chunk_key: String in _chunks_for(seed_key).keys():
			var facts: Dictionary = _chunks_for(seed_key)[chunk_key]
			var expected: Dictionary = facts.get("histogram", {}) as Dictionary
			var coord: Vector2i = _coords(chunk_key)
			var raw: PackedByteArray = WorldgenNether.generate_terrain_only(coord.x, coord.y)
			var counts: Dictionary = {}
			for b: int in raw:
				counts[b] = int(counts.get(b, 0)) + 1
			for id_key: String in expected.keys():
				assert_eq(
					int(counts.get(int(id_key), 0)),
					int(expected[id_key]),
					"seed %s chunk %s: count of Alpha block %s" % [seed_key, chunk_key, id_key]
				)
			assert_eq(
				counts.size(),
				expected.size(),
				"seed %s chunk %s: no extra block ids" % [seed_key, chunk_key]
			)


func test_probe_columns_match_the_oracle() -> void:
	for seed_key: String in _seed_keys():
		_use_seed(seed_key)
		for chunk_key: String in _chunks_for(seed_key).keys():
			var facts: Dictionary = _chunks_for(seed_key)[chunk_key]
			var expected: Dictionary = facts.get("columns", {}) as Dictionary
			var coord: Vector2i = _coords(chunk_key)
			var raw: PackedByteArray = WorldgenNether.generate_terrain_only(coord.x, coord.y)
			for col_key: String in expected.keys():
				var xz: Vector2i = _coords(col_key)
				var got: String = ""
				for y: int in range(128):
					got += "%02x" % raw[WorldgenNether.alpha_index(xz.x, y, xz.y)]
				assert_eq(
					got,
					str(expected[col_key]),
					"seed %s chunk %s column %s" % [seed_key, chunk_key, col_key]
				)


func test_probe_cells_match_the_oracle() -> void:
	for seed_key: String in _seed_keys():
		_use_seed(seed_key)
		for chunk_key: String in _chunks_for(seed_key).keys():
			var facts: Dictionary = _chunks_for(seed_key)[chunk_key]
			var expected: Dictionary = facts.get("cells", {}) as Dictionary
			var coord: Vector2i = _coords(chunk_key)
			var raw: PackedByteArray = WorldgenNether.generate_terrain_only(coord.x, coord.y)
			for cell_key: String in expected.keys():
				var parts: PackedStringArray = cell_key.split(",")
				var idx: int = WorldgenNether.alpha_index(
					int(parts[0]), int(parts[1]), int(parts[2])
				)
				assert_eq(
					raw[idx],
					int(expected[cell_key]),
					"seed %s chunk %s cell %s" % [seed_key, chunk_key, cell_key]
				)


# --- Population (plan §6.5) ---


func test_population_write_lists_match_the_oracle() -> void:
	# The oracle runs the REAL decorators — kf, pm, dt, lp and aj — over a
	# 2x2 window of finished terrain, from the same canonical RNG state
	# this port reconstructs, and records every cell they changed. This is
	# the strongest available check on the decorators: anchors, attempt
	# counts, draw order and placement predicates all have to line up or
	# the cell lists diverge.
	for seed_key: String in _seed_keys():
		_use_seed(seed_key)
		for chunk_key: String in _chunks_for(seed_key).keys():
			var facts: Dictionary = _chunks_for(seed_key)[chunk_key]
			var pop: Dictionary = facts.get("population", {}) as Dictionary
			var coord: Vector2i = _coords(chunk_key)
			var expected: Array = pop.get("changes", []) as Array
			var got: Array = WorldgenNetherPopulation.write_list(int(seed_key), coord.x, coord.y)
			assert_eq(
				got.size(),
				int(pop.get("changed_count", -1)),
				"seed %s source %s: number of cells population writes" % [seed_key, chunk_key]
			)
			var expected_set: Dictionary = {}
			for e: Variant in expected:
				var a: Array = e as Array
				expected_set["%d,%d,%d" % [int(a[0]), int(a[1]), int(a[2])]] = int(a[3])
			for e: Variant in got:
				var a: Array = e as Array
				var key: String = "%d,%d,%d" % [int(a[0]), int(a[1]), int(a[2])]
				assert_true(
					expected_set.has(key),
					"seed %s source %s: oracle also writes %s" % [seed_key, chunk_key, key]
				)
				if expected_set.has(key):
					assert_eq(
						int(a[3]),
						int(expected_set[key]),
						"seed %s source %s cell %s: same block" % [seed_key, chunk_key, key]
					)
