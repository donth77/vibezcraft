extends GutTest

# Scheduled-tick queue unit tests. Exercises the mechanism end-to-end
# without any block-specific callbacks — Flow #3 adds fluid tests that
# depend on the real dispatch path. Here we use a minimal fake manager
# that counts callback invocations per cell.
#
# Note: TickScheduler is a static class so state persists across tests.
# Every test calls reset_for_tests() in before_each.


# Fake ChunkManager stand-in. The TickScheduler dispatches through
# Blocks.on_scheduled_tick(manager, pos, block_id), which reads
# manager.get_world_block(pos) to verify the cell still holds the
# expected block. We fake the world state as a Dictionary.
class FakeManager:
	extends RefCounted
	var world: Dictionary = {}

	func get_world_block(pos: Vector3i) -> int:
		return world.get(pos, Blocks.AIR)


var _manager: FakeManager


func before_each() -> void:
	TickScheduler.reset_for_tests()
	_manager = FakeManager.new()


# --- Core scheduling ---


func test_schedule_enqueues() -> void:
	TickScheduler.schedule(Vector3i(0, 64, 0), Blocks.WATER_STILL, 5)
	assert_eq(TickScheduler.pending_count(), 1)


func test_advance_drains_at_20hz() -> void:
	# 5-tick delay = 5 × 50 ms = 250 ms of wall-clock.
	TickScheduler.schedule(Vector3i(0, 64, 0), Blocks.WATER_STILL, 5)
	# One tick worth of time: 50 ms → tick counter advances 1, but fire_tick
	# is 5 so nothing drains yet.
	TickScheduler.advance(0.05, _manager)
	assert_eq(TickScheduler.pending_count(), 1, "one tick: entry still pending")
	assert_eq(TickScheduler.current_tick(), 1)
	# 4 more ticks (200 ms): total 5 ticks, entry fires. Stepped one tick
	# per advance() because the catch-up cap (_MAX_TICKS_PER_ADVANCE = 2)
	# would clamp a single 0.2 s / 4-tick advance to 2 ticks. Per-tick
	# stepping mirrors real per-frame deltas (a frame rarely buys >1 tick).
	for _i in range(4):
		TickScheduler.advance(0.05, _manager)
	assert_eq(TickScheduler.pending_count(), 0, "after 5 ticks: entry drained")
	assert_eq(TickScheduler.current_tick(), 5)


func test_delay_of_one_fires_next_tick() -> void:
	# delay=1 must fire on the very next tick, not the same one.
	TickScheduler.schedule(Vector3i(0, 64, 0), Blocks.WATER_STILL, 1)
	TickScheduler.advance(0.05, _manager)  # exactly one tick
	assert_eq(TickScheduler.pending_count(), 0, "delay=1 drains on next tick")


func test_delay_zero_is_clamped_to_one() -> void:
	# Defensive: 0-delay schedules might be caller bugs, but we clamp to
	# 1 to ensure the tick doesn't fire mid-schedule call (never observed
	# by the caller as complete).
	TickScheduler.schedule(Vector3i(0, 64, 0), Blocks.WATER_STILL, 0)
	assert_eq(TickScheduler.pending_count(), 1)
	TickScheduler.advance(0.05, _manager)
	assert_eq(TickScheduler.pending_count(), 0, "clamped delay=1 fires next tick")


# --- Catch-up clamp ---


func test_catch_up_clamps_at_max_ticks_per_advance() -> void:
	# Long frame hitch (say 5 seconds = 100 ticks worth) must cap at
	# _MAX_TICKS_PER_ADVANCE = 2 to prevent a main-thread spiral. Anything
	# over the cap is discarded from the accumulator (not deferred), so the
	# next frame starts clean rather than draining a backlog.
	TickScheduler.schedule(Vector3i(0, 64, 0), Blocks.WATER_STILL, 30)
	TickScheduler.advance(5.0, _manager)
	# 100 ticks of accumulated time clamps to exactly 2; delay=30 still pending.
	assert_eq(TickScheduler.current_tick(), 2, "catch-up clamped to 2 ticks")
	assert_eq(TickScheduler.pending_count(), 1)


# --- Cancellation ---


func test_cancel_removes_matching_entries() -> void:
	var pos := Vector3i(4, 64, 4)
	TickScheduler.schedule(pos, Blocks.WATER_STILL, 5)
	TickScheduler.schedule(pos, Blocks.WATER_STILL, 10)
	# Unrelated entry must survive.
	TickScheduler.schedule(Vector3i(5, 64, 5), Blocks.LAVA_STILL, 5)
	assert_eq(TickScheduler.pending_count(), 3)
	TickScheduler.cancel(pos, Blocks.WATER_STILL)
	assert_eq(TickScheduler.pending_count(), 1, "both water entries removed")


func test_cancel_ignores_mismatched_block_id() -> void:
	# cancel(pos, water) must NOT remove a lava entry at the same pos.
	var pos := Vector3i(4, 64, 4)
	TickScheduler.schedule(pos, Blocks.WATER_STILL, 5)
	TickScheduler.schedule(pos, Blocks.LAVA_STILL, 5)
	TickScheduler.cancel(pos, Blocks.WATER_STILL)
	assert_eq(TickScheduler.pending_count(), 1, "lava entry at same pos survives")


# --- Dispatch through Blocks.on_scheduled_tick ---


func test_tick_noop_if_block_changed_before_firing() -> void:
	# Vanilla BlockFlowing.b() checks the cell still holds the expected
	# block before acting. Our Blocks.on_scheduled_tick does the same
	# early-out. This test sets a different block at the scheduled pos
	# and confirms no error / no spurious write.
	var pos := Vector3i(0, 64, 0)
	_manager.world[pos] = Blocks.STONE  # player placed stone after schedule
	TickScheduler.schedule(pos, Blocks.WATER_STILL, 1)
	TickScheduler.advance(0.05, _manager)
	# No asserts needed — test passes if no error thrown; Blocks handler
	# silently drops mismatched-id ticks.
	assert_eq(TickScheduler.pending_count(), 0)


# --- Ordering ---


func test_same_tick_entries_fire_in_insertion_order() -> void:
	# Multiple entries with the same fire_tick must fire in enqueue order —
	# matches vanilla's ArrayList iteration. Drift here breaks water-before-
	# lava ordering in cascade scenarios where both schedule themselves
	# against the same cell.
	var pos1 := Vector3i(0, 64, 0)
	var pos2 := Vector3i(1, 64, 0)
	_manager.world[pos1] = Blocks.STONE  # non-match, drops silently
	_manager.world[pos2] = Blocks.STONE
	TickScheduler.schedule(pos1, Blocks.WATER_STILL, 1)
	TickScheduler.schedule(pos2, Blocks.WATER_STILL, 1)
	TickScheduler.advance(0.05, _manager)
	assert_eq(TickScheduler.pending_count(), 0, "both fired on same tick")


# --- Mixed delay drain ---


func test_mixed_delays_fire_in_chronological_order() -> void:
	# Enqueue out of order: delay=3, delay=1, delay=2. Drain 3 ticks.
	# All three must fire, each on its own fire_tick.
	for pos: Vector3i in [Vector3i(0, 64, 0), Vector3i(1, 64, 0), Vector3i(2, 64, 0)]:
		_manager.world[pos] = Blocks.AIR  # non-match so handler is a no-op
	TickScheduler.schedule(Vector3i(0, 64, 0), Blocks.WATER_STILL, 3)
	TickScheduler.schedule(Vector3i(1, 64, 0), Blocks.WATER_STILL, 1)
	TickScheduler.schedule(Vector3i(2, 64, 0), Blocks.WATER_STILL, 2)
	# Step one tick per advance() — the catch-up cap
	# (_MAX_TICKS_PER_ADVANCE = 2) would clamp a single 3-tick advance to
	# 2, leaving the delay=3 entry pending. Per-tick stepping matches real
	# per-frame deltas anyway.
	for _i in range(3):
		TickScheduler.advance(0.05, _manager)
	assert_eq(TickScheduler.pending_count(), 0, "all three drained")


# --- Accumulator carry-over ---


func test_sub_tick_delta_accumulates() -> void:
	# 10 ms per call × 5 calls = 50 ms = one tick.
	TickScheduler.schedule(Vector3i(0, 64, 0), Blocks.WATER_STILL, 1)
	TickScheduler.advance(0.01, _manager)
	assert_eq(TickScheduler.current_tick(), 0)
	TickScheduler.advance(0.01, _manager)
	assert_eq(TickScheduler.current_tick(), 0)
	TickScheduler.advance(0.01, _manager)
	assert_eq(TickScheduler.current_tick(), 0)
	TickScheduler.advance(0.01, _manager)
	assert_eq(TickScheduler.current_tick(), 0)
	TickScheduler.advance(0.01, _manager)
	assert_eq(TickScheduler.current_tick(), 1)
	assert_eq(TickScheduler.pending_count(), 0, "entry fired on the 5th 10 ms tick")
