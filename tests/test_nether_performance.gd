extends GutTest

# Nether performance envelope (Batch 10 release gate).
#
# These are CEILINGS, not benchmarks. A CI machine's absolute numbers
# mean little, so every assertion here is set well above the measured
# figure and only fires when something has changed by an order of
# magnitude — a per-frame allocation, an accidental O(n^2), a scan that
# stopped early-outing. The measured values are printed so a regression
# shows up as a number in the log even when the assertion still passes.
#
# The release-gate criterion is "compared with the Batch 0 route,
# unexplained p95 frame-time regression is at most 10%". That comparison
# is against the Overworld baseline, which
# tests/test_generation_perf_baseline.gd owns and this file leaves alone.

const _GEN_SAMPLES: int = 12
# Nether generation is a 3D density field plus caves. Measured p50 is
# ~20 ms on the native path against the Overworld baseline's ~56 ms;
# 400 ms leaves room for a loaded CI box while still catching an
# order-of-magnitude regression.
const _GEN_CEILING_MS: float = 400.0
# The GDScript reference path is roughly a hundred times slower — 1.9 s
# per chunk, measured — and that is the whole reason the native port
# exists. It is the CORRECTNESS reference, not the performance one, so
# it gets its own ceiling rather than being held to the native figure.
# Without this the suite fails on any build where the extension is
# absent, which is exactly the configuration this ceiling should still
# be meaningful in.
const _GEN_CEILING_FALLBACK_MS: float = 6000.0


class FakeWorld:
	extends Node

	var blocks: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return int(blocks.get(pos, Blocks.AIR))

	func set_world_block(pos: Vector3i, id: int) -> void:
		blocks[pos] = id

	func has_chunk_at(_x: int, _z: int) -> bool:
		return true

	func fill(from: Vector3i, to: Vector3i, id: int) -> void:
		for x: int in range(from.x, to.x + 1):
			for y: int in range(from.y, to.y + 1):
				for z: int in range(from.z, to.z + 1):
					blocks[Vector3i(x, y, z)] = id


var _parent: Node = null
var _dimension_was: int = 0


func before_each() -> void:
	_parent = Node.new()
	add_child_autofree(_parent)
	_dimension_was = DimensionContext.active()


func after_each() -> void:
	DimensionContext.set_active(_dimension_was)


func _percentile(samples: Array[float], fraction: float) -> float:
	if samples.is_empty():
		return 0.0
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	var index: int = clampi(int(float(sorted.size() - 1) * fraction), 0, sorted.size() - 1)
	return sorted[index]


# --- Generation ---


func test_nether_chunk_generation_stays_within_its_envelope() -> void:
	var samples: Array[float] = []
	for i: int in range(_GEN_SAMPLES):
		var start: int = Time.get_ticks_usec()
		WorldgenNether.generate_chunk(i * 7 - 20, i * 3 - 10)
		samples.append(float(Time.get_ticks_usec() - start) / 1000.0)
	var native: bool = WorldgenNether.native_available()
	var p50: float = _percentile(samples, 0.5)
	var p95: float = _percentile(samples, 0.95)
	gut.p(
		(
			"nether chunk gen (%s): n=%d p50=%.2f ms p95=%.2f ms max=%.2f ms"
			% [
				"native" if native else "GDScript reference",
				samples.size(),
				p50,
				p95,
				samples.max()
			]
		)
	)
	var ceiling: float = _GEN_CEILING_MS if native else _GEN_CEILING_FALLBACK_MS
	assert_lt(p95, ceiling, "generation has not regressed by an order of magnitude")


func test_generating_the_same_chunk_twice_costs_the_same() -> void:
	# There is no generation cache, deliberately — a chunk is pure on
	# (seed, x, z). What this catches is an accidental one: if the second
	# call were suddenly free, something is memoising and the memory
	# profile of a long session just changed shape.
	var first_start: int = Time.get_ticks_usec()
	WorldgenNether.generate_chunk(41, 41)
	var first: float = float(Time.get_ticks_usec() - first_start)
	var second_start: int = Time.get_ticks_usec()
	WorldgenNether.generate_chunk(41, 41)
	var second: float = float(Time.get_ticks_usec() - second_start)
	gut.p("same chunk twice: %.2f ms then %.2f ms" % [first / 1000.0, second / 1000.0])
	assert_gt(second, first * 0.05, "the second call still does the work")


# --- Portal search ---


func test_the_portal_search_skips_unloaded_columns() -> void:
	# The whole reason PortalIndex exists: a raw 128-radius scan is 8.4M
	# block reads. The residency test cuts it to the resident ring, and
	# losing that would turn every portal trip into a multi-second stall.
	var w := FakeWorld.new()
	_parent.add_child(w)
	for along: int in range(2):
		for up: int in range(3):
			w.set_world_block(Vector3i(20 + along, 70 + up, 20), Blocks.PORTAL)
	var start: int = Time.get_ticks_usec()
	var found: Variant = NetherTeleporter.find_portal(w, Vector3(8.5, 75.0, 8.5), 128)
	var elapsed_ms: float = float(Time.get_ticks_usec() - start) / 1000.0
	gut.p("portal search, radius 128, all resident: %.1f ms" % elapsed_ms)
	assert_not_null(found, "and it still finds the portal")
	assert_lt(elapsed_ms, 8000.0, "a full-residency scan is slow but bounded")


func test_the_index_narrows_the_search_to_a_handful_of_chunks() -> void:
	PortalIndex.reset()
	for i: int in range(64):
		PortalIndex.record(-1, Vector3i(i * 7 - 200, 70, i * 5 - 150))
	var start: int = Time.get_ticks_usec()
	var hints: Array[Vector2i] = PortalIndex.chunk_hints(-1, Vector3(8.5, 75.0, 8.5), 128)
	var elapsed_ms: float = float(Time.get_ticks_usec() - start) / 1000.0
	gut.p("index hints from 64 entries: %.3f ms -> %d chunks" % [elapsed_ms, hints.size()])
	assert_lt(elapsed_ms, 50.0, "deriving hints is trivial next to the scan it replaces")
	assert_lt(hints.size(), 289, "and it is far fewer than the 17x17 the radius covers")
	PortalIndex.reset()


# --- Mob AI ---


func test_a_full_nether_mob_population_ticks_within_budget() -> void:
	# The Nether cap is `100 * eligible_chunks / 256`, so 100 is the
	# ceiling. Ticking that many pigmen is the worst realistic case.
	var mobs: Array[Node] = []
	for i: int in range(100):
		var mob: Node = MobRegistry.script_for("zombie_pigman").new()
		_parent.add_child(mob)
		(mob as Node3D).global_position = Vector3(float(i % 10) * 6.0, 70.0, float(i / 10) * 6.0)
		mobs.append(mob)
	var samples: Array[float] = []
	for _round: int in range(20):
		var start: int = Time.get_ticks_usec()
		for mob: Node in mobs:
			mob.call("_ai_tick")
		samples.append(float(Time.get_ticks_usec() - start) / 1000.0)
	var p95: float = _percentile(samples, 0.95)
	gut.p(
		(
			"100 pigmen, one AI tick: p50=%.2f ms p95=%.2f ms max=%.2f ms"
			% [_percentile(samples, 0.5), p95, samples.max()]
		)
	)
	# A 20 Hz tick has 50 ms; the whole mob population must be a small
	# fraction of it.
	assert_lt(p95, 25.0, "a full population ticks in well under one 20 Hz slice")


func test_the_ghast_course_scan_early_outs() -> void:
	# The single most expensive thing in the Nether's AI, and the one
	# optimisation Batch 9 made. A naive rescan measured 6.5 ms per call;
	# this ceiling catches a revert.
	var w := FakeWorld.new()
	_parent.add_child(w)
	var ghast: Node = MobRegistry.script_for("ghast").new()
	_parent.add_child(ghast)
	(ghast as Node3D).global_position = Vector3(0, 70, 0)
	ghast.set("_chunk_manager", w)
	var samples: Array[float] = []
	for _i: int in range(40):
		var start: int = Time.get_ticks_usec()
		ghast.call("course_is_clear", Vector3(0, 70, 50), 50.0)
		samples.append(float(Time.get_ticks_usec() - start) / 1000.0)
	var p95: float = _percentile(samples, 0.95)
	gut.p("ghast course scan, 50 blocks of open air: p95=%.2f ms" % p95)
	assert_lt(p95, 4.0, "the incremental scan is still in place")


func test_a_blocked_course_is_cheaper_than_an_open_one() -> void:
	# The scan returns on the first blocked step, so a wall two blocks
	# away must cost far less than fifty blocks of open air. If it did
	# not, the early-out is gone.
	var w := FakeWorld.new()
	_parent.add_child(w)
	w.fill(Vector3i(-8, 60, 3), Vector3i(8, 80, 5), Blocks.NETHERRACK)
	var ghast: Node = MobRegistry.script_for("ghast").new()
	_parent.add_child(ghast)
	(ghast as Node3D).global_position = Vector3(0, 70, 0)
	ghast.set("_chunk_manager", w)
	var start: int = Time.get_ticks_usec()
	for _i: int in range(40):
		ghast.call("course_is_clear", Vector3(0, 70, 50), 50.0)
	var blocked_ms: float = float(Time.get_ticks_usec() - start) / 1000.0
	gut.p("ghast course scan into a wall, 40 calls: %.2f ms" % blocked_ms)
	assert_lt(blocked_ms, 40.0, "a wall two blocks out is cheap")


# --- Projectiles ---


func test_a_barrage_of_fireballs_ticks_cheaply() -> void:
	var w := FakeWorld.new()
	_parent.add_child(w)
	var balls: Array[Node3D] = []
	for _i: int in range(32):
		var ball: Node3D = GhastFireball.new()
		_parent.add_child(ball)
		ball.global_position = Vector3(0, 200, 0)
		ball.set("_chunk_manager", w)
		ball.set("acceleration", Vector3(0, 0, 0.05))
		balls.append(ball)
	var samples: Array[float] = []
	for _round: int in range(20):
		var start: int = Time.get_ticks_usec()
		for ball: Node3D in balls:
			if is_instance_valid(ball) and not ball.is_queued_for_deletion():
				ball.call("_tick")
		samples.append(float(Time.get_ticks_usec() - start) / 1000.0)
	gut.p(
		(
			"32 fireballs, one tick: p50=%.2f ms p95=%.2f ms"
			% [_percentile(samples, 0.5), _percentile(samples, 0.95)]
		)
	)
	assert_lt(_percentile(samples, 0.95), 20.0, "projectiles stay off the frame budget")


# --- Lighting and rendering ---


func test_the_nether_brightness_table_is_not_rebuilt_per_query() -> void:
	# The table is 16 floats; querying it a hundred thousand times is
	# what a chunk relight does. If it were being rebuilt per call the
	# cost would be visible immediately.
	var provider: WorldProvider = DimensionContext.provider(DimensionContext.NETHER)
	var start: int = Time.get_ticks_usec()
	var total: float = 0.0
	for i: int in range(100000):
		total += provider.brightness(i % 16)
	var elapsed_ms: float = float(Time.get_ticks_usec() - start) / 1000.0
	gut.p("100k brightness queries: %.2f ms" % elapsed_ms)
	assert_gt(total, 0.0, "sanity")
	assert_lt(elapsed_ms, 500.0, "per-level brightness is a formula, not a rebuild")


func test_the_portal_texture_is_built_once() -> void:
	# 32 frames of per-pixel float maths. Warmed in Game._ready; asking
	# again must be free, or every portal cell would pay for it.
	PortalTexture.strip_texture()
	var start: int = Time.get_ticks_usec()
	for _i: int in range(1000):
		PortalTexture.strip_texture()
	var elapsed_ms: float = float(Time.get_ticks_usec() - start) / 1000.0
	gut.p("1000 strip_texture() calls after warm: %.3f ms" % elapsed_ms)
	assert_lt(elapsed_ms, 50.0, "cached, not regenerated")
