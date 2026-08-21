class_name PortalTravel
extends RefCounted

# The dimension-travel transaction — plan §7.2's nine numbered steps, in
# order, in one place.
#
# It reads as a lot of ceremony for "move the player", and the reason is
# step 9: a transition that fails halfway leaves a save file describing a
# world that does not exist. Every step before the point of no return is
# reversible, and the one irreversible step (ChunkManager's own
# transition, which frees the source scene) already restores the source
# dimension on failure.
#
# A coroutine, because materializing the destination ring has to yield
# between chunks or the loading screen never paints — the player would
# get a multi-second black freeze instead of "Entering the Nether".

# Chunks either side of the arrival to force-materialize before searching.
# 2 covers a 5x5 = 25-chunk block, which is 40 blocks either way — more
# than NetherTeleporter.BUILD_RADIUS, so a portal the transaction decides
# to BUILD always lands in resident chunks.
const RING_RADIUS: int = 2

# Alpha's own loading labels (`no.java` sets them via the progress
# listener). Not "Loading Nether" — the direction is part of the string.
const LABEL_ENTERING: String = "Entering the Nether"
const LABEL_LEAVING: String = "Leaving the Nether"

# Guard against a second trip starting while one is mid-flight. The
# ChunkManager has its own re-entrancy guard, but this one also covers the
# awaits before and after it, during which the manager is not yet busy.
# Hostile-spawn suppression granted to the destination on arrival.
# Long enough to look around, find the ground and step clear of the
# portal; short enough that the dimension still feels hostile.
const ARRIVAL_SPAWN_GRACE_SEC: float = 12.0

static var _in_progress: bool = false


static func in_progress() -> bool:
	return _in_progress


# Where a player standing in a portal in `from_dimension` should end up.
static func destination_dimension(from_dimension: int) -> int:
	if from_dimension == DimensionContext.NETHER:
		return DimensionContext.OVERWORLD
	return DimensionContext.NETHER


static func label_for(target_dimension: int) -> String:
	return LABEL_ENTERING if target_dimension == DimensionContext.NETHER else LABEL_LEAVING


# Run the whole trip. Returns true when the player ended up in the target
# dimension. Awaits frames, so callers that need the result must await it;
# callers that just want it to happen can fire and forget, because
# Game.is_loading freezes the player for the duration either way.
static func travel(player: Node3D, chunk_manager: Node) -> bool:
	if _in_progress:
		return false
	if player == null or chunk_manager == null:
		return false
	var source: int = DimensionContext.active()
	var target: int = destination_dimension(source)
	if not DimensionContext.is_registered(target):
		push_error("[PortalTravel] no provider for dimension %d" % target)
		return false
	_in_progress = true

	# 1. Lock input and expose the loading UI. Game.is_loading is what
	#    actually freezes the player's physics and mutes gameplay SFX;
	#    the screen is the part the player sees.
	var tree: SceneTree = player.get_tree()
	var screen: CanvasLayer = null
	if tree != null:
		screen = LoadingScreen.show_transition(tree, label_for(target))
	Game.is_loading = true

	# 2-5. Persist the source, bump the epoch, tear the scene down, switch
	#      provider. All inside ChunkManager's own transaction, which
	#      restores the source dimension if the destination is unusable.
	var arrival_centre: Vector3 = NetherTeleporter.scale_position(
		player.global_position, source, target
	)
	var switched: bool = chunk_manager.call(
		"transition_to_dimension", target, _safe_landing(arrival_centre)
	)
	if not switched:
		# 9. Failure before any world state changed. The manager has
		#    already put the source dimension back; all we owe the player
		#    is their controls.
		_finish(screen)
		_in_progress = false
		return false

	# 7. Materialize a ring around the arrival so the search has real
	#    blocks to look at and the player has something to stand on.
	#    PortalIndex supplies the chunks a known portal lives in, which is
	#    the only way a portal outside the ring can be found at all — but
	#    it is a hint, and the raw search below is what decides.
	await _materialize(chunk_manager, arrival_centre, target, screen, tree)

	# The player node can in principle be freed while we were awaiting
	# (scene teardown mid-trip); everything below dereferences it.
	if not is_instance_valid(player):
		_finish(screen)
		_in_progress = false
		return false
	# Normal streaming ran during those awaited frames, and it evicts
	# chunks outside the render-distance ring at 4 per frame — which can
	# include hint chunks we sync-spawned for a DISTANT known portal
	# (audit finding #8). Re-pin them with no awaits in between, so the
	# search below sees every chunk it was promised; re-spawning a chunk
	# that is still resident is a cheap force-apply.
	for coord: Vector2i in PortalIndex.chunk_hints(
		target, arrival_centre, NetherTeleporter.SEARCH_RADIUS
	):
		chunk_manager.call("spawn_chunk_now", coord)

	# 6. Find or create the destination portal, then place the player.
	var landing: Vector3 = NetherTeleporter.destination_for(chunk_manager, arrival_centre)

	# 8. Place, zero velocity, preserve yaw, pitch to zero, persist.
	player.global_position = landing
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO
	if player.has_method("reset_pitch"):
		player.call("reset_pitch")
	if player.has_method("reset_portal_exposure"):
		player.call("reset_portal_exposure")
	# The chunk the player now stands in may be outside the ring we just
	# built (a portal found at the edge of the index hints), so guarantee
	# its neighbourhood before releasing physics.
	_materialize_around(chunk_manager, landing)
	# The ground under the landing must be ACTIVE collision before
	# is_loading clears, or the player's ground guard freezes them inside
	# the portal while the exposure meter refills — the enter/leave loop.
	if chunk_manager.has_method("refresh_collision_activity"):
		chunk_manager.call("refresh_collision_activity")
	# Headless sessions are read-only — the same rule as every
	# ChunkManager disk path (see _disk_writes_allowed and the World1
	# fossil incident it exists for).
	if DisplayServer.get_name() != "headless":
		PlayerSave.save_player(player)
	# Breathing room on the far side — see grant_spawn_grace for why this
	# deviates from vanilla.
	if NaturalMobSpawner != null:
		NaturalMobSpawner.grant_spawn_grace(ARRIVAL_SPAWN_GRACE_SEC)
	DebugLog.add(
		"PORTAL",
		(
			"arrived dim=%d landing=%v ground_ready=%s"
			% [
				DimensionContext.active(),
				landing,
				str(chunk_manager.call("is_ground_ready_at", landing))
			]
		)
	)
	_finish(screen)
	# AFTER _finish, which clears Game.is_loading — the optional sound
	# player gates on that flag, so ordered the other way round the
	# travel sound could never play (audit finding #7).
	SFX.play_portal_travel()
	_in_progress = false
	return true


# Y is not scaled between dimensions, so an Overworld player at Y 5 maps
# to Nether Y 5 — inside the bedrock floor. Clamping only the value handed
# to the ChunkManager keeps the SEARCH centred on the true scaled point
# (which is what decides which portal is nearest) while making sure the
# streaming centre and the interim player position are somewhere survivable.
static func _safe_landing(arrival_centre: Vector3) -> Vector3:
	return Vector3(
		arrival_centre.x,
		clampf(arrival_centre.y, float(NetherTeleporter.FALLBACK_MIN_Y), 120.0),
		arrival_centre.z
	)


static func _materialize(
	chunk_manager: Node, centre: Vector3, dimension: int, screen: CanvasLayer, tree: SceneTree
) -> void:
	var coords: Array[Vector2i] = []
	var seen: Dictionary = {}
	var centre_chunk := Vector2i(
		int(floor(centre.x / float(Chunk.SIZE_X))), int(floor(centre.z / float(Chunk.SIZE_Z)))
	)
	for dx: int in range(-RING_RADIUS, RING_RADIUS + 1):
		for dz: int in range(-RING_RADIUS, RING_RADIUS + 1):
			var coord := centre_chunk + Vector2i(dx, dz)
			seen[coord] = true
			coords.append(coord)
	for coord: Vector2i in PortalIndex.chunk_hints(
		dimension, centre, NetherTeleporter.SEARCH_RADIUS
	):
		if seen.has(coord):
			continue
		seen[coord] = true
		coords.append(coord)
	for i: int in range(coords.size()):
		chunk_manager.call("spawn_chunk_now", coords[i])
		if screen != null and is_instance_valid(screen):
			screen.call("set_progress", float(i + 1) / float(coords.size()))
		# Yield so the loading screen actually renders a frame. Without
		# this the whole ring builds inside one frame and the player sees
		# a freeze rather than a progress bar.
		if tree != null:
			await tree.process_frame


static func _materialize_around(chunk_manager: Node, position: Vector3) -> void:
	var centre := Vector2i(
		int(floor(position.x / float(Chunk.SIZE_X))), int(floor(position.z / float(Chunk.SIZE_Z)))
	)
	for dx: int in [-1, 0, 1]:
		for dz: int in [-1, 0, 1]:
			chunk_manager.call("spawn_chunk_now", centre + Vector2i(dx, dz))


static func _finish(screen: CanvasLayer) -> void:
	if screen != null and is_instance_valid(screen):
		screen.call("dismiss")
	else:
		Game.is_loading = false
