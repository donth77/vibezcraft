class_name Boat
extends CharacterBody3D

# Vanilla MC Alpha 1.2.6 EntityBoat (vendor/alpha-1.2.6-src/src/dp.java).
# Floats on water, the player right-clicks an empty boat to mount,
# sneak/jump to dismount, WASD to paddle.
#
# Vanilla refs:
#   dp.java::e_()  — per-tick physics (buoyancy, thrust, drag, auto-yaw)
#   dp.java::j_()  — passenger seat positioning
#   nv.java        — ItemBoat (id 333), right-click water → spawn
#   da.java        — RenderBoat (visual model)
#
# Stage 2 scope: paddle physics + water-surface buoyancy + auto-yaw.
# Earlier stage 1 added mount/dismount + placement. Still NOT in this
# stage: collision damage + drops (stage 3), persistence (stage 4),
# vanilla-faithful hull mesh (currently a brown box).

# Vanilla model dimensions (RenderBoat.java + dp.java::a(1.5f, 0.6f)):
#   hull length  = 1.5 m  (X axis)
#   hull width   = 0.75 m (Z axis) — vanilla uses 0.6 but visual is 0.75
#   hull height  = 0.5625 m (Y axis, base of hull to top of gunwale)
const HULL_LENGTH: float = 1.5
const HULL_WIDTH: float = 0.75
const HULL_HEIGHT: float = 0.5625

# Vanilla constants from dp.java::e_(), converted from per-tick to
# per-second by ×20 (TPS). Vanilla source comments inline for each.

# `this.aA += 0.04f * d15` where d15 = 2*water_pct - 1, ranges -1..+1.
# In water (d15=+1): +0.04 m/tick² Y accel ≈ +16 m/s² (positive buoyancy).
# In air (d15=-1):   -0.04 m/tick² ≈ -16 m/s² (gravity-like, but weaker
# than vanilla terrain gravity 0.08/tick = -32 m/s²).
const BUOY_ACCEL: float = 16.0  # m/s² magnitude

# `if (this.az < -d4 = 0.4)` — vanilla caps horizontal velocity at
# 0.4 m/tick = 8 m/s. We enforce on X and Z independently same way
# vanilla does (axis-aligned, not euclidean magnitude).
const MAX_HORIZ_PER_AXIS: float = 8.0  # m/s

# `this.az *= 0.99` and `this.aA *= 0.95` per tick when above-water /
# no rider. Per-second: 0.99^20 ≈ 0.82, 0.95^20 ≈ 0.36.
const DRAG_HORIZ_PER_TICK: float = 0.99
const DRAG_VERT_PER_TICK: float = 0.95

# `if (this.aH) this.az *= 0.5` — horizontal speed halves on floor /
# ceiling bump (vanilla's "scrape against bank" feel).
const BUMP_DAMP: float = 0.5

# Yaw smoothing — `if (d2 > 20.0) d2 = 20.0;` clamps the per-tick yaw
# delta to ±20° (vanilla follows motion direction with bounded turn).
# Per-second: 400°/s = ~7 rad/s.
const MAX_YAW_RATE: float = TAU * (20.0 / 360.0) * 20.0  # = ~6.98 rad/s
# Motion threshold below which auto-yaw doesn't fire (avoids jittering
# at near-zero velocity): `d3*d3 + d23*d23 > 0.001` in dp.java.
const MIN_MOTION_SQ_FOR_YAW: float = 0.001

# Rider thrust scale — `this.az += this.aq.az * 0.2`. Boat picks up
# 20% of the rider's per-tick velocity each tick. For our per-second
# system: rider's per-second velocity × 0.2 × 20 = ×4. We read rider
# input as a unit-length direction and multiply by RIDER_THRUST below.
# Rider velocity ~4.3 m/s walking → thrust ~17 m/s² accel. Cap at
# MAX_HORIZ_PER_AXIS keeps the boat from exceeding 8 m/s.
const RIDER_THRUST: float = 18.0  # m/s² accel for full forward input

# Vanilla `BoatHealth` — 4 HP max. Damage on collision lands in stage 3.
const MAX_HEALTH: int = 4

# Seat offset (relative to boat origin). Vanilla j_() places the rider
# at `(aw + cos(yaw)*0.4, ax + j() + rider.y(), ay + sin(yaw)*0.4)`,
# where j() returns `-0.3`. So vanilla seat is forward 0.4 m along the
# boat's facing and 0.3 m below the boat's reference Y, plus the
# rider's own y-offset. For our simpler model the rider sits at the
# boat's local center, slightly above the hull mid-Y. Tunable.
const _SEAT_OFFSET: Vector3 = Vector3(0, 0.35, 0)

var health: int = MAX_HEALTH
# Set by interaction.gd at spawn time so the boat knows which player
# initiated the placement (used for the first mount + drop targeting).
var _owner_player: Node3D = null
# Set when the player mounts. null == empty boat.
var _rider: Node3D = null
# Cached reference to ChunkManager so _physics_process can sample
# water cells without walking the scene tree each tick. Resolved in
# _ready via get_tree().root.
var _chunk_manager: Node = null


func setup(spawn_pos: Vector3, yaw: float, owner: Node3D) -> void:
	global_position = spawn_pos
	rotation.y = yaw
	_owner_player = owner


func _ready() -> void:
	# CharacterBody3D defaults — the boat doesn't interact with the
	# player's collision body (player walks through boats) but DOES
	# block their raycast so right-clicks land on the hull.
	collision_layer = 0b10  # layer 2 (selection-only, like sapling cross-quads)
	collision_mask = 0
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	_build_collider()
	_build_visual_mesh()


func _build_collider() -> void:
	# Thin AABB roughly covering the hull, on the selection-only layer
	# so the player raycast (mask 0b11) hits the boat for mount but the
	# player body (mask 0b01) walks through it.
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(HULL_LENGTH, HULL_HEIGHT, HULL_WIDTH)
	shape.shape = box
	shape.position = Vector3(0, HULL_HEIGHT * 0.5, 0)
	add_child(shape)


func _build_visual_mesh() -> void:
	# Placeholder mesh — single dark-plank box of hull dimensions.
	# Stage 5+ will replace this with a vanilla-faithful built-from-quads
	# hull mesh (matches da.java's per-plank planar geometry).
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(HULL_LENGTH, HULL_HEIGHT, HULL_WIDTH)
	mi.mesh = box
	mi.position = Vector3(0, HULL_HEIGHT * 0.5, 0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.55, 0.37, 0.20)
	mi.material_override = mat
	add_child(mi)


# Called by interaction.gd::_try_right_click_boat when the player
# right-clicks the boat. Mounts the player (empty boat) or no-op
# (boat already has rider). Returns true if the click was consumed.
func right_click_with(_held_id: int, player: Node3D) -> bool:
	if _rider != null:
		return false  # already occupied
	mount(player)
	return true


# Mount the player onto the boat. Player's physics short-circuits via
# the existing Player.set_mount hook (pig uses the same path).
func mount(player: Node3D) -> void:
	if _rider != null:
		return
	_rider = player
	if player.has_method("set_mount"):
		player.set_mount(self)


# Drop the rider off. Called by Player when it sees sneak/jump while
# mounted (Player._physics_process drives this via the existing
# `_mounted_to.dismount()` call on sneak).
func dismount() -> void:
	if _rider == null:
		return
	var p: Node3D = _rider
	_rider = null
	if p != null and p.has_method("set_mount"):
		p.set_mount(null)


# Per-tick physics — buoyancy + drag + rider thrust + auto-yaw + bump.
# Mirrors vanilla dp.java::e_() but on a per-second clock instead of
# vanilla's 20 Hz fixed tick.
func _physics_process(delta: float) -> void:
	var on_water: bool = _sample_water_at_origin()
	# Buoyancy / gravity — vanilla `aA += 0.04 * (2*water_pct - 1)` per
	# tick. We use a single-cell water check instead of vanilla's
	# 5-slice probe so water_pct is binary (0 or 1) — close enough at
	# our resolution.
	var buoy_sign: float = 1.0 if on_water else -1.0
	velocity.y += buoy_sign * BUOY_ACCEL * delta
	# Rider thrust — vanilla reads `aq.az` (passenger velocity) at 0.2
	# scale. We read input directly: WASD in WORLD-space relative to
	# the player's look direction (so paddling forward = where the
	# player is looking), only when input isn't captured by a UI.
	if _rider != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var thrust_dir: Vector3 = _read_rider_input()
		if thrust_dir.length_squared() > 0.001:
			velocity.x += thrust_dir.x * RIDER_THRUST * delta
			velocity.z += thrust_dir.z * RIDER_THRUST * delta
	# Speed cap — vanilla caps each horizontal axis at 0.4/tick = 8 m/s.
	velocity.x = clampf(velocity.x, -MAX_HORIZ_PER_AXIS, MAX_HORIZ_PER_AXIS)
	velocity.z = clampf(velocity.z, -MAX_HORIZ_PER_AXIS, MAX_HORIZ_PER_AXIS)
	# Drag — pow() lets us match vanilla's per-tick decay regardless of
	# our frame delta. tick_scale = delta * 20 (ticks elapsed this frame).
	var tick_scale: float = delta * 20.0
	velocity.x *= pow(DRAG_HORIZ_PER_TICK, tick_scale)
	velocity.z *= pow(DRAG_HORIZ_PER_TICK, tick_scale)
	velocity.y *= pow(DRAG_VERT_PER_TICK, tick_scale)
	# Auto-yaw — vanilla turns toward motion direction with ±20°/tick
	# bound. Skipped at near-zero motion to avoid jitter.
	_apply_auto_yaw(delta)
	# Move + bump damp. CharacterBody3D's move_and_slide returns
	# collision info via get_slide_collision_count().
	var was_grounded: bool = is_on_floor()
	move_and_slide()
	if not was_grounded and is_on_floor():
		# Hit bottom — halve all components (vanilla `aH` branch).
		velocity *= BUMP_DAMP
	# Drive rider to seat position. Rider's own physics short-circuits
	# while _mounted_to != null (Player._physics_process check).
	if _rider != null:
		_rider.global_position = global_position + _SEAT_OFFSET


# Read the rider's WASD into a world-space horizontal unit vector.
# Forward = rider's look direction (XZ-projected). Strafe = rider's
# right vector. Returns a unit-length Vector3 with y=0 (or ZERO if no
# input).
func _read_rider_input() -> Vector3:
	var input := Vector3.ZERO
	if _rider == null:
		return input
	# Rider's body yaw (player.rotation.y) — XZ forward + right vectors.
	var yaw: float = _rider.rotation.y
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var rt := Vector3(cos(yaw), 0, -sin(yaw))
	if Input.is_action_pressed("move_forward"):
		input += fwd
	if Input.is_action_pressed("move_back"):
		input -= fwd
	if Input.is_action_pressed("move_left"):
		input -= rt
	if Input.is_action_pressed("move_right"):
		input += rt
	if input.length_squared() > 0.001:
		input = input.normalized()
	return input


# Turn the boat toward its horizontal motion direction with the same
# clamped per-tick step vanilla uses (dp.java lines 222-240).
func _apply_auto_yaw(delta: float) -> void:
	var horiz_sq: float = velocity.x * velocity.x + velocity.z * velocity.z
	if horiz_sq < MIN_MOTION_SQ_FOR_YAW:
		return
	# Target yaw = atan2 of motion direction. Vanilla uses atan2(dz, dx)
	# which gives 0 along +X and increases CCW. Godot rotation.y has
	# the opposite handedness so we negate; (-sin(yaw), 0, -cos(yaw))
	# is our world-space forward.
	var target_yaw: float = atan2(-velocity.x, -velocity.z)
	var diff: float = target_yaw - rotation.y
	# Shortest-path delta in [-π, π].
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	# Clamp per-frame turn to MAX_YAW_RATE × delta.
	var max_step: float = MAX_YAW_RATE * delta
	diff = clampf(diff, -max_step, max_step)
	rotation.y += diff


# Sample the block at the boat's origin to decide if we're on water.
# Vanilla checks 5 vertical slices for a water-percentage; we use one
# cell — close enough at our scale and avoids the extra get_block
# round-trips per tick.
func _sample_water_at_origin() -> bool:
	if _chunk_manager == null:
		return false
	var cell := Vector3i(
		int(floor(global_position.x)), int(floor(global_position.y)), int(floor(global_position.z))
	)
	var id: int = _chunk_manager.get_world_block(cell)
	return id == Blocks.WATER_STILL or id == Blocks.WATER_FLOWING
