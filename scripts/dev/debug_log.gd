class_name DebugLog
extends RefCounted

# Rolling in-memory event log for post-hoc bug investigation. The
# fall-through / missing-chunk / stuck failures from issue #5 are
# intermittent and near-impossible to reproduce on demand, so instead of
# a bare state snapshot we record the events AS THEY HAPPEN and surface
# the tail in Pause -> Options -> Unstuck / Debug (+ mirror to stdout).
#
# Ring-capped so a long session can't grow memory unbounded; reset once
# per world load (ChunkManager._ready) so the log scopes to the session
# the player is actually in when they hit a problem.
#
# Thread-safe: corrupt-chunk decode logs from a WorkerThreadPool task, so
# every mutation takes the mutex (matches PerfProbe's threading contract).

const _MAX_ENTRIES: int = 200

# Categories — keep the log skimmable and greppable.
const SPAWN: String = "SPAWN"  # world entry / respawn position
const FALL: String = "FALL"  # left solid ground descending — clip-through ONSET
const VOID: String = "VOID"  # fell past the world floor -> recovered
const STUCK: String = "STUCK"  # embedded in solid -> unstuck
const CHUNK: String = "CHUNK"  # missing / corrupt / regenerated chunk
const GROUND: String = "GROUND"  # no live collision under player (fall-through precursor)
const TP: String = "TP"  # manual Teleport to Spawn

static var _entries: Array[String] = []
static var _start_ticks_msec: int = 0
static var _start_wall: String = ""
static var _mutex := Mutex.new()


# Call once per world load so the log scopes to the current session.
static func reset() -> void:
	_mutex.lock()
	_entries.clear()
	_start_ticks_msec = Time.get_ticks_msec()
	_start_wall = Time.get_time_string_from_system()
	_mutex.unlock()


static func add(category: String, message: String) -> void:
	var line: String = ""
	_mutex.lock()
	if _start_ticks_msec == 0:
		_start_ticks_msec = Time.get_ticks_msec()
		_start_wall = Time.get_time_string_from_system()
	line = "[%s] [%s] %s" % [_elapsed_stamp(), category, message]
	_entries.append(line)
	if _entries.size() > _MAX_ENTRIES:
		_entries.remove_at(0)
	_mutex.unlock()
	# Mirror to the console so a desktop tester watching stdout gets the
	# same trail. Low volume — these are state-change events, never
	# per-frame — so the print cost is negligible.
	print("[DebugLog] ", line)


# Monotonic elapsed-since-reset stamp, "+MM:SS.mmm" — sequences events
# and shows the gaps between them without depending on wall-clock math.
static func _elapsed_stamp() -> String:
	var total: int = maxi(0, Time.get_ticks_msec() - _start_ticks_msec)
	var mm: int = total / 60000
	var ss: int = (total / 1000) % 60
	var mmm: int = total % 1000
	return "+%02d:%02d.%03d" % [mm, ss, mmm]


static func dump() -> String:
	_mutex.lock()
	var header: String = "session started %s | %d event(s)" % [_start_wall, _entries.size()]
	var body: String = (
		"\n".join(_entries) if not _entries.is_empty() else "(no events logged yet this session)"
	)
	_mutex.unlock()
	return header + "\n" + body
