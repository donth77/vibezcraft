class_name DimensionContext
extends RefCounted

# Which dimension is resident, and the epoch that invalidates work queued
# for a previous one (docs/nether-alpha-1.2.6-implementation-plan.md
# §3.2/§3.3, Batch 1).
#
# Static state, matching the project's Blocks/Items/Worldgen convention —
# there is exactly one resident dimension at a time (plan §3.3), so a
# singleton is the honest model. Two dimension scene graphs are never
# resident simultaneously.
#
# The epoch is the safety mechanism for the threading contract. Chunk
# generation runs on WorkerThreadPool, so a task dispatched before a
# portal transition can finish after it and try to materialise Overworld
# terrain into the Nether. Every queued job carries the dimension and
# epoch it was dispatched under; `accepts_result` rejects anything that
# no longer matches. Bumping the epoch is therefore how a transition
# cancels in-flight work it cannot actually stop.

const OVERWORLD: int = WorldProvider.OVERWORLD_ID
const NETHER: int = WorldProvider.NETHER_ID

# id → WorldProvider. Built lazily so no boot ordering is required.
static var _providers: Dictionary = {}
static var _active: int = OVERWORLD
# Monotonic. Never reset except by `reset()` between worlds/tests, so a
# stale result can never coincidentally match a recycled value.
static var _epoch: int = 0


static func _ensure_providers() -> void:
	if not _providers.is_empty():
		return
	# The base WorldProvider IS the Overworld — its defaults are the
	# values the engine already used.
	var overworld := WorldProvider.new()
	_providers[overworld.id] = overworld
	var nether := NetherProvider.new()
	_providers[nether.id] = nether


static func provider(dimension_id: int = -2147483648) -> WorldProvider:
	_ensure_providers()
	var wanted: int = _active if dimension_id == -2147483648 else dimension_id
	if not _providers.has(wanted):
		push_error("[DimensionContext] no provider for dimension %d" % wanted)
		return _providers[OVERWORLD] as WorldProvider
	return _providers[wanted] as WorldProvider


static func is_registered(dimension_id: int) -> bool:
	_ensure_providers()
	return _providers.has(dimension_id)


static func registered_ids() -> Array:
	_ensure_providers()
	var ids: Array = _providers.keys()
	ids.sort()
	return ids


# --- Active dimension ---


static func active() -> int:
	return _active


static func active_provider() -> WorldProvider:
	return provider(_active)


# Set the resident dimension. Callers that are performing a real
# transition should go through `begin_transition` first so in-flight
# worker results are invalidated; this setter alone does not bump the
# epoch, because world LOAD also uses it and has no stale work to reject.
static func set_active(dimension_id: int) -> void:
	_ensure_providers()
	if not _providers.has(dimension_id):
		push_error(
			"[DimensionContext] refusing to activate unregistered dimension %d" % dimension_id
		)
		return
	_active = dimension_id


# --- Epoch ---


static func epoch() -> int:
	return _epoch


# Invalidate every job and result queued so far and return the new epoch.
# Call this at the START of a transition, before any unload, so work that
# lands mid-teardown is already rejectable.
static func begin_transition() -> int:
	_epoch += 1
	return _epoch


# The guard every queued result must pass before it is applied. A result
# is only valid if it was produced for the dimension that is resident NOW
# and under the current epoch.
static func accepts_result(dimension_id: int, result_epoch: int) -> bool:
	return dimension_id == _active and result_epoch == _epoch


# --- Convenience ---


static func is_overworld() -> bool:
	return _active == OVERWORLD


static func is_nether() -> bool:
	return _active == NETHER


# Full reset. Used when opening a world and by tests; returns to the
# Overworld and bumps the epoch so nothing queued by a previous world can
# be mistaken for current work.
static func reset() -> void:
	_active = OVERWORLD
	_epoch += 1
