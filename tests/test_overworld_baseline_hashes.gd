# gdlint: disable=max-public-methods
extends GutTest

# Overworld generation baseline (docs/nether-alpha-1.2.6-implementation-plan.md
# Batch 0).
#
# The Nether work adds a second dimension, a provider abstraction, a
# dimension-aware ChunkManager and eventually a second native generator.
# Every one of those touches code the Overworld runs through. The plan
# gates each batch on "Overworld generation remains byte-identical", so
# this file freezes what the Overworld produces today and re-checks it on
# every run.
#
# The canonical hashes are captured from the GDScript reference path with
# the native extension disabled, matching the project's rule that
# GDScript is the correctness reference and native must match it. A
# second test asserts the native path agrees, so the fixture doubles as a
# cross-path parity guard that works whether or not the extension built.
#
# Regenerate deliberately (only when an Overworld change is intended):
#   MC_CLONE_WRITE_FIXTURES=1 godot --headless --path . \
#     -s addons/gut/gut_cmdln.gd \
#     -gtest=res://tests/test_overworld_baseline_hashes.gd -gexit

const _FIXTURE_PATH := "res://tests/fixtures/overworld_baseline_hashes.json"

# Plan §12.2 seed matrix.
const _SEEDS: Array[int] = [0, 1, -1, 12345, 987654321]

# Plan §12.2 coordinate matrix: origin, the four axis neighbours, the
# negative diagonal, and one distant coordinate in each sign direction.
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
var _terrain_3d_was: bool
var _native_was: RefCounted


func before_all() -> void:
	_seed_was = Worldgen.WORLD_SEED
	_terrain_3d_was = Worldgen.terrain_3d_enabled
	_native_was = Worldgen._native_worldgen
	# Pin the production default explicitly rather than inheriting
	# whatever MC_CLONE_TERRAIN_3D happens to be in this shell.
	Worldgen.terrain_3d_enabled = true


func after_all() -> void:
	Worldgen._native_worldgen = _native_was
	Worldgen.terrain_3d_enabled = _terrain_3d_was
	Worldgen.apply_world_seed(_seed_was)


func _hash_bytes(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func _key(world_seed: int, coord: Vector2i) -> String:
	return "%d/%d,%d" % [world_seed, coord.x, coord.y]


# Generates the whole matrix and returns {key: "sha256:max_y"}.
func _capture(use_native: bool) -> Dictionary:
	var out: Dictionary = {}
	for world_seed: int in _SEEDS:
		for coord: Vector2i in _COORDS:
			Worldgen._native_worldgen = _native_was if use_native else null
			Worldgen.apply_world_seed(world_seed)
			var chunk: Chunk = Worldgen.generate_chunk(coord.x, coord.y)
			out[_key(world_seed, coord)] = ("%s:%d" % [_hash_bytes(chunk.blocks), chunk.max_y])
	return out


func _write_fixture(rows: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/fixtures"))
	var payload: Dictionary = {
		"_provenance":
		{
			"purpose":
			"Batch 0 Overworld generation baseline; later batches must not change these.",
			"generator": "scripts/world/worldgen.gd (GDScript reference path, native disabled)",
			"terrain_3d_enabled": true,
			"chunk_layout": "y * 256 + z * 16 + x, PackedByteArray of 16x128x16",
			"value_format": "sha256(chunk.blocks) + ':' + max_y",
			"seeds": _SEEDS,
			"godot_version": Engine.get_version_info().get("string", ""),
		},
		"hashes": rows,
	}
	var f := FileAccess.open(_FIXTURE_PATH, FileAccess.WRITE)
	assert_not_null(f, "fixture file opens for writing")
	if f != null:
		f.store_string(JSON.stringify(payload, "  ", true))
		f.close()


func _load_fixture() -> Dictionary:
	if not FileAccess.file_exists(_FIXTURE_PATH):
		return {}
	var f := FileAccess.open(_FIXTURE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return (parsed as Dictionary).get("hashes", {}) as Dictionary


func test_overworld_matrix_matches_the_recorded_baseline() -> void:
	var rows: Dictionary = _capture(false)
	assert_eq(rows.size(), _SEEDS.size() * _COORDS.size(), "the full seed/coordinate matrix ran")
	var expected: Dictionary = _load_fixture()
	var writing: bool = OS.get_environment("MC_CLONE_WRITE_FIXTURES") == "1"
	if expected.is_empty() or writing:
		_write_fixture(rows)
		assert_true(
			expected.is_empty() or writing,
			"baseline written to %s — re-run to compare against it" % _FIXTURE_PATH
		)
		return
	for key: String in rows.keys():
		assert_true(expected.has(key), "baseline covers %s" % key)
		if expected.has(key):
			assert_eq(rows[key], expected[key], "Overworld chunk %s is unchanged" % key)
	for key: String in expected.keys():
		assert_true(rows.has(key), "baseline entry %s is still generated" % key)


func test_native_worldgen_matches_the_gdscript_baseline() -> void:
	if not ClassDB.class_exists("WorldgenNative"):
		# Fallback platforms legitimately have no extension; the GDScript
		# baseline above is the one that must hold there.
		pass_test("WorldgenNative not registered — GDScript-only run")
		return
	if _native_was == null:
		pass_test("native worldgen not enabled in this session")
		return
	var expected: Dictionary = _load_fixture()
	if expected.is_empty():
		pass_test("baseline not recorded yet — first run writes it")
		return
	var rows: Dictionary = _capture(true)
	for key: String in rows.keys():
		if expected.has(key):
			assert_eq(rows[key], expected[key], "native Overworld chunk %s matches" % key)


func test_generation_is_stable_across_repeated_runs() -> void:
	# Cheap determinism guard: the same coordinate generated twice in one
	# process must be byte-identical. Catches accidental time/RNG state
	# leaking into the pipeline.
	Worldgen._native_worldgen = _native_was
	Worldgen.apply_world_seed(12345)
	var a: Chunk = Worldgen.generate_chunk(3, -7)
	var b: Chunk = Worldgen.generate_chunk(3, -7)
	assert_eq(a.blocks, b.blocks, "repeat generation is byte-identical")
	assert_eq(a.max_y, b.max_y, "repeat generation agrees on max_y")


func test_generation_is_independent_of_request_order() -> void:
	# The plan requires order-independent generation for the Nether; the
	# Overworld already guarantees it and must keep doing so.
	Worldgen._native_worldgen = _native_was
	Worldgen.apply_world_seed(987654321)
	var forward: Dictionary = {}
	for coord: Vector2i in _COORDS:
		forward[_key(987654321, coord)] = _hash_bytes(
			Worldgen.generate_chunk(coord.x, coord.y).blocks
		)
	var reversed_coords: Array[Vector2i] = _COORDS.duplicate()
	reversed_coords.reverse()
	for coord: Vector2i in reversed_coords:
		var key: String = _key(987654321, coord)
		assert_eq(
			_hash_bytes(Worldgen.generate_chunk(coord.x, coord.y).blocks),
			forward[key],
			"chunk %s is identical in reverse request order" % key
		)
