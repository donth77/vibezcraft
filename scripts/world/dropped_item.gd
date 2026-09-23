class_name DroppedItem
extends Node3D

# Vanilla MC dropped-item behavior:
#   - Spawns at the broken-block position and hovers (no gravity, no
#     collision — MC items just float in place at the spawn height).
#   - Sine-wave bob + slow Y-spin for visual life.
#   - Magnet: when player gets within MAGNET_RADIUS, accelerates toward them.
#   - Pickup: at PICKUP_RADIUS the item plays "pop", removes self, adds to
#     the player's inventory. PICKUP_DELAY_SEC prevents instant re-grab off
#     your own break.
#   - Five source health points: fire/lava contact and the trailing burn
#     damage that follows it destroy the entity without producing a drop.

const MESH_SIZE: float = 0.25
const PICKUP_DELAY_SEC: float = 0.5  # default for break-spawned items
# Vanilla Alpha 1.2.6: eo.java:126 sets delayBeforeCanPickup=40 ticks (2s)
# for ANY player-originated drop — Q-throw OR death (eb.b → fo.g → eb.a).
# Same delay for both, so the player can sprint back to a death pile and
# scoop loot before items despawn at LIFETIME_SEC (6000 ticks = 5 min).
const PLAYER_DROP_DELAY_SEC: float = 2.0
const LIFETIME_SEC: float = 300.0  # matches vanilla Java MC
const PICKUP_RADIUS: float = 0.9
const MAGNET_RADIUS: float = 1.8
const MAGNET_SPEED: float = 9.0
const SPIN_SPEED: float = 1.2  # rad/s
# Alpha af.java:24 — `sin((age + partial) / 10.0 + d) * 0.1 + 0.1`. Per-tick
# phase increment is 1/10 rad; at 20 tps that's 2 rad/s → 1/π ≈ 0.3183 Hz
# (one full bob every ~3.14 s). Amplitude 0.1 with +0.1 bias gives a
# non-negative [0, 0.2] block offset.
const HOVER_AMPLITUDE: float = 0.1
const HOVER_FREQUENCY: float = 1.0 / PI  # cycles/sec — ~0.318
const GRAVITY: float = -22.0  # vanilla feel — items arc and settle quickly, not float
const TERMINAL_VELOCITY: float = -32.0
const HORIZONTAL_DRAG: float = 2.5  # 1/s — quickly damps thrown velocity

# Alpha 1.2.6 EntityItem (`eo.java`). The item starts with five health and
# inherits Entity's 20 Hz fire bookkeeping: burning-block contact deals one
# damage every source tick, and an active Fire counter deals another point
# whenever it is divisible by 20. `cy.java::c(AABB)` treats FIRE and both
# lava states as burning blocks, so either hazard eventually calls J()/die.
const _SOURCE_TICKS_PER_SEC: float = 20.0
const _SOURCE_TICK_SEC: float = 1.0 / _SOURCE_TICKS_PER_SEC
const _SOURCE_HEALTH: int = 5
const _CONTACT_DAMAGE: int = 1
const _BURN_DURATION_TICKS: int = 300
const _BURN_DAMAGE_INTERVAL_TICKS: int = 20
const _CONTACT_FIRE: int = 1
const _CONTACT_LAVA: int = 2
const _CONTACT_WATER: int = 4
const _AABB_EPSILON: float = 0.0001
# Block collision (_clip_move). The skin keeps the floor an item rests on
# from reading as a wall across the float noise of its resting height; the
# gap parks a blocked item a hair short of the face so it never starts the
# next frame overlapping it.
const _COLLIDE_SKIN: float = 0.001
const _CONTACT_GAP: float = 0.0001

# Distance LOD. Items are the one entity class that routinely exists in
# the dozens — one creeper in a sand pile drops scores at once — and until
# now every single one ran the whole per-frame pipeline no matter where it
# was: billboard or spin, a brightness sample and material write, an
# entity-contact report, the 20 Hz hazard tick, a magnet check, the
# push-out-of-solid scan, and a PhysicsDirectSpaceState3D.intersect_ray.
# MobBase has had a four-tier gate for exactly this reason; items never
# got one.
#
# Inside NEAR nothing changes. Past it the item is a handful of pixels, so
# the visual work goes and the magnet cannot possibly apply (the player
# would have to be within MAGNET_RADIUS, which is 1.8 m). Past DORMANT an
# item that has already come to rest stops ticking entirely bar its
# despawn clock.
const _LOD_NEAR_RADIUS: float = 24.0
const _LOD_DORMANT_RADIUS: float = 64.0
const _LOD_NEAR_RADIUS_SQ: float = _LOD_NEAR_RADIUS * _LOD_NEAR_RADIUS
const _LOD_DORMANT_RADIUS_SQ: float = _LOD_DORMANT_RADIUS * _LOD_DORMANT_RADIUS
# Measuring the distance is itself per-item work, and an item 60 m out does
# not become 20 m out inside one frame unless the player teleports — and a
# portal hop frees every transient entity anyway.
const _LOD_REFRESH_SEC: float = 0.25

# A settled item re-derives the same answer every frame: gravity nudges it
# down a hair, the floor probe snaps it back, velocity returns to zero.
# That is one ray query per item per frame to stay exactly still. While at
# rest the probe drops to this period — the only thing it can discover is
# the floor being mined out from under it, and a fifth of a second of
# latency on that is invisible.
const _REST_PROBE_SEC: float = 0.2
const _REST_SPEED_EPSILON: float = 0.01

var item_id: int = 0
var _spawn_time: float = 0.0
var _hover_phase: float = 0.0
var _velocity: Vector3 = Vector3.ZERO  # full 3D so thrown items arc forward
var _pickup_delay: float = PICKUP_DELAY_SEC
var _picked_up: bool = false
var _health: int = _SOURCE_HEALTH
# `lw.bg` starts at 0, settles to -fireResistance while safe, and becomes
# 300 after entering a burning block. Preserve the signed state because the
# -1 -> 0 edge is what seeds the full trailing-burn duration in the source.
var _fire_ticks: int = 0
var _hazard_tick_accum: float = 0.0
var _is_sprite_item: bool = false  # vanilla af.java RenderItem "item" branch
var _mesh: MeshInstance3D
var _player: Node3D
var _camera: Camera3D  # cached — used to billboard sprite items
var _chunk_manager: Node  # cached — used by push-out-of-solid-block
var _ray_query: PhysicsRayQueryParameters3D  # reused per-frame to avoid allocs
# Last `world_brightness` pushed to the sprite material. -1 forces the
# first write. Vanilla af.java samples every render frame; we skip
# negligible deltas to avoid GPU uniform churn on a stack of items.
var _last_brightness: float = -1.0
# LOD bookkeeping — see the _LOD_* constants. `_near` and `_dormant` are
# recomputed on the refresh cadence rather than per frame.
var _near: bool = true
var _dormant: bool = false
var _lod_accum: float = 0.0
# True once the item has landed and stopped. Gates the floor-probe
# throttle and, past _LOD_DORMANT_RADIUS, the whole tick.
var _at_rest: bool = false
var _rest_probe_accum: float = 0.0


func setup(
	p_item_id: int,
	p_initial_velocity: Vector3 = Vector3.ZERO,
	p_pickup_delay: float = PICKUP_DELAY_SEC
) -> void:
	# Called AFTER add_child + global_position set, so the block id and spawn
	# position are valid before the mesh is built. Pass a non-zero velocity
	# (and a longer pickup delay) for player-thrown drops.
	item_id = p_item_id
	_velocity = p_initial_velocity
	_pickup_delay = p_pickup_delay
	_spawn_time = Time.get_ticks_msec() / 1000.0
	# Counted by PerfWatchdog's slowdown report (hundreds of drops from a
	# TNT'd sand pile are a classic frame-rate sink).
	add_to_group("dropped_items")
	_health = _SOURCE_HEALTH
	_fire_ticks = 0
	_hazard_tick_accum = 0.0
	# Mesh is a child Node3D so we can bob its local Y without fighting the
	# root's gravity-controlled global Y. Registered blocks render as a
	# real cube via BlockMesh; non-block items (coal, ingots, sticks,
	# tools) get the voxel-extruded sprite mesh used by held items, which
	# would otherwise show as a textureless cube. Non-cube blocks (sapling,
	# future torches/plants) take the sprite path too — vanilla draws them
	# as flat 2D billboards on the ground, not as textured cubes with the
	# icon tiled on every face.
	_mesh = MeshInstance3D.new()
	# Sprite path: non-block items and flat-billboard blocks (cross-quads
	# like sapling/fire, and torches).
	_is_sprite_item = (not Blocks.is_registered(p_item_id) or Blocks.has_sprite_tile(p_item_id))
	if _is_sprite_item:
		_build_sprite_mesh(p_item_id)
	else:
		_mesh.mesh = BlockMesh.get_cube_mesh(p_item_id, MESH_SIZE)
	add_child(_mesh)
	_ray_query = PhysicsRayQueryParameters3D.new()


func _process(delta: float) -> void:
	if _picked_up:
		return
	if _player == null:
		_player = _find_player()
	_lod_accum += delta
	if _lod_accum >= _LOD_REFRESH_SEC:
		_lod_accum = 0.0
		_refresh_lod()
	# The despawn clock is a wall-clock comparison and runs at every tier —
	# an item must not outlive its five minutes just because nobody was
	# nearby to tick it.
	var elapsed: float = Time.get_ticks_msec() / 1000.0 - _spawn_time
	if elapsed > LIFETIME_SEC:
		queue_free()
		return
	# Dormant: past the far ring AND already settled. No player within magnet
	# range, no legible spin, no brightness delta worth a material write, and
	# no fall left to finish. Gating only once it is AT REST is deliberate:
	# freezing an item mid-arc would leave it hanging in the air for whoever
	# walks back out to it.
	#
	# The hazard tick stops too, so an item resting in lava sixty-odd metres
	# away waits to burn until someone comes near. Same trade MobBase makes
	# at LOD_FAR, and it resolves itself the moment anyone can see it.
	if _dormant and _at_rest:
		return
	# Alpha 1.2.6 af.java (RenderItem) has two branches:
	#   • Full-cube block (line 38-56): 3D cube, continuous Y-spin
	#     (glRotatef(f5, 0, 1, 0), f5 = age / 20 * 180/π).
	#   • Item / tool / non-cube block (line 57-91): flat 2D sprite,
	#     billboarded to the camera on Y (glRotatef(180 - cam.yaw, 0, 1, 0)),
	#     NO age-based spin — only the sine bob.
	# We preserve the extrusion for visual depth but keep the billboard +
	# no-spin behavior so a diagonal tool sprite stays readable from every
	# angle instead of flashing through a thin edge-on view each rotation.
	# The BILLBOARD is not gated by distance. It is two subtractions and an
	# atan2, and a sprite item that stops facing the camera drifts edge-on
	# as the player walks around it — an extruded sprite seen edge-on is a
	# sliver, which is the opposite of what a report saying "often times I
	# don't see items" needs. The light sample and its material write are
	# the parts actually worth gating, along with the cube spin, which is
	# not legible at range either way.
	if _is_sprite_item:
		_billboard_to_camera()
	elif _near:
		rotate_y(delta * SPIN_SPEED)
	if _near:
		_update_world_brightness()

	# Vanilla Entity.moveEntity fires Block.onEntityCollidedWithBlock for
	# every cell the bounds touch. Wooden plates (`lg.a`) accept every
	# entity, so items / arrows / carts / boats all need this route —
	# without it an unpressed plate has nothing to wake it.
	if _chunk_manager != null and _chunk_manager.has_method("report_entity_contact"):
		_chunk_manager.report_entity_contact(self)
	# EntityItem runs at the source's fixed 20 Hz. Hazard damage precedes
	# pickup/movement, so an item already burning cannot be rescued on the
	# same tick that exhausts its five health points.
	if _tick_environment(delta):
		return

	# Magnet / pickup. Vanilla rule: skip the pull entirely if the player's
	# inventory can't take this item — otherwise the item orbits the
	# player at PICKUP_RADIUS forever (magnet pulls in, pickup fails,
	# repeat) and looks like it's tied to them by an invisible string.
	# `_near` short-circuits this: MAGNET_RADIUS is 1.8 m, so an item past
	# the 24 m near ring cannot possibly be in range and the vector maths
	# is pure waste.
	if _near and _player != null and elapsed >= _pickup_delay and _player_can_accept():
		var target: Vector3 = _player.global_position + Vector3(0, 0.4, 0)
		var to_target: Vector3 = target - global_position
		var dist: float = to_target.length()
		if dist <= PICKUP_RADIUS:
			_try_pickup(_player)
			return
		if dist <= MAGNET_RADIUS:
			var step: Vector3 = to_target.normalized() * MAGNET_SPEED * delta
			if step.length() >= dist:
				global_position = target
			else:
				global_position += step
			_velocity = Vector3.ZERO
			_at_rest = false
			return

	# Alpha 1.2.6 eo.java:47 — pushOutOfBlocks runs BEFORE move every tick,
	# so the impulse is integrated this frame. Cheap: 1 lookup in the common
	# case (center not in a solid); 7 only when stuck.
	_push_out_of_solid_block()

	# Always-on gravity. Each frame, raycast straight down — if there's still
	# terrain under us, snap to it and zero the velocity; otherwise fall.
	# This way breaking the block under a resting item resumes the fall.
	_apply_physics(delta)

	# Visual hover bob — Alpha af.java:36 applies the bob unconditionally
	# every render tick (glTranslatef(d2, d3 + f4, d4)), so it runs while
	# the item is arcing/sliding as well as at rest. Gating on at-rest
	# caused a visible jump the frame the item settled: mesh.y would snap
	# from 0 to the current sin-wave value. Keeping the bob always-on
	# means the sin phase advances continuously through the fall and the
	# transition to rest is smooth (the item's arc naturally dominates
	# the small bob while in motion).
	if _near and _mesh != null:
		_hover_phase += delta * HOVER_FREQUENCY * TAU
		# +amp bias keeps the bob non-negative so the sprite never dips
		# below its resting Y and clips through the floor.
		_mesh.position.y = sin(_hover_phase) * HOVER_AMPLITUDE + HOVER_AMPLITUDE


# Recompute the two distance flags. Squared distance so no sqrt, and
# horizontal-and-vertical because a shaft full of drops under the player
# is exactly the case that hurts. With no player yet (first frames after a
# world load) the item stays fully active rather than silently freezing.
func _refresh_lod() -> void:
	if _player == null:
		_near = true
		_dormant = false
		return
	var distance_sq: float = global_position.distance_squared_to(_player.global_position)
	_near = distance_sq <= _LOD_NEAR_RADIUS_SQ
	_dormant = distance_sq > _LOD_DORMANT_RADIUS_SQ


# Advance Alpha's Entity fire bookkeeping at 20 Hz. Returns true once the
# item has been destroyed so `_process` stops before pickup or physics can
# touch a node already queued for deletion.
func _tick_environment(delta: float) -> bool:
	_resolve_chunk_manager()
	if _chunk_manager == null or not _chunk_manager.has_method("get_world_block"):
		return false
	_hazard_tick_accum += delta
	while _hazard_tick_accum >= _SOURCE_TICK_SEC:
		_hazard_tick_accum -= _SOURCE_TICK_SEC
		if _environment_tick():
			return true
	return false


# One `eo.e_()` source tick. `lw.B()` handles water + an existing Fire
# counter first; movement then calls `cy.c(AABB)`, whose burning set is
# exactly fire plus flowing/still lava. EntityItem's five-point health makes
# sustained contact destructive in a handful of ticks, while a brief touch
# can keep damaging the item after it leaves the block.
func _environment_tick() -> bool:
	_resolve_chunk_manager()
	if _chunk_manager == null or not _chunk_manager.has_method("get_world_block"):
		return false
	var contacts: int = _environment_contacts()
	var in_water: bool = (contacts & _CONTACT_WATER) != 0
	if in_water:
		# `lw.B()` extinguishes before the periodic burn-damage branch.
		_fire_ticks = 0
	elif _fire_ticks > 0:
		if _fire_ticks % _BURN_DAMAGE_INTERVAL_TICKS == 0:
			if _take_environment_damage(_CONTACT_DAMAGE):
				return true
		_fire_ticks -= 1

	var touching_burning_block: bool = (contacts & (_CONTACT_FIRE | _CONTACT_LAVA)) != 0
	if touching_burning_block:
		# `cy.c(AABB)` -> `lw.a(1)` -> EntityItem.a(entity, damage).
		if _take_environment_damage(_CONTACT_DAMAGE):
			return true
		if not in_water:
			_fire_ticks += 1
			if _fire_ticks == 0:
				_fire_ticks = _BURN_DURATION_TICKS
	elif _fire_ticks <= 0:
		# fireResistance is one tick for ordinary entities (`lw.bf = 1`).
		_fire_ticks = -1
	return false


func _take_environment_damage(amount: int) -> bool:
	_health -= amount
	if _health > 0:
		return false
	queue_free()
	return true


# Sample every block cell touched by the item's 0.25 m AABB. Center-cell
# sampling misses the common edge case where a scattered death drop straddles
# a fire/lava boundary, while this mirrors `cy.c(AABB)` without a physics
# query or per-frame allocation.
func _environment_contacts() -> int:
	var half: float = MESH_SIZE * 0.5
	var min_pos: Vector3 = global_position - Vector3.ONE * half
	var max_pos: Vector3 = global_position + Vector3.ONE * half - Vector3.ONE * _AABB_EPSILON
	var min_cell := Vector3i(floori(min_pos.x), floori(min_pos.y), floori(min_pos.z))
	var max_cell := Vector3i(floori(max_pos.x), floori(max_pos.y), floori(max_pos.z))
	var contacts: int = 0
	for x: int in range(min_cell.x, max_cell.x + 1):
		for y: int in range(min_cell.y, max_cell.y + 1):
			for z: int in range(min_cell.z, max_cell.z + 1):
				var id: int = _chunk_manager.get_world_block(Vector3i(x, y, z))
				if id == Blocks.FIRE:
					contacts |= _CONTACT_FIRE
				elif Blocks.is_lava(id):
					contacts |= _CONTACT_LAVA
				elif Blocks.is_water(id):
					contacts |= _CONTACT_WATER
	return contacts


func _resolve_chunk_manager() -> void:
	if _chunk_manager != null and is_instance_valid(_chunk_manager):
		return
	var parent: Node = get_parent()
	if parent != null and parent.has_method("get_world_block"):
		_chunk_manager = parent
		return
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")


func _apply_physics(delta: float) -> void:
	# Gravity on Y, exponential drag on horizontal so thrown items glide
	# briefly before settling.
	# Rest throttle — see _REST_PROBE_SEC. A settled item spends one ray
	# query per frame proving it is still settled; the only thing that
	# probe can ever discover is the floor being mined out from under it.
	if _at_rest:
		_rest_probe_accum += delta
		if _rest_probe_accum < _REST_PROBE_SEC:
			return
		_rest_probe_accum = 0.0
	_velocity.y = maxf(_velocity.y + GRAVITY * delta, TERMINAL_VELOCITY)
	var drag_factor: float = clampf(1.0 - HORIZONTAL_DRAG * delta, 0.0, 1.0)
	_velocity.x *= drag_factor
	_velocity.z *= drag_factor
	# lw.java:267-290 — every axis of the move is clipped against the block
	# boxes in its path, and a blocked axis loses its velocity (lw.java:
	# 350-358). Items used to have no horizontal collision at all: sliding
	# into a wall left only the push-out rescue, which shoves along whichever
	# face is nearest — through the far side when that one was — and never
	# fires for non-opaque solids (glass, ice, leaves, chests), so an item
	# could slide clean through those (issue #10). X and Z are clipped at the
	# current height, before this frame's fall, so the floor an item is
	# sliding across never counts as a wall; the fall itself is the floor
	# probe below.
	var new_pos: Vector3 = global_position
	new_pos.x += _clip_move(new_pos, 0, _velocity.x * delta)
	new_pos.z += _clip_move(new_pos, 2, _velocity.z * delta)
	if _velocity.y > 0.0:
		new_pos.y += _clip_move(new_pos, 1, _velocity.y * delta)
	else:
		new_pos.y += _velocity.y * delta
	var landed: bool = false
	if _velocity.y <= 0.0:
		var half: float = MESH_SIZE * 0.5
		# Cooked collision wins wherever it exists: the chunk trimesh follows
		# the RENDER mesh, so it catches the tread of a stair and the open
		# half of a doorway, which a per-cell AABB cannot. It only exists
		# within ChunkManager.collision_radius of the player, which is why
		# the voxel scan BACKS IT UP rather than replacing it — past that
		# ring the ray hit nothing, the item sank into the ground and
		# _push_out_of_solid_block shoved it back, forever (issue #8).
		var floor_top: float = _collider_floor_top(new_pos, half)
		if floor_top == -INF:
			floor_top = _voxel_floor_top(new_pos, global_position.y - half, new_pos.y - half)
		if floor_top > -INF:
			new_pos.y = floor_top + half
			_velocity.y = 0.0
			landed = true
	# Settled means on a floor with the horizontal throw damped out. Losing
	# the floor clears it immediately, so a mined-out support resumes the
	# fall at full per-frame rate on the very next tick.
	_at_rest = (
		landed
		and absf(_velocity.x) < _REST_SPEED_EPSILON
		and absf(_velocity.z) < _REST_SPEED_EPSILON
	)
	global_position = new_pos


# Move by `offset` with block collision. For spawners that launch an item
# from ahead of a point known to be clear, such as the thrower's eye, so it
# cannot start out inside a wall the thrower is standing against.
func move_clipped(offset: Vector3) -> void:
	_resolve_chunk_manager()
	var pos: Vector3 = global_position
	pos.x += _clip_move(pos, 0, offset.x)
	pos.z += _clip_move(pos, 2, offset.z)
	pos.y += _clip_move(pos, 1, offset.y)
	global_position = pos


# How far the item's box can move `motion` along `axis` (0 = X, 1 = Y,
# 2 = Z) from `pos` before a block's collision box stops it — vanilla's
# per-axis AABB offset (co.java a / b / c), against every block box the
# sweep crosses, so no step size can skip a block. Zeroes the velocity on
# that axis when the move is cut short. Only boxes wholly ahead of the
# leading face count: an item already embedded (a block placed on it)
# can still leave, and _push_out_of_solid_block frees it.
func _clip_move(pos: Vector3, axis: int, motion: float) -> float:
	if motion == 0.0:
		return 0.0
	if _chunk_manager == null or not _chunk_manager.has_method("get_world_block"):
		return motion
	var half: float = MESH_SIZE * 0.5
	var item_min: Vector3 = pos - Vector3.ONE * half
	var item_max: Vector3 = pos + Vector3.ONE * half
	var lo: Vector3 = item_min + Vector3.ONE * _COLLIDE_SKIN
	var hi: Vector3 = item_max - Vector3.ONE * _COLLIDE_SKIN
	lo[axis] = minf(item_min[axis], item_min[axis] + motion)
	hi[axis] = maxf(item_max[axis], item_max[axis] + motion)
	var has_meta: bool = _chunk_manager.has_method("get_world_block_meta")
	var allowed: float = motion
	for x: int in range(floori(lo.x), floori(hi.x) + 1):
		for y: int in range(floori(lo.y), floori(hi.y) + 1):
			for z: int in range(floori(lo.z), floori(hi.z) + 1):
				var cell := Vector3i(x, y, z)
				var id: int = _chunk_manager.get_world_block(cell)
				if not Blocks.is_solid_collision(id):
					continue
				var meta: int = _chunk_manager.get_world_block_meta(cell) if has_meta else 0
				var box: AABB = Blocks.collision_aabb(id, meta)
				if not box.has_volume():
					continue
				var box_min: Vector3 = Vector3(cell) + box.position
				var box_max: Vector3 = box_min + box.size
				if not _overlaps_across(item_min, item_max, box_min, box_max, axis):
					continue
				if allowed > 0.0 and box_min[axis] >= item_max[axis] - _COLLIDE_SKIN:
					var room: float = box_min[axis] - item_max[axis] - _CONTACT_GAP
					allowed = minf(allowed, maxf(0.0, room))
				elif allowed < 0.0 and box_max[axis] <= item_min[axis] + _COLLIDE_SKIN:
					var room_back: float = box_max[axis] - item_min[axis] + _CONTACT_GAP
					allowed = maxf(allowed, minf(0.0, room_back))
	if allowed != motion:
		_velocity[axis] = 0.0
	return allowed


# True when the two boxes overlap on both axes other than `axis`, by more
# than the collision skin.
static func _overlaps_across(
	a_min: Vector3, a_max: Vector3, b_min: Vector3, b_max: Vector3, axis: int
) -> bool:
	for other: int in range(3):
		if other == axis:
			continue
		if b_max[other] <= a_min[other] + _COLLIDE_SKIN:
			return false
		if b_min[other] >= a_max[other] - _COLLIDE_SKIN:
			return false
	return true


# Surface the chunk's cooked collision reports directly under the item, or
# -INF when there is no collider in the way (either open air, or terrain
# whose chunk is outside the live-physics ring).
func _collider_floor_top(new_pos: Vector3, half: float) -> float:
	if _ray_query == null or not is_inside_tree():
		return -INF
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return -INF
	_ray_query.from = global_position
	_ray_query.to = Vector3(new_pos.x, new_pos.y - half, new_pos.z)
	var result: Dictionary = space.intersect_ray(_ray_query)
	if result.is_empty():
		return -INF
	return float(result.position.y)


# Highest block surface the item's underside would cross this step, or
# -INF for a clear fall. Read from VOXEL data rather than a physics ray:
# chunk trimesh colliders only exist inside ChunkManager.collision_radius
# (one chunk) of the player, so the old downward raycast found nothing for
# any drop past that ring. The item sank into the terrain,
# _push_out_of_solid_block shoved it back out, and the two fought every
# frame — the endless bounce on distant items in issue #8. Voxel reads
# answer the same question at any distance, and Blocks.collision_aabb
# keeps slabs and soul sand resting at their true height.
func _voxel_floor_top(pos: Vector3, from_bottom: float, to_bottom: float) -> float:
	if _chunk_manager == null or not _chunk_manager.has_method("get_world_block"):
		return -INF
	var x: int = floori(pos.x)
	var z: int = floori(pos.z)
	# Scan the cells the underside sweeps through, top-down, so the first
	# surface found is the one it lands on. A resting item sits with
	# `from_bottom` exactly on a cell boundary, so floori() puts the scan's
	# first cell at the AIR above its floor and the next one down is the
	# floor itself — which is how it keeps re-finding the surface it is
	# already on instead of drifting off it.
	var y_top: int = floori(from_bottom)
	var y_bottom: int = floori(to_bottom)
	for y in range(y_top, y_bottom - 1, -1):
		var id: int = _chunk_manager.get_world_block(Vector3i(x, y, z))
		if not Blocks.is_solid_collision(id):
			continue
		var meta: int = 0
		if _chunk_manager.has_method("get_world_block_meta"):
			meta = _chunk_manager.get_world_block_meta(Vector3i(x, y, z))
		var box: AABB = Blocks.collision_aabb(id, meta)
		if box.size.y <= 0.0:
			continue
		# The box's XZ footprint counts as much as its height. A door is a
		# 3/16 slab, a fence a 4/16 post, an open gate thinner still — take
		# any of them as a full-cell floor and an item dropped in a doorway
		# settles a whole block up, hanging in the open half. Test the same
		# column the raycast walks: the item's centre.
		var fx: float = pos.x - float(x)
		var fz: float = pos.z - float(z)
		if fx < box.position.x or fx > box.position.x + box.size.x:
			continue
		if fz < box.position.z or fz > box.position.z + box.size.z:
			continue
		var top: float = float(y) + box.position.y + box.size.y
		if top <= from_bottom + _AABB_EPSILON and top >= to_bottom:
			return top
	return -INF


# Build a voxel-extruded sprite mesh from the item's icon texture and
# scale to MESH_SIZE world units (sprite is 16 native px wide → uniform
# scale = MESH_SIZE / 16). Uses the same depth-tested item shader the
# third-person held tool uses.
func _build_sprite_mesh(id: int) -> void:
	var tex: Texture2D = ItemIcons.icon_for(id)
	if tex == null:
		return
	var mesh: ArrayMesh = SpriteExtruder.build(tex)
	if mesh == null:
		return
	_mesh.mesh = mesh
	var ps: float = MESH_SIZE / 16.0
	_mesh.scale = Vector3(ps, ps, ps)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/held_item_world.gdshader") as Shader
	mat.set_shader_parameter("item_texture", tex)
	_mesh.material_override = mat


# Vanilla af.java RenderItem tints dropped items by world brightness via
# the same lightmap path mobs/boats use. We mirror that with the shared
# EntityLighting helper (Alpha 0.05 floor — see EntityLighting._FLOOR).
# Sprite items push into their per-instance `world_brightness` uniform on
# the held-item shader (each gets its own material). Cube-block drops
# share BlockAtlas.entity_material (chunk.gdshader), so we use
# `set_instance_shader_parameter("entity_brightness", lit)` on the mesh
# instance — Godot bakes that into the per-instance data without cloning
# the material, keeping the single-material invariant.
func _update_world_brightness() -> void:
	if _mesh == null:
		return
	# Resolve via get_parent() optimistically — in gameplay we're added
	# as a ChunkManager child. In tests our parent is a plain Node, so
	# check that it actually has the chunk API before caching it (or
	# we'd poison `_chunk_manager` and break `_push_out_of_solid_block`
	# next tick too). Visual tint is non-critical — bail silently.
	if _chunk_manager == null:
		var parent: Node = get_parent()
		if parent != null and parent.has_method("get_world_effective_light"):
			_chunk_manager = parent
	if _chunk_manager == null:
		return
	var cell := Vector3i(
		int(floor(global_position.x)), int(floor(global_position.y)), int(floor(global_position.z))
	)
	var lit: float = EntityLighting.sample_brightness(_chunk_manager, cell)
	if absf(lit - _last_brightness) < 0.01:
		return
	_last_brightness = lit
	if _is_sprite_item:
		var mat: ShaderMaterial = _mesh.material_override as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("world_brightness", lit)
	else:
		# Cube branch — mesh uses the shared chunk material; push per-
		# instance so we don't clone the material per dropped item.
		_mesh.set_instance_shader_parameter("entity_brightness", lit)


func _try_pickup(player: Node3D) -> void:
	if not "inventory" in player:
		return
	var inv: Inventory = player.get("inventory") as Inventory
	if inv == null:
		return
	var overflow: int = inv.add_item(item_id, 1)
	if overflow > 0:
		return  # inventory full — leave the item
	_picked_up = true
	SFX.play_pickup()
	queue_free()


func _find_player() -> Node3D:
	return get_tree().root.get_node_or_null("Main/Player") as Node3D


# Alpha af.java:81 — glRotatef(180 - cam.yaw, 0, 1, 0). Rotates on Y only so
# the sprite stays upright; pitch/roll never factor in. SpriteExtruder emits
# the sprite facing +Z, so aiming +Z at the camera (yaw = atan2(dx, dz))
# leaves the sprite flat-on to the viewer at any camera position.
func _billboard_to_camera() -> void:
	if _camera == null:
		_camera = get_viewport().get_camera_3d()
		if _camera == null:
			return
	var cam_pos: Vector3 = _camera.global_position
	var dx: float = cam_pos.x - global_position.x
	var dz: float = cam_pos.z - global_position.z
	# Null vector (player stands on the item) — keep last rotation.
	if absf(dx) < 1e-5 and absf(dz) < 1e-5:
		return
	rotation = Vector3(0.0, atan2(dx, dz), 0.0)


# Alpha 1.2.6 eo.java:75-135 (EntityItem.pushOutOfBlocks). Runs every tick
# before move. When the item's center sits inside a solid full cube —
# usually because the player placed a block where it was resting — pick
# the nearest open neighbor face and impulse along that axis so the item
# pops out. Guard on a solid-cube test first so the neighbor scan only
# runs when actually stuck; this is the hot path for resting items.
func _push_out_of_solid_block() -> void:
	if _chunk_manager == null:
		_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager") as Node
		if _chunk_manager == null:
			return
	var pos: Vector3 = global_position
	var bx: int = floori(pos.x)
	var by: int = floori(pos.y)
	var bz: int = floori(pos.z)
	# Alpha gates on nq.o[id] (isOpaqueCube). Our Blocks.is_opaque matches:
	# true for full solids, false for air, fluids, leaves, glass, fire.
	var here_id: int = _chunk_manager.get_world_block(Vector3i(bx, by, bz))
	if not Blocks.is_opaque(here_id):
		return
	var frac_x: float = pos.x - float(bx)
	var frac_y: float = pos.y - float(by)
	var frac_z: float = pos.z - float(bz)
	var open_nx: bool = not Blocks.is_opaque(
		_chunk_manager.get_world_block(Vector3i(bx - 1, by, bz))
	)
	var open_px: bool = not Blocks.is_opaque(
		_chunk_manager.get_world_block(Vector3i(bx + 1, by, bz))
	)
	var open_ny: bool = not Blocks.is_opaque(
		_chunk_manager.get_world_block(Vector3i(bx, by - 1, bz))
	)
	var open_py: bool = not Blocks.is_opaque(
		_chunk_manager.get_world_block(Vector3i(bx, by + 1, bz))
	)
	var open_nz: bool = not Blocks.is_opaque(
		_chunk_manager.get_world_block(Vector3i(bx, by, bz - 1))
	)
	var open_pz: bool = not Blocks.is_opaque(
		_chunk_manager.get_world_block(Vector3i(bx, by, bz + 1))
	)
	var axis: int = -1
	var best: float = 9999.0
	if open_nx and frac_x < best:
		best = frac_x
		axis = 0
	if open_px and 1.0 - frac_x < best:
		best = 1.0 - frac_x
		axis = 1
	if open_ny and frac_y < best:
		best = frac_y
		axis = 2
	if open_py and 1.0 - frac_y < best:
		best = 1.0 - frac_y
		axis = 3
	if open_nz and frac_z < best:
		best = frac_z
		axis = 4
	if open_pz and 1.0 - frac_z < best:
		best = 1.0 - frac_z
		axis = 5
	if axis < 0:
		return
	# Vanilla: rand.nextFloat() * 0.2 + 0.1 = 0.1..0.3 blocks/tick. At
	# 20 tps that's 2..6 m/s along the chosen axis. Set velocity directly —
	# _apply_physics' horizontal drag and 0.98/tick-equivalent Y damping
	# then decay it at roughly vanilla's rate.
	var speed: float = randf_range(2.0, 6.0)
	# Being shoved out of a block is motion, so the rest throttle has to
	# let go or the impulse would sit unintegrated for a fifth of a second.
	_at_rest = false
	match axis:
		0:
			_velocity.x = -speed
		1:
			_velocity.x = speed
		2:
			_velocity.y = -speed
		3:
			_velocity.y = speed
		4:
			_velocity.z = -speed
		5:
			_velocity.z = speed


# Returns true if the player's inventory has room for at least 1 of our
# item. False → the magnet (and the pickup attempt) skip this frame so
# the item just sits on the ground until something opens up.
func _player_can_accept() -> bool:
	if _player == null or not "inventory" in _player:
		return false
	# Vanilla Alpha eo.b(eb): pickup test runs in the entity's onCollideWith,
	# but the dead EntityPlayer's hitbox is removed via setEntityDead before
	# the next tick — so a dead player physically can't trigger the collision
	# and re-absorb their own loot. We don't remove the body on death (the
	# death screen freezes input while the body stays put), so gate explicitly
	# on health: a corpse can't pick up items.
	if "health" in _player and int(_player.get("health")) <= 0:
		return false
	var inv: Inventory = _player.get("inventory") as Inventory
	if inv == null:
		return false
	return inv.can_accept(item_id, 1)


# --- Persistence (step 7.3) ---


# Pack the entity's state into a Dictionary that EntitySave can serialize
# via var_to_bytes. `age_seconds` is the elapsed time since spawn — saving
# this (instead of the raw `_spawn_time` wall clock) means the despawn
# timer keeps counting from where it left off across save/load cycles
# instead of resetting to 0 on every reload.
func to_save_dict() -> Dictionary:
	var now: float = Time.get_ticks_msec() / 1000.0
	var age: float = maxf(0.0, now - _spawn_time)
	return {
		"pos": global_position,
		"vel": _velocity,
		"item_id": item_id,
		"age_seconds": age,
		"pickup_delay": _pickup_delay,
		# EntityItem writes Health while Entity writes Fire in Alpha. Keeping
		# both prevents a dimension round-trip from healing a singed drop or
		# extinguishing its trailing burn.
		"health": _health,
		"fire_ticks": _fire_ticks,
	}


# Inverse of to_save_dict. Caller must add_child + set global_position
# BEFORE calling restore_from_dict (matches the existing spawn pattern:
# new() → add_child → setup()). Internally calls setup() to handle mesh
# build + field init, then rewinds _spawn_time so the saved despawn
# countdown picks up where it left off instead of restarting from 0.
func restore_from_dict(dict: Dictionary) -> void:
	var item: int = int(dict.get("item_id", 0))
	var vel: Vector3 = dict.get("vel", Vector3.ZERO) as Vector3
	var delay: float = float(dict.get("pickup_delay", PICKUP_DELAY_SEC))
	setup(item, vel, delay)
	var age: float = float(dict.get("age_seconds", 0.0))
	_spawn_time = Time.get_ticks_msec() / 1000.0 - age
	_health = int(dict.get("health", _SOURCE_HEALTH))
	_fire_ticks = int(dict.get("fire_ticks", 0))
