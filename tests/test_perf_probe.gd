extends GutTest


func before_each() -> void:
	PerfProbe.reset()
	PerfProbe.enabled = true


func after_each() -> void:
	PerfProbe.enabled = true
	PerfProbe.reset()


func test_begin_end_records_sample() -> void:
	var t := PerfProbe.begin("test.one")
	PerfProbe.end("test.one", t)
	var snap := PerfProbe.snapshot()
	assert_true(snap.has("test.one"), "label recorded")
	assert_eq(snap["test.one"]["count"], 1, "one sample")


func test_multiple_samples_compute_percentiles() -> void:
	# Inject a known distribution by calling begin/end rapidly; exact numbers
	# depend on ticks, so we only assert the snapshot schema is sane.
	for i in range(50):
		var t := PerfProbe.begin("test.many")
		PerfProbe.end("test.many", t)
	var snap := PerfProbe.snapshot()
	var entry: Dictionary = snap["test.many"]
	assert_eq(entry["count"], 50)
	assert_true(entry.has("p50"))
	assert_true(entry.has("p95"))
	assert_true(entry.has("mean"))
	assert_true(entry.has("max"))
	assert_gte(entry["max"], entry["p95"])
	assert_gte(entry["p95"], entry["p50"])


func test_disabled_records_nothing() -> void:
	PerfProbe.enabled = false
	var t := PerfProbe.begin("test.off")
	PerfProbe.end("test.off", t)
	var snap := PerfProbe.snapshot()
	assert_false(snap.has("test.off"), "no sample when disabled")


func test_reset_clears_samples() -> void:
	var t := PerfProbe.begin("test.clear")
	PerfProbe.end("test.clear", t)
	PerfProbe.reset()
	var snap := PerfProbe.snapshot()
	assert_eq(snap.size(), 0, "snapshot empty after reset")


func test_ring_buffer_caps_at_ring_size() -> void:
	# Push > RING_SIZE samples; count should cap.
	var n: int = PerfProbe.RING_SIZE + 10
	for i in range(n):
		var t := PerfProbe.begin("test.ring")
		PerfProbe.end("test.ring", t)
	var snap := PerfProbe.snapshot()
	assert_eq(snap["test.ring"]["count"], PerfProbe.RING_SIZE, "ring buffer caps at RING_SIZE")


func test_isolated_labels_do_not_mix() -> void:
	var ta := PerfProbe.begin("test.a")
	PerfProbe.end("test.a", ta)
	var tb := PerfProbe.begin("test.b")
	PerfProbe.end("test.b", tb)
	PerfProbe.end("test.b", PerfProbe.begin("test.b"))
	var snap := PerfProbe.snapshot()
	assert_eq(snap["test.a"]["count"], 1)
	assert_eq(snap["test.b"]["count"], 2)
