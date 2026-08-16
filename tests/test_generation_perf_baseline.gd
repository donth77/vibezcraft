extends GutTest

# Batch 0 generation performance baseline
# (docs/nether-alpha-1.2.6-implementation-plan.md §13).
#
# Batch 5 gates native Nether generation against the native Overworld
# worker-generation p95 measured "for the same sampled chunk count", and
# Batch 10 compares steady-state timings against a Batch 0 route. This
# file records the Overworld half of that comparison from the existing
# PerfProbe instrumentation.
#
# It deliberately asserts almost nothing about the numbers themselves —
# developer and CI hardware differ by more than any threshold worth
# writing, and the plan says absolute numbers are diagnostic. What it
# does assert is that the probes fire, so a later batch cannot quietly
# lose its instrumentation and report an empty baseline as a pass.
#
# The recorded report lands in user:// rather than tests/fixtures/,
# because it is a machine measurement rather than a portable fact.

const _CHUNK_SPAN: int = 7  # 7x7 = 49 chunks, the doc's reference load
const _REPORT_PATH := "user://perf_baseline_batch0.json"

# Probes worth carrying forward. Others still get recorded; these are the
# ones the plan's gates name.
# Meshing is deliberately absent: it needs a ChunkNode and the main-thread
# upload path, so it belongs to an in-game capture rather than this
# generation-only harness.
const _HEADLINE_PROBES: Array[String] = [
	"worldgen.generate_chunk",
	"worldgen.caves",
]

var _seed_was: int
var _terrain_3d_was: bool


func before_all() -> void:
	_seed_was = Worldgen.WORLD_SEED
	_terrain_3d_was = Worldgen.terrain_3d_enabled
	Worldgen.terrain_3d_enabled = true
	PerfProbe.enabled = true


func after_all() -> void:
	Worldgen.terrain_3d_enabled = _terrain_3d_was
	Worldgen.apply_world_seed(_seed_was)


func _fmt_us(us: int) -> String:
	return "%.2f ms" % (float(us) / 1000.0)


func test_records_the_overworld_generation_baseline() -> void:
	PerfProbe.reset()
	Worldgen.apply_world_seed(12345)
	# One warm-up chunk so noise/LUT lazy-init does not land in the
	# sample set; the plan asks for warm numbers.
	Worldgen.generate_chunk(1000, 1000)
	PerfProbe.reset()

	var half: int = _CHUNK_SPAN / 2
	var generated: int = 0
	for cx: int in range(-half, half + 1):
		for cz: int in range(-half, half + 1):
			var chunk: Chunk = Worldgen.generate_chunk(cx, cz)
			assert_not_null(chunk, "chunk (%d, %d) generated" % [cx, cz])
			generated += 1
	assert_eq(generated, _CHUNK_SPAN * _CHUNK_SPAN, "the whole reference load ran")

	var snap: Dictionary = PerfProbe.snapshot()
	assert_true(
		snap.has("worldgen.generate_chunk"),
		"the generation probe fired — instrumentation is still wired"
	)
	var gen: Dictionary = snap.get("worldgen.generate_chunk", {}) as Dictionary
	assert_eq(int(gen.get("count", 0)), generated, "one generation sample per chunk")

	var native_active: bool = Worldgen._native_worldgen != null
	var report: Dictionary = {
		"batch": 0,
		"purpose": "Overworld generation baseline for the Batch 5 and Batch 10 gates.",
		"chunk_count": generated,
		"seed": 12345,
		"terrain_3d_enabled": Worldgen.terrain_3d_enabled,
		"native_worldgen": native_active,
		"native_mesher": ClassDB.class_exists("MesherNative"),
		"godot_version": Engine.get_version_info().get("string", ""),
		"os": OS.get_name(),
		"cpu": OS.get_processor_name(),
		"cpu_count": OS.get_processor_count(),
		"static_memory_bytes": OS.get_static_memory_usage(),
		"probes_us": snap,
	}
	var f := FileAccess.open(_REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  ", true))
		f.close()

	# Printed so the batch handoff can quote real numbers rather than
	# "it ran fine".
	gut.p("--- Batch 0 Overworld generation baseline ---")
	gut.p(
		(
			"%d chunks, seed 12345, terrain_3d=%s, native_worldgen=%s"
			% [generated, str(Worldgen.terrain_3d_enabled), str(native_active)]
		)
	)
	for label: String in _HEADLINE_PROBES:
		if not snap.has(label):
			gut.p("  %-28s (no samples)" % label)
			continue
		var e: Dictionary = snap[label] as Dictionary
		(
			gut
			. p(
				(
					"  %-28s n=%-5d p50=%-10s p95=%-10s max=%s"
					% [
						label,
						int(e["count"]),
						_fmt_us(int(e["p50"])),
						_fmt_us(int(e["p95"])),
						_fmt_us(int(e["max"])),
					]
				)
			)
		)
	for label: String in snap.keys():
		if _HEADLINE_PROBES.has(label):
			continue
		var e: Dictionary = snap[label] as Dictionary
		(
			gut
			. p(
				(
					"  %-28s n=%-5d p50=%-10s p95=%-10s max=%s"
					% [
						label,
						int(e["count"]),
						_fmt_us(int(e["p50"])),
						_fmt_us(int(e["p95"])),
						_fmt_us(int(e["max"])),
					]
				)
			)
		)
	gut.p("report written to %s" % _REPORT_PATH)
