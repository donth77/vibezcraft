class_name Cow
extends "res://scripts/entities/mob_base.gd"

# Vanilla Alpha 1.2.6 EntityCow (as.java, entity id 92, name "Cow").
# Model `el.java` extends `ij.java` (same base as pig's `cj.java`) but
# OVERRIDES head + body with bigger dimensions, ADDS two horns + one
# udder, and bumps leg height to 12 px (vs pig's 6 px). Renders via
# `nu.java` — passive ground animal, no targeting, no attack path.
#
# Drops: LEATHER only (vanilla `as.g_() = dx.aD.aW` = LEATHER). Beef
# wasn't added until later MC versions. 0-2 quantity per kill matches
# the pig's 0-2 pork roll.
#
# Interaction: right-click with empty bucket → milk bucket (vanilla
# `as.a(eb player)` lines 42-48 — swaps the held bucket stack for a
# milk bucket via `eb.e.a(eb.e.d, new fp(dx.aE))`).
#
# AI is duplicated from pig.gd — wander + flee on hit + A* pathfinding +
# vanilla ij-faithful walk animation. Future refactor will extract the
# shared passive-animal AI into a base class once chicken + sheep land
# and the duplication cost outweighs the coupling cost. For now,
# copy-paste keeps each mob standalone and easy to audit against its
# vanilla source.

const _COW_TEXTURE_PATH: String = "res://assets/textures/mob/cow.png"
const _COW_TEXTURE_SIZE: Vector2i = Vector2i(64, 32)

# Vanilla model dims per `el.java`:
#   head  d: cube 8×8×6  @ tex (0,  0)  — pivot (0, 4, -8)
#   body  e: cube 12×18×10 @ tex (18, 4) — pivot (0, 5, 2), rotated PI/2 X
#   horns b/c: cube 1×3×1 @ tex (22, 0) — pair on top of head
#   udder a: cube 4×6×2 @ tex (52, 0) — pivot (0, 14, 6), rotated PI/2 X
#   legs  f/g/h/i (inherited from ij with n=12): cube 4×12×4 @ tex (0, 16)
# Body is 50% wider AND 13% longer than pig, with TALLER (12-px vs 6-px)
# legs — cow is a much bigger silhouette overall.
const _PIXEL_TO_METER: float = 1.0 / 16.0
const _HEAD_CUBE_PX: Vector3i = Vector3i(8, 8, 6)
const _BODY_CUBE_PX: Vector3i = Vector3i(12, 18, 10)
const _LEG_CUBE_PX: Vector3i = Vector3i(4, 12, 4)
const _HORN_CUBE_PX: Vector3i = Vector3i(1, 3, 1)
const _UDDER_CUBE_PX: Vector3i = Vector3i(4, 6, 2)
const _HEAD_TEX_ORIGIN: Vector2i = Vector2i(0, 0)
const _BODY_TEX_ORIGIN: Vector2i = Vector2i(18, 4)
const _LEG_TEX_ORIGIN: Vector2i = Vector2i(0, 16)
const _HORN_TEX_ORIGIN: Vector2i = Vector2i(22, 0)
const _UDDER_TEX_ORIGIN: Vector2i = Vector2i(52, 0)

# Post-rotation world-space extents (collision AABB + leg placement).
# Body cube 12×18×10 after -PI/2 X rotation becomes 0.75 × 0.625 × 1.125
# m. Legs are 4×12×4 → 0.25 × 0.75 × 0.25.
const _BODY_SIZE := Vector3(0.75, 0.625, 1.125)
const _LEG_SIZE := Vector3(0.25, 0.75, 0.25)
# Body center per `el.java`. Body pivot (0, 5, 2), cube_local
# (-6,-10,-7)..(6,8,3). After +PI/2 X rotation around pivot, cube
# extends MODEL X (-6,6), Y (2,12), Z (-8,10). World (T=1.5):
# X (-0.375, 0.375), Y (0.75, 1.375), Z (-0.5, 0.625). Cube CENTER
# world: (0, 1.0625, 0.0625) — body sits 1 px forward of origin.
const _BODY_Y_OFFSET: float = 1.0625
const _BODY_Z_OFFSET: float = 0.0625
# Head center per `el.java`. Pivot (0, 4, -8), cube_local (-4,-4,-6)
# ..(4,4,0). Cube MODEL: X (-4,4), Y (0,8), Z (-14,-8). Cube MODEL
# center: (0, 4, -11). World: (0, T-4/16, -11/16) = (0, 1.25, -0.6875).
# Head sits ABOVE body top (1.375) by 0.125 m and is forward of body's
# front (-0.5) by 0.1875 m, with cube extending into body's front for
# visual continuity. Earlier (0, 1.0, -0.9375) had the cube
# arithmetic-off-by-4-px in both Y and Z — head appeared low + forward
# of the body, "floating" with a gap.
const _HEAD_OFFSET: Vector3 = Vector3(0.0, 1.25, -0.6875)
# Leg pivot Y at the leg's CENTER. With leg height 0.75 m, center =
# 0.375 puts the leg cube at Y range 0 (feet) .. 0.75 (top).
const _LEG_Y_OFFSET: float = 0.375
# Horn cubes — vanilla `el.java` pivots both at (0, 3, -7), cube_offset
# (-4/+4, -5, -4), size (1, 3, 1). DEVIATIONS FROM VANILLA toward
# modern-MC cow ear placement:
#   1) Shifted 1 px OUTWARD in X (cube_offset.x: -4 → -5). Vanilla
#      horn intersected head's left edge causing z-fighting and
#      mostly-buried geometry. Outward shift puts the horn's +X face
#      flush against head's -X face — no z-fight, ears clearly stick
#      out laterally like modern MC cow ears.
#   2) Shifted 1 px DOWN (cube_offset.y: -5 → -4). Cube MODEL Y range
#      goes from (-2, 1) to (-1, 2) → world Y center 1.46875 (was
#      1.53125). Modern MC ears sit lower on the head's top quadrant,
#      not flush with the very top.
#   3) Shifted 2 px FORWARD (cube_offset.z: -4 → -6). MODEL Z range
#      (-13, -12) → world Z -0.78125 (was -0.65625 in vanilla, then
#      -0.71875 after first 1-px shift). Horns now sit toward the
#      FRONT half of the head's Z extent (head Z range -0.875 to
#      -0.5, horns at -0.8125 to -0.75), reading as "above the
#      face" rather than "above the back of the head".
# Right horn cube MODEL center: (-4.5, 0.5, -12.5) → world
# (-0.28125, 1.46875, -0.78125). Left horn mirrors X to +0.28125.
const _HORN_RIGHT_OFFSET: Vector3 = Vector3(-0.28125, 1.46875, -0.78125)
const _HORN_LEFT_OFFSET: Vector3 = Vector3(0.28125, 1.46875, -0.78125)
# Udder — vanilla `el.a` at (0, 14, 6), rotated PI/2 X. Cube
# 4×6×2 → 0.25 × 0.125 × 0.375 m (after rotation: 0.25 × 0.375 × 0.125
# but vanilla rotation puts the long axis along Z). Sits under the
# body's rear belly.
const _UDDER_OFFSET: Vector3 = Vector3(0.0, 0.6875, 0.375)

# Walk-animation constants — identical to pig (vanilla `ij.java::a()`
# applies the same formula to all `ij`-derived mobs). All 4 legs swing
# at 1.4 rad with diagonal gait.
const _WALK_FREQ: float = 0.6662
const _WALK_DIST_SCALE: float = 12.0
const _WALK_ANIM_LERP_PER_SEC: float = 8.0
const _LEG_AMPLITUDE: float = 1.4
# Step-SFX stride.
const _STEP_STRIDE: float = 2.0  # cow takes longer strides than pig

# AI — direct copy of pig.gd's wander+flee FSM. See pig.gd for the
# vanilla-source citations (fc.java, ak.java, hf.java).
const _AI_TICK_DT: float = 1.0 / 20.0
const _AI_WANDER_X_RANGE: int = 6
const _AI_WANDER_Y_RANGE: int = 3
const _AI_NEW_TARGET_DENOM: int = 80
const _AI_ABANDON_DENOM: int = 100
const _AI_YAW_TWITCH_CHANCE: float = 0.05
const _AI_YAW_TWITCH_RANGE: float = PI / 18.0
const _AI_SCORE_GRASS: float = 10.0
const _AI_SCORE_LIGHT_OFFSET: float = -0.5
const _AI_ARRIVE_DIST: float = 0.7
const _AI_WALK_SPEED: float = 0.7
const _AI_MAX_YAW_STEP: float = PI / 6.0
const _AI_PATHFIND_RADIUS: float = 16.0
const _AI_PATHFIND_MAX_ITERS: int = 200
const _AI_FLEE_TICKS: int = 60
const _AI_FLEE_SPEED: float = 1.4
const _AI_JUMP_VELOCITY: float = 6.0
# Horizontal speed boost during step-up jumps. Normal walk speed (0.7
# m/s) covers ~0.5 m horizontal across the ~0.75 s air time — not
# enough for a 1-block (1.0 m) step. 2.0 m/s gives ~1.5 m horizontal
# = comfortable clearance. Only applied during jumps, then drops back
# to walk speed in the next tick once on floor.
const _AI_STEP_BOOST_SPEED: float = 2.0

# Leg-mesh refs for walk animation.
var _leg_front_l: MeshInstance3D
var _leg_front_r: MeshInstance3D
var _leg_rear_l: MeshInstance3D
var _leg_rear_r: MeshInstance3D

var _walk_dist: float = 0.0
var _walk_anim_amount: float = 0.0
var _step_accum: float = 0.0

# AI state.
var _ai_tick_accum: float = 0.0
var _ai_path: Array = []
var _ai_flee_ticks_remaining: int = 0
var _ai_flee_from: Vector3 = Vector3.ZERO


# MobBase environment overrides — cow BB total height = body + legs =
# 0.625 + 0.75 = 1.375 m. Eye height ~1.1 m (head sits above body).
# Width = body X axis (0.75 m).
func _get_body_height() -> float:
	return _BODY_SIZE.y + _LEG_SIZE.y


func _get_eye_height() -> float:
	return 1.1


func _get_body_width() -> float:
	return _BODY_SIZE.x


func _ready() -> void:
	max_health = 10
	# Vanilla as.g_() = LEATHER (dx.aD). Beef wasn't in Alpha — added
	# in later MC versions. 0-2 quantity matches the pig's 0-2 pork.
	drop_item_id = Items.LEATHER
	drop_count_min = 0
	drop_count_max = 2
	_build_collision_shape()
	_build_model()
	super._ready()


func _physics_process(delta: float) -> void:
	super._physics_process(delta)  # super handles dying short-circuit
	if _dying:
		return
	_ai_tick_accum += delta
	while _ai_tick_accum >= _AI_TICK_DT:
		_ai_tick_accum -= _AI_TICK_DT
		_ai_tick()


func _process(delta: float) -> void:
	super._process(delta)
	_advance_walk_animation(delta)


# Two-shape collision (MobBase helpers). Body capsule = physics-only
# (centered on origin, symmetric around Y → no rotation-induced
# stuck-clipping). Head Area3D = hit-only, sized to cover head + both
# horns so arrow + sword hits land on the protruding silhouette.
#
# Body capsule: radius = _BODY_SIZE.x / 2 = 0.375, height covers body +
# legs (~1.375). Use 1.5 for a small vertical margin.
#
# Head box covers HEAD_OFFSET (0, 1.25, -0.6875) plus horn extent:
# horns at Y=1.46875 ± 0.09375 (top = 1.5625), so we lift the box
# center to 1.28 and use height 0.65 → Y range [0.955, 1.605]. Width
# 0.65 covers horn X-extent (±0.3125). Depth 0.5 covers head + horn
# Z-extent (-0.9375 to -0.4375).
func _build_collision_shape() -> void:
	_build_body_capsule(_BODY_SIZE.x * 0.5, 1.5)
	_build_head_hit_area(Vector3(0.65, 0.65, 0.5), Vector3(0.0, 1.28, -0.6875))


# Vanilla `el.java` model build — body + head + 4 legs + 2 horns + udder.
func _build_model() -> void:
	var tex: Texture2D = load(_COW_TEXTURE_PATH) as Texture2D
	var cow_mat: StandardMaterial3D = _make_textured_material(tex)
	# Body (overrides ij.java's base body): cube 12×18×10 at tex (18, 4),
	# rotated -PI/2 X to lay horizontal.
	var body_mesh_size := Vector3(
		_BODY_CUBE_PX.x * _PIXEL_TO_METER,
		_BODY_CUBE_PX.y * _PIXEL_TO_METER,
		_BODY_CUBE_PX.z * _PIXEL_TO_METER
	)
	var body_mesh := MeshInstance3D.new()
	body_mesh.mesh = MobCube.build_textured_cube(
		body_mesh_size, _COW_TEXTURE_SIZE, _BODY_TEX_ORIGIN, _BODY_CUBE_PX, false
	)
	body_mesh.position = Vector3(0, _BODY_Y_OFFSET, _BODY_Z_OFFSET)
	body_mesh.rotation = Vector3(-PI * 0.5, 0, 0)
	body_mesh.material_override = cow_mat
	add_child(body_mesh)
	# Head (overrides ij.java's base head): cube 8×8×6 at tex (0, 0).
	# Eyes drawn at the cube's -Z face per pig.gd's pixel-scan finding;
	# no Y rotation needed since pig faces -Z (Godot forward).
	var head_size := Vector3(
		_HEAD_CUBE_PX.x * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.y * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.z * _PIXEL_TO_METER
	)
	var head_mesh := MeshInstance3D.new()
	head_mesh.mesh = MobCube.build_textured_cube(
		head_size, _COW_TEXTURE_SIZE, _HEAD_TEX_ORIGIN, _HEAD_CUBE_PX, false
	)
	head_mesh.position = _HEAD_OFFSET
	head_mesh.material_override = cow_mat
	add_child(head_mesh)
	# Horns — small 1×3×1 nubs on top of head. Both horns share the
	# (22, 0) tex region.
	var horn_size := Vector3(
		_HORN_CUBE_PX.x * _PIXEL_TO_METER,
		_HORN_CUBE_PX.y * _PIXEL_TO_METER,
		_HORN_CUBE_PX.z * _PIXEL_TO_METER
	)
	for offset in [_HORN_RIGHT_OFFSET, _HORN_LEFT_OFFSET]:
		var horn := MeshInstance3D.new()
		horn.mesh = MobCube.build_textured_cube(
			horn_size, _COW_TEXTURE_SIZE, _HORN_TEX_ORIGIN, _HORN_CUBE_PX, false
		)
		horn.position = offset
		horn.material_override = cow_mat
		add_child(horn)
	# Udder — 4×6×2 cube rotated PI/2 X (vanilla `el.a.d = 1.5707964f`).
	# In our Godot frame that's -PI/2 X (same convention as body).
	var udder_mesh_size := Vector3(
		_UDDER_CUBE_PX.x * _PIXEL_TO_METER,
		_UDDER_CUBE_PX.y * _PIXEL_TO_METER,
		_UDDER_CUBE_PX.z * _PIXEL_TO_METER
	)
	var udder := MeshInstance3D.new()
	udder.mesh = MobCube.build_textured_cube(
		udder_mesh_size, _COW_TEXTURE_SIZE, _UDDER_TEX_ORIGIN, _UDDER_CUBE_PX, false
	)
	udder.position = _UDDER_OFFSET
	udder.rotation = Vector3(-PI * 0.5, 0, 0)
	udder.material_override = cow_mat
	add_child(udder)
	# 4 legs per vanilla `el.java` lines 28-35 adjustments to base `ij`
	# leg positions. Front legs at (±4, _, +7), rear at (±4, _, -6).
	# Cow legs are 12 px tall (vs pig's 6) → 0.75 m tall.
	# Vanilla `el.java` adjusts ij's leg pivots:
	#   h front-right: x -= 1, z -= 1 → MODEL (-4, 12, -6) → Godot (+0.25, hip, -0.375)
	#   i front-left:  x += 1, z -= 1 → MODEL ( 4, 12, -6) → Godot (-0.25, hip, -0.375)
	#   f rear-right:  x -= 1, z += 0 → MODEL (-4, 12,  7) → Godot (+0.25, hip, +0.4375)
	#   g rear-left:   x += 1, z += 0 → MODEL ( 4, 12,  7) → Godot (-0.25, hip, +0.4375)
	# Earlier code had front/rear Z magnitudes swapped (used f/g's |7|
	# for front and h/i's |6| for rear), positioning front legs 1 px
	# too far forward.
	var leg_x: float = 4.0 / 16.0
	var leg_z_front: float = -6.0 / 16.0
	var leg_z_rear: float = 7.0 / 16.0
	_leg_front_r = _add_leg(Vector3(leg_x, _LEG_Y_OFFSET, leg_z_front), cow_mat, false)
	_leg_front_l = _add_leg(Vector3(-leg_x, _LEG_Y_OFFSET, leg_z_front), cow_mat, true)
	_leg_rear_r = _add_leg(Vector3(leg_x, _LEG_Y_OFFSET, leg_z_rear), cow_mat, false)
	_leg_rear_l = _add_leg(Vector3(-leg_x, _LEG_Y_OFFSET, leg_z_rear), cow_mat, true)


func _add_leg(hip_pos: Vector3, mat: StandardMaterial3D, mirror: bool) -> MeshInstance3D:
	var pivot := Node3D.new()
	var leg_size := Vector3(
		_LEG_CUBE_PX.x * _PIXEL_TO_METER,
		_LEG_CUBE_PX.y * _PIXEL_TO_METER,
		_LEG_CUBE_PX.z * _PIXEL_TO_METER
	)
	pivot.position = Vector3(hip_pos.x, hip_pos.y + leg_size.y * 0.5, hip_pos.z)
	add_child(pivot)
	var mi := MeshInstance3D.new()
	mi.mesh = MobCube.build_textured_cube(
		leg_size, _COW_TEXTURE_SIZE, _LEG_TEX_ORIGIN, _LEG_CUBE_PX, mirror
	)
	mi.position = Vector3(0, -leg_size.y * 0.5, 0)
	mi.material_override = mat
	pivot.add_child(mi)
	return mi


func _make_textured_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	return mat


# --- AI tick (mirrors pig.gd; see there for vanilla-source citations) ---


func _ai_tick() -> void:
	# Vanilla `hf.B()` rolls the idle-sound chance per tick. Centralized
	# on MobBase so every species uses the same `nextInt(1000) < a++`
	# pattern (mean ~1 fire per 6 s, matching vanilla `b() = 80`).
	if roll_idle_sfx_tick():
		_play_idle_sfx()
	if _ai_flee_ticks_remaining > 0:
		_ai_flee_ticks_remaining -= 1
		_tick_flee()
		return
	if not _ai_path.is_empty():
		_tick_walk_path()
	else:
		_tick_idle()


func _tick_walk_path() -> void:
	var next_node: Vector3i = _ai_path[0]
	var node_center: Vector3 = (
		Vector3(float(next_node.x), float(next_node.y), float(next_node.z)) + Vector3(0.5, 0.0, 0.5)
	)
	var to_node: Vector3 = node_center - global_position
	to_node.y = 0.0
	if to_node.length_squared() < _AI_ARRIVE_DIST * _AI_ARRIVE_DIST:
		_ai_path.pop_front()
		return
	if randi() % _AI_ABANDON_DENOM == 0:
		_ai_path.clear()
		return
	var dir: Vector3 = to_node.normalized()
	# Step-up: if next path node is HIGHER than current cell, jump AND
	# boost horizontal velocity so the cow clears the 1-block gap. The
	# normal walk speed (0.7 m/s) × air time (~0.75 s) = 0.5 m
	# horizontal, not enough for a 1-m step. The boost applies once on
	# the jump frame; once grounded again the next tick resets to walk
	# speed. Down-steps don't need this — gravity handles them.
	var current_cell_y: int = int(floor(global_position.y + 0.05))
	if next_node.y > current_cell_y and mob_is_on_floor():
		velocity.y = _AI_JUMP_VELOCITY
		velocity.x = dir.x * _AI_STEP_BOOST_SPEED
		velocity.z = dir.z * _AI_STEP_BOOST_SPEED
	else:
		velocity.x = dir.x * _AI_WALK_SPEED
		velocity.z = dir.z * _AI_WALK_SPEED
	_face_walk_direction()


func _tick_idle() -> void:
	if roll_wander_gate(_AI_NEW_TARGET_DENOM):
		if _pick_wander_target():
			return
	if randf() < _AI_YAW_TWITCH_CHANCE:
		rotation.y += randf_range(-_AI_YAW_TWITCH_RANGE, _AI_YAW_TWITCH_RANGE)


func _tick_flee() -> void:
	var away: Vector3 = global_position - _ai_flee_from
	away.y = 0.0
	if away.length_squared() < 0.0001:
		return
	var dir: Vector3 = away.normalized()
	velocity.x = dir.x * _AI_FLEE_SPEED
	velocity.z = dir.z * _AI_FLEE_SPEED
	_face_walk_direction()


func _pick_wander_target() -> bool:
	if _chunk_manager == null:
		return false
	var best_score: float = -99999.0
	var best_cell: Vector3i = Vector3i.ZERO
	var found: bool = false
	var origin: Vector3i = Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y)),
		int(floor(global_position.z)),
	)
	for _i in range(10):
		var x: int = origin.x + (randi() % (2 * _AI_WANDER_X_RANGE + 1)) - _AI_WANDER_X_RANGE
		var y: int = origin.y + (randi() % (2 * _AI_WANDER_Y_RANGE + 1)) - _AI_WANDER_Y_RANGE
		var z: int = origin.z + (randi() % (2 * _AI_WANDER_X_RANGE + 1)) - _AI_WANDER_X_RANGE
		var cell: Vector3i = Vector3i(x, y, z)
		if not Pathfinder.is_walkable(_chunk_manager, cell):
			continue
		var score: float = _score_cell(x, y, z)
		if score > best_score:
			best_score = score
			best_cell = cell
			found = true
	if not found:
		return false
	_ai_path = Pathfinder.find_path(
		_chunk_manager, origin, best_cell, _AI_PATHFIND_RADIUS, _AI_PATHFIND_MAX_ITERS
	)
	return not _ai_path.is_empty()


func _score_cell(x: int, y: int, z: int) -> float:
	if _chunk_manager == null:
		return 0.0
	var below: int = _chunk_manager.get_world_block(Vector3i(x, y - 1, z))
	if below == Blocks.GRASS:
		return _AI_SCORE_GRASS
	var light: int = _chunk_manager.get_world_sky_light(Vector3i(x, y, z))
	return float(light) + _AI_SCORE_LIGHT_OFFSET


func _face_walk_direction() -> void:
	var vx: float = velocity.x
	var vz: float = velocity.z
	if vx * vx + vz * vz < 0.0025:
		return
	var target_yaw: float = atan2(-vx, -vz)
	var delta: float = wrapf(target_yaw - rotation.y, -PI, PI)
	delta = clampf(delta, -_AI_MAX_YAW_STEP, _AI_MAX_YAW_STEP)
	rotation.y += delta


func take_damage(
	amount: int,
	knockback_dir: Vector3 = Vector3.ZERO,
	knockback_strength: float = 1.0,
	attacker: Node = null
) -> bool:
	var landed: bool = super.take_damage(amount, knockback_dir, knockback_strength, attacker)
	if landed and knockback_dir.length_squared() > 0.0001:
		_ai_flee_ticks_remaining = _AI_FLEE_TICKS
		_ai_flee_from = global_position - knockback_dir.normalized()
		_ai_path.clear()
	return landed


# --- Walk animation (mirrors pig.gd; vanilla ij.java::a) ---


func _advance_walk_animation(delta: float) -> void:
	var vx: float = velocity.x
	var vz: float = velocity.z
	var sp_sq: float = vx * vx + vz * vz
	var speed: float = sqrt(sp_sq) if sp_sq > 0.0001 else 0.0
	var target_amount: float = clampf(speed / _AI_WALK_SPEED, 0.0, 1.0)
	var lerp_t: float = minf(_WALK_ANIM_LERP_PER_SEC * delta, 1.0)
	_walk_anim_amount = lerpf(_walk_anim_amount, target_amount, lerp_t)
	_walk_dist += _walk_anim_amount * delta * _WALK_DIST_SCALE
	var phase: float = _walk_dist * _WALK_FREQ
	var swing_a: float = sin(phase) * _LEG_AMPLITUDE * _walk_anim_amount
	var swing_b: float = sin(phase + PI) * _LEG_AMPLITUDE * _walk_anim_amount
	if _leg_rear_l != null:
		_leg_rear_l.get_parent().rotation.x = swing_a
	if _leg_rear_r != null:
		_leg_rear_r.get_parent().rotation.x = swing_b
	if _leg_front_l != null:
		_leg_front_l.get_parent().rotation.x = swing_b
	if _leg_front_r != null:
		_leg_front_r.get_parent().rotation.x = swing_a
	_step_accum += speed * delta
	if _step_accum >= _STEP_STRIDE:
		_step_accum -= _STEP_STRIDE
		_play_block_step()


# Vanilla `lw.java::a_` plays the BLOCK's step sound (step.grass etc.),
# NOT a mob-specific clip. Look up the block under the cow's feet and
# play its material's step sound. mob/cow/step*.ogg files exist in the
# vanilla assets but vanilla uses them elsewhere (impact thuds, etc.) —
# using them for walking sounded like punching.
func _play_block_step() -> void:
	if _chunk_manager == null:
		return
	var below: Vector3i = Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y - 0.05)),
		int(floor(global_position.z))
	)
	var block_id: int = _chunk_manager.get_world_block(below)
	if block_id == Blocks.AIR:
		return
	SFX.play_block_step_3d(block_id, global_position)


# Species SFX overrides — vanilla as.java::d() = "mob.cow",
# f_() = f() = "mob.cowhurt" (cow shares clip for hurt + death).
func _play_idle_sfx() -> void:
	SFX.play_cow_say(global_position)


func _play_hurt_sfx() -> void:
	SFX.play_cow_hurt(global_position)


func _play_death_sfx() -> void:
	SFX.play_cow_death(global_position)


# Vanilla `as.java::a(eb player)` — right-click handler. If the player
# holds an empty bucket, swap it for a milk bucket. Otherwise no-op.
func right_click_with(item_id: int, player: Node) -> bool:
	if item_id != Items.BUCKET_EMPTY:
		return false
	var inv: Object = player.get("inventory") if player != null else null
	if inv == null or not inv.has_method("replace_selected"):
		return false
	inv.replace_selected(Items.MILK_BUCKET, 1)
	return true
