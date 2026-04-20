class_name PerfProbe
extends RefCounted

# Lightweight always-on timing probe. Callers pair `begin(label)` with
# `end(label, token)`. Samples go into a per-label ring buffer (last N=512
# deltas in µs). `snapshot()` computes p50/p95/mean for the debug overlay
# and CI harness.
#
# Thread-safe: mesher and worldgen run on WorkerThreadPool, so `end()`
# acquires a mutex before touching the samples dict. `begin()` is lock-free
# (just returns ticks).
#
# Zero-overhead when disabled: `enabled = false` short-circuits both calls
# before any allocation. Set it from game.gd at boot (or via a debug key).

const RING_SIZE: int = 512

static var enabled: bool = true
static var _samples: Dictionary = {}  # label → {buf: PackedInt64Array, idx: int, count: int}
static var _mutex := Mutex.new()


# Returns a token to pass to `end()`. Call sites pattern:
#   var t := PerfProbe.begin("worldgen.generate_chunk")
#   ... work ...
#   PerfProbe.end("worldgen.generate_chunk", t)
static func begin(_label: String) -> int:
	if not enabled:
		return 0
	return Time.get_ticks_usec()


static func end(label: String, token: int) -> void:
	if not enabled or token == 0:
		return
	var delta: int = Time.get_ticks_usec() - token
	_mutex.lock()
	var entry: Dictionary = _samples.get(label, {})
	if entry.is_empty():
		var buf := PackedInt64Array()
		buf.resize(RING_SIZE)
		entry = {"buf": buf, "idx": 0, "count": 0}
		_samples[label] = entry
	var buf: PackedInt64Array = entry["buf"]
	var idx: int = entry["idx"]
	buf[idx] = delta
	entry["idx"] = (idx + 1) % RING_SIZE
	entry["count"] = min(entry["count"] + 1, RING_SIZE)
	_mutex.unlock()


# Returns { label → {count, p50, p95, mean, max} } with times in µs. Copies
# + sorts each ring under the mutex so callers can iterate lock-free.
static func snapshot() -> Dictionary:
	var out: Dictionary = {}
	_mutex.lock()
	for label: String in _samples:
		var entry: Dictionary = _samples[label]
		var count: int = entry["count"]
		if count == 0:
			continue
		var buf: PackedInt64Array = entry["buf"]
		var sorted: Array[int] = []
		sorted.resize(count)
		for i in range(count):
			sorted[i] = buf[i]
		sorted.sort()
		var sum: int = 0
		for v in sorted:
			sum += v
		out[label] = {
			"count": count,
			"p50": sorted[count / 2],
			"p95": sorted[mini(count - 1, (count * 95) / 100)],
			"mean": sum / count,
			"max": sorted[count - 1],
		}
	_mutex.unlock()
	return out


static func reset() -> void:
	_mutex.lock()
	_samples = {}
	_mutex.unlock()
