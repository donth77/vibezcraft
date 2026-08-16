class_name PortalExposure
extends RefCounted

# Alpha 1.2.6 portal exposure — a port of `bq.java:33-57`.
# See docs/nether-alpha-1.2.6-implementation-plan.md §7.2.
#
# Standing in a portal fills a 0..1 meter; reaching 1 travels. Stepping
# out drains it four times faster than it fills, which is why a quick
# walk-through does nothing and lingering is required:
#
#     in portal:   c += 0.0125   -> 80 ticks (4 s at 20 Hz) from empty
#     out:         c -= 0.05     -> 20 ticks to drain a full meter
#
# On travel the meter pins at 1 and a ten-tick cooldown starts, which is
# what stops the player bouncing straight back through the portal they
# just arrived in.
#
# Kept as its own object rather than three fields on the player so the
# timeline is testable without a scene: the exact tick a trigger sound
# fires, and the exact tick travel happens, are both observable.

# bq.java:39 — fill rate per tick.
const FILL_PER_TICK: float = 0.0125
# bq.java:49 — drain rate per tick.
const DRAIN_PER_TICK: float = 0.05
# bq.java:42 — cooldown ticks after a travel.
const COOLDOWN_TICKS: int = 10
# The nominal figure is 1.0 / 0.0125 = 80 ticks, and that is what the
# plan and every wiki page quote. The REAL answer is 81.
#
# 0.0125 is not exactly representable in binary, and Alpha accumulates it
# into a Java `float`. Eighty additions land at 0.99999... — just short —
# so the meter crosses 1.0 on the eighty-FIRST tick. Both float32 and
# double accumulation agree on that, so it is a property of the constant
# rather than of the precision.
const TICKS_TO_TRAVEL: int = 81

# 0..1. Alpha's `this.c`.
var exposure: float = 0.0
# Alpha's `this.b` — counts down after a travel.
var cooldown: int = 0

# Set true by whatever detects the player standing in a portal cell, each
# tick, before `advance`. Alpha's `this.by`, set from the portal block's
# entity-collision hook.
var in_portal: bool = false

# Emitted-once flags for the caller to turn into sounds. Reset each tick.
var triggered_this_tick: bool = false
var travelled_this_tick: bool = false


# One tick of the state machine. Returns true when travel should happen
# NOW — the caller performs the dimension transition and is responsible
# for clearing `in_portal` afterwards.
func advance() -> bool:
	triggered_this_tick = false
	travelled_this_tick = false
	var travel: bool = false
	if in_portal:
		# bq.java:36-38 — the trigger sound fires on the tick the meter
		# LEAVES zero, not on every tick inside.
		if exposure == 0.0:
			triggered_this_tick = true
		# Accumulated through float32, because Alpha's `this.c` is a
		# Java float and the rounding is what sets the exact travel tick.
		exposure = AlphaMath.f32(exposure + FILL_PER_TICK)
		if exposure >= 1.0:
			exposure = 1.0
			cooldown = COOLDOWN_TICKS
			travelled_this_tick = true
			travel = true
	else:
		if exposure > 0.0:
			exposure = AlphaMath.f32(exposure - DRAIN_PER_TICK)
		if exposure < 0.0:
			exposure = 0.0
	if cooldown > 0:
		cooldown -= 1
	return travel


# True while the ten-tick post-travel cooldown is running. Callers use it
# to suppress re-entry: the player arrives standing IN the destination
# portal, and without this they would immediately start filling again.
func on_cooldown() -> bool:
	return cooldown > 0


# Reset everything — used on death, world load and dimension switch.
func reset() -> void:
	exposure = 0.0
	cooldown = 0
	in_portal = false
	triggered_this_tick = false
	travelled_this_tick = false
