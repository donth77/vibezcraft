extends GutTest

# Phase 8 — wire propagation convergence and cost under adversarial load
# (.claude/redstone-plan.md §7.7).
#
# The fixture is a 32 × 32 CONNECTED wire field — 1,024 cells, every one
# of them initially held at 15 by its own torch under its own support
# block. Nothing in Alpha builds this (a single source only reaches 15
# cells), which is the point: it is the worst case the plan's eventual-
# convergence and stale-load reconciliation contract has to survive.
#
# It exists because the honest failure mode here is silent. A fixed
# worklist cap makes a big network return LOOKING finished while a
# thousand cells still hold stale power, and every unit test on a
# hand-sized circuit stays green. So this file asserts the two things a
# small circuit can never show: that a burst too large for one drain
# pauses instead of truncating, and that resuming it reaches the exact
# fixpoint with nothing left pending.

const Y: int = 64
const FLOOR_Y: int = 63
const TORCH_Y: int = 62
const BASE_Y: int = 61
const FIELD: int = 32
const CELLS: int = FIELD * FIELD
# Small enough that the adversarial burst is guaranteed to pause many
# times, so the resume path is exercised rather than assumed.
const DRAIN_BUDGET: int = 512


# Advertises the deferral contract, so `Redstone.update_wire` hands back
# a paused burst exactly the way it does for the real ChunkManager and
# this test drives the pump itself.
class PumpedWorld:
	extends RefCounted
	var blocks: Dictionary = {}
	var metas: Dictionary = {}
	var notified: Array = []
	var writes: int = 0

	func get_world_block(pos: Vector3i) -> int:
		return blocks.get(pos, Blocks.AIR)

	func get_world_block_meta(pos: Vector3i) -> int:
		return metas.get(pos, 0)

	func set_world_block_state(pos: Vector3i, id: int, meta: int, _notify: bool = true) -> bool:
		var old_id: int = blocks.get(pos, Blocks.AIR)
		var old_meta: int = metas.get(pos, 0)
		if old_id == id and old_meta == (meta & 0xF):
			return false
		blocks[pos] = id
		metas[pos] = meta & 0xF
		writes += 1
		return true

	func enqueue_block_notification(pos: Vector3i, _source_id: int = -1) -> void:
		notified.append(pos)

	func redstone_defers_wire_bursts() -> bool:
		return true

	func put(pos: Vector3i, id: int, meta: int = 0) -> void:
		blocks[pos] = id
		metas[pos] = meta


var _w: PumpedWorld


func before_each() -> void:
	_w = PumpedWorld.new()
	Redstone.reset_state()


func after_each() -> void:
	Redstone.reset_state()


# 32 × 32 wire on stone, with a floor-mounted lit torch two cells below
# each wire. The torch strong-powers the block above it (bo.java:121),
# that block is a normal cube so it relays, and every wire cell therefore
# computes 15 independently of its neighbours.
func _build_field(with_torches: bool) -> void:
	for z in range(FIELD):
		for x in range(FIELD):
			_w.put(Vector3i(x, FLOOR_Y, z), Blocks.STONE)
			_w.put(Vector3i(x, Y, z), Blocks.REDSTONE_WIRE, 0)
			if not with_torches:
				continue
			_w.put(Vector3i(x, BASE_Y, z), Blocks.STONE)
			_w.put(Vector3i(x, TORCH_Y, z), Blocks.REDSTONE_TORCH, Redstone.MOUNT_FLOOR)


func _remove_torches() -> void:
	for z in range(FIELD):
		for x in range(FIELD):
			_w.blocks.erase(Vector3i(x, TORCH_Y, z))


func _cell(index: int) -> Vector3i:
	return Vector3i(index % FIELD, Y, index / FIELD)


# Drive the pump the way ChunkManager's `_process` does, one budget per
# simulated frame. Returns {frames, usec} so the same helper produces the
# convergence assertion and the timing sample.
func _pump_to_settle() -> Dictionary:
	var frames: int = 0
	var started: int = Time.get_ticks_usec()
	while Redstone.has_pending_wire_work():
		frames += 1
		Redstone.drain_wire_work(_w, DRAIN_BUDGET)
		assert_between(frames, 1, 100000, "pump terminates")
		if frames > 100000:
			break
	return {"frames": frames, "usec": Time.get_ticks_usec() - started}


func _metas_matching(level: int) -> int:
	var count: int = 0
	for i in range(CELLS):
		if _w.get_world_block_meta(_cell(i)) == level:
			count += 1
	return count


# --- The convergence contract ------------------------------------------


func test_adversarial_depower_pauses_resumes_and_reaches_all_zero() -> void:
	# The exact case the fixed 8,192-step cap used to abandon: 1,024 cells
	# at full power, every source pulled at once. Alpha's decay is
	# one-level-per-relaxation, so this needs roughly 15 sweeps of the
	# whole field — far more work than any single frame should do, and
	# far more than any cap that discards its queue can finish.
	_build_field(true)
	Redstone.update_wire(_w, _cell(0), true)
	_pump_to_settle()
	assert_eq(_metas_matching(15), CELLS, "every cell starts at full power")

	_remove_torches()
	_w.writes = 0
	Redstone.update_wire(_w, _cell(0), true)
	# The first drain must NOT have finished the job — otherwise this
	# fixture is not exercising the resume path at all and the rest of
	# the test proves nothing.
	assert_true(Redstone.has_pending_wire_work(), "burst pauses instead of truncating")
	var run: Dictionary = _pump_to_settle()
	assert_gt(int(run.frames), 1, "took more than one drain to converge")
	assert_false(Redstone.has_pending_wire_work(), "no work left pending")
	assert_eq(Redstone.pending_wire_cells(), 0, "worklist empty")
	assert_eq(_metas_matching(0), CELLS, "every one of the 1024 cells reached zero")
	var stats: Dictionary = Redstone.last_burst_stats()
	gut.p(
		(
			"[perf] 1024-cell depower: %d frames, %d steps, %d writes, %.1f ms total"
			% [int(run.frames), int(stats.steps), int(stats.writes), float(run.usec) / 1000.0]
		)
	)


func test_a_paused_burst_withholds_its_notifications() -> void:
	# A consumer that acted on a half-drained network would see a line
	# that is neither the old state nor the new one. Zero-crossings are
	# therefore collected and only published once the queue empties.
	_build_field(true)
	Redstone.update_wire(_w, _cell(0), true)
	assert_true(Redstone.has_pending_wire_work(), "burst is mid-flight")
	assert_eq(_w.notified.size(), 0, "nothing notified while paused")
	_pump_to_settle()
	assert_gt(_w.notified.size(), 0, "notifications arrive once settled")


func test_reconcile_from_any_seed_repairs_the_whole_field() -> void:
	# Stale-load contract: metadata written by a previous session is
	# wrong, and an update seeded at one corner still has to fix all of
	# it. Seeded at the FAR corner from cell 0 to make the walk maximal.
	_build_field(true)
	for i in range(CELLS):
		_w.metas[_cell(i)] = 3
	Redstone.update_wire(_w, _cell(CELLS - 1), true)
	_pump_to_settle()
	assert_eq(_metas_matching(15), CELLS, "whole field reconciled from one seed")


func test_change_driven_seed_on_a_settled_field_does_no_work() -> void:
	# The cheap path, and the reason `reconcile` is opt-in: once settled,
	# a neighbour notification must cost one cell evaluation, not a walk
	# of the network. This is the property that keeps a big circuit from
	# taxing every frame it merely exists in.
	_build_field(true)
	Redstone.update_wire(_w, _cell(0), true)
	_pump_to_settle()
	_w.writes = 0
	var samples: Array[float] = []
	for i in range(100):
		var started: int = Time.get_ticks_usec()
		Redstone.update_wire(_w, _cell(i * 7 % CELLS))
		_pump_to_settle()
		samples.append(float(Time.get_ticks_usec() - started))
	assert_eq(_w.writes, 0, "a settled network rewrites nothing")
	samples.sort()
	gut.p("[perf] settled seed x100: median %.1f us, p95 %.1f us" % [samples[50], samples[94]])
	# Generous, because CI hardware varies wildly — the assertion that
	# matters is the zero above. This only catches an accidental return
	# to full-network traversal, which was ~3 orders of magnitude worse.
	assert_lt(samples[94], 2000.0, "settled seed stays far below a frame")


func test_power_up_from_dark_converges_and_is_reported() -> void:
	_build_field(false)
	Redstone.update_wire(_w, _cell(0), true)
	_pump_to_settle()
	assert_eq(_metas_matching(0), CELLS, "no sources, no power")
	for z in range(FIELD):
		for x in range(FIELD):
			_w.put(Vector3i(x, BASE_Y, z), Blocks.STONE)
			_w.put(Vector3i(x, TORCH_Y, z), Blocks.REDSTONE_TORCH, Redstone.MOUNT_FLOOR)
	Redstone.update_wire(_w, _cell(0), true)
	var run: Dictionary = _pump_to_settle()
	assert_eq(_metas_matching(15), CELLS, "every cell reaches full power")
	var stats: Dictionary = Redstone.last_burst_stats()
	gut.p(
		(
			"[perf] 1024-cell power-up: %d frames, %d steps, %.1f ms total"
			% [int(run.frames), int(stats.steps), float(run.usec) / 1000.0]
		)
	)


func test_a_time_budget_bounds_the_drain_and_still_converges() -> void:
	# What production actually uses. A step budget means something
	# different on a desktop and on mobile web (several times slower per
	# relaxation), so the pump is bounded by the clock instead — and the
	# frame it is bounded to has to hold whatever the wire is doing.
	_build_field(true)
	Redstone.update_wire(_w, _cell(0), true)
	while Redstone.has_pending_wire_work():
		Redstone.drain_wire_work(_w, Redstone.WIRE_STEPS_PER_DRAIN, Redstone.WIRE_USEC_PER_DRAIN)
	_remove_torches()
	Redstone.update_wire(_w, _cell(0), true)
	var samples: Array[float] = []
	while Redstone.has_pending_wire_work():
		var started: int = Time.get_ticks_usec()
		Redstone.drain_wire_work(_w, Redstone.WIRE_STEPS_PER_DRAIN, Redstone.WIRE_USEC_PER_DRAIN)
		samples.append(float(Time.get_ticks_usec() - started))
		if samples.size() > 10000:
			break
	assert_eq(_metas_matching(0), CELLS, "converges under a time budget too")
	assert_false(Redstone.has_pending_wire_work(), "nothing pending")
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	var median: float = sorted[sorted.size() / 2]
	var p95: float = sorted[int(sorted.size() * 0.95)]
	(
		gut
		. p(
			(
				"[perf] 1024-cell depower @ %d us budget: %d drains, median %.2f ms, p95 %.2f ms, max %.2f ms"
				% [
					Redstone.WIRE_USEC_PER_DRAIN,
					samples.size(),
					median / 1000.0,
					p95 / 1000.0,
					sorted[-1] / 1000.0,
				]
			)
		)
	)
	# Deliberately NOT asserted. Wall-clock in a unit suite measures the
	# machine, not the code: the same fixture varies ~30% between runs on
	# this laptop and more under a full-suite load, so a threshold here
	# would be a flake generator that eventually gets deleted or widened
	# until it means nothing. The numbers are recorded above for the
	# release gate; the deterministic proof that the budget is WIRED UP
	# lives in the test below.
	assert_between(median, 0.0, 1e9, "median recorded")


func test_a_tiny_time_budget_forces_many_short_drains() -> void:
	# The mechanism check that the timing report can't give us. With a
	# 1 µs budget every drain must bail at its first clock check, so a
	# burst that needs thousands of relaxations has to come back for
	# thousands of drains. If the time bound were ignored — or checked
	# only after the step budget — this would settle in one or two.
	_build_field(true)
	Redstone.update_wire(_w, _cell(0), true)
	var drains: int = 0
	while Redstone.has_pending_wire_work() and drains < 200000:
		drains += 1
		Redstone.drain_wire_work(_w, Redstone.WIRE_STEPS_PER_DRAIN, 1)
	assert_gt(drains, 100, "a 1 us budget yields many short drains")
	assert_eq(_metas_matching(15), CELLS, "and still converges exactly")


func test_a_world_swap_does_not_carry_a_burst_across():
	# Bursts are module state, so a world torn down mid-propagation must
	# not leave its worklist pointing at cells in the next world.
	_build_field(true)
	Redstone.update_wire(_w, _cell(0), true)
	assert_true(Redstone.has_pending_wire_work(), "burst in flight")
	var other := PumpedWorld.new()
	other.put(Vector3i(0, FLOOR_Y, 0), Blocks.STONE)
	other.put(Vector3i(0, Y, 0), Blocks.REDSTONE_WIRE, 0)
	Redstone.update_wire(other, Vector3i(0, Y, 0))
	assert_false(Redstone.has_pending_wire_work(), "new world's tiny burst settled on its own")
	assert_eq(other.get_world_block_meta(Vector3i(0, Y, 0)), 0, "and produced its own answer")
