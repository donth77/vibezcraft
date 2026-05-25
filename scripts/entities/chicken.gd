class_name Chicken
extends "res://scripts/entities/mob_base.gd"

# Vanilla Alpha 1.2.6 EntityChicken (ou.java, entity id 93). Passive,
# 4 HP, drops feathers. Egg-laying timer fires every 6000-12000 ticks
# (5-10 min) and produces an EGG item. Slow-fall — when falling,
# vertical velocity is dampened by 0.6 per tick so chickens drift
# down instead of plummeting.
#
# Model `mk.java` differs from pig/cow's `ij` chain — chicken has its
# own 8-part rig:
#   a head (4×6×3 @ tex 0,0), g beak (4×2×2 @ 14,0),
#   h wattle (2×2×2 @ 14,4), b body (6×8×6 @ 0,9) rotated PI/2 X,
#   c right leg (3×5×3 @ 26,0), d left leg (3×5×3 @ 26,0),
#   e right wing (1×4×6 @ 24,13), f left wing (1×4×6 @ 24,13).
#
# DEVIATIONS from Alpha:
#   * Head look-at — vanilla `mk.a()` rotates head/beak/wattle by the
#     entity's pitch + yaw. We don't have per-entity head pitch /
#     player-tracking, so head pitch stays at 0 (chickens look
#     straight forward, matching their default behavior since Alpha
#     `ou` doesn't track players anyway). Yaw is handled automatically
#     by the parent transform (entity rotation.y rotates all children).
#
# Re-uses pig/cow AI tick + Pathfinder copy. Refactor into a shared
# PassiveMob base when sheep lands (4 passive mobs is the right time).

const _CHICKEN_TEXTURE_PATH: String = "res://assets/textures/mob/chicken.png"
const _CHICKEN_TEXTURE_SIZE: Vector2i = Vector2i(64, 32)

# Vanilla model pixel-dims per `mk.java`. n=16 in the constructor adds
# this to all Y-pivots; head Y=15, body Y=16, legs Y=19, wings Y=13.
const _PIXEL_TO_METER: float = 1.0 / 16.0
const _HEAD_CUBE_PX: Vector3i = Vector3i(4, 6, 3)
const _BEAK_CUBE_PX: Vector3i = Vector3i(4, 2, 2)
const _WATTLE_CUBE_PX: Vector3i = Vector3i(2, 2, 2)
const _BODY_CUBE_PX: Vector3i = Vector3i(6, 8, 6)
const _WING_CUBE_PX: Vector3i = Vector3i(1, 4, 6)
# Modern-MC-style leg split — vanilla `mk.java` has a single 3×5×3
# leg cube whose texture (UV at 26,0) has alpha=0 pixels carving the
# block into a thin-leg-plus-foot silhouette. The 4 transparent side
# faces make legs vanish from those camera angles in vanilla. We
# split the leg into two opaque solid cubes — a thin column placed at
# the BACK of vanilla's cube footprint (where the vanilla texture
# stripe is, the +Z model face → chicken's back in our world since we
# face -Z) and a wider foot pad covering the FRONT 2 px of vanilla's
# cube footprint (where the alpha-active 3×2 bottom-face region is).
# Result: leg comes down at chicken's rear, foot pad extends forward
# toward the toes — matches both vanilla anatomy and modern MC look.
const _LEG_CUBE_PX: Vector3i = Vector3i(1, 4, 1)
const _FOOT_CUBE_PX: Vector3i = Vector3i(3, 1, 3)
# Mesh-position Z offset (relative to hip pivot, which sits at the
# vanilla cube's TOP-CENTER, Godot Z = -0.03125). Vanilla cube Z range
# -2..+1 px = -0.125..+0.0625 m. The leg COLUMN belongs at the +Z back
# face (where vanilla paints the leg stripe) → column center Z =
# +0.03125, relative to pivot = +0.0625. The FOOT PAD covers the full
# 3×3 vanilla footprint so it includes the cell directly under the
# leg column's back position — without this, that 1×1×1 cell is empty
# and the leg appears to "float" over a missing corner.
const _LEG_Z_OFFSET: float = 0.0625
# Vanilla chicken leg color (light orange-yellow) per pixel sample
# at chicken.png (33, 1): RGB (224, 204, 105). Used for both the
# thin leg and wide foot cube — solid material, no texture lookup.
const _LEG_COLOR: Color = Color(224.0 / 255.0, 204.0 / 255.0, 105.0 / 255.0, 1.0)
const _HEAD_TEX_ORIGIN: Vector2i = Vector2i(0, 0)
const _BEAK_TEX_ORIGIN: Vector2i = Vector2i(14, 0)
const _WATTLE_TEX_ORIGIN: Vector2i = Vector2i(14, 4)
const _BODY_TEX_ORIGIN: Vector2i = Vector2i(0, 9)
const _WING_TEX_ORIGIN: Vector2i = Vector2i(24, 13)

# World-space mesh positions, computed from vanilla MODEL coords with
# T=1.5 (feet-anchor translation, same as pig/cow). Each value is
# cube_center_world.
# Head: pivot (0, 15, -4), cube_offset (-2,-6,-2), size 4×6×3 → cube
# model X(-2,2) Y(9,15) Z(-6,-3) → center (0, 12, -4.5) → world (0, 0.75, -0.28125)
const _HEAD_OFFSET: Vector3 = Vector3(0.0, 0.75, -0.28125)
# Beak: pivot (0, 15, -4), cube_offset (-2,-4,-4), size 4×2×2 → cube
# model center (0, 12, -7) → world (0, 0.75, -0.4375)
const _BEAK_OFFSET: Vector3 = Vector3(0.0, 0.75, -0.4375)
# Wattle: pivot (0, 15, -4), cube_offset (-1,-2,-3), size 2×2×2 → cube
# model center (0, 14, -6) → world (0, 0.625, -0.375)
const _WATTLE_OFFSET: Vector3 = Vector3(0.0, 0.625, -0.375)
# Body: pivot (0, 16, 0), cube_offset (-3,-4,-3), size 6×8×6, rotated
# -PI/2 X → post-rotation cube model X(-3,3) Y(13,19) Z(-4,4) → center
# (0, 16, 0) → world (0, 0.5, 0)
const _BODY_OFFSET: Vector3 = Vector3(0.0, 0.5, 0.0)
# Leg pivot world positions (hip = top + center of vanilla cube
# footprint). Vanilla mk.java leg cube extends MODEL X (-3, 0), Y
# (19, 24), Z (-2, +1) → vanilla cube center MODEL (-1.5, 21.5, -0.5).
# Pivot Y at TOP of leg = world Y of cube top after Y-flip: 24/16 -
# 19/16 = 0.3125. XZ centered on cube center: (∓0.09375, _, -0.03125).
# The leg COLUMN and FOOT PAD meshes are then offset in Z via
# _LEG_Z_OFFSET / _FOOT_Z_OFFSET so the column lands at the back of
# the footprint and the foot lands at the front (see _add_leg).
const _LEG_RIGHT_HIP: Vector3 = Vector3(-0.09375, 0.3125, -0.03125)
const _LEG_LEFT_HIP: Vector3 = Vector3(0.09375, 0.3125, -0.03125)
# Right wing: pivot (-4, 13, 0), cube_offset (0,0,-3), size 1×4×6 →
# cube model X(-4,-3) Y(13,17) Z(-3,3) → center (-3.5, 15, 0) →
# world (-0.21875, 0.5625, 0)
const _WING_RIGHT_OFFSET: Vector3 = Vector3(-0.21875, 0.5625, 0.0)
const _WING_LEFT_OFFSET: Vector3 = Vector3(0.21875, 0.5625, 0.0)

# Vanilla BB `ou.a(0.3f, 0.4f)` = setSize(width, height): 0.3 wide and
# deep, 0.4 tall.
const _BB_WIDTH: float = 0.3
const _BB_HEIGHT: float = 0.4

# Walk animation — vanilla `mk.a()` lines 63-64 use the same formula
# as `ij` for legs: cos(walkDist × 0.6662 [+PI]) × 1.4 × limbAmount.
# Chicken has only 2 legs, anti-phase.
const _WALK_FREQ: float = 0.6662
const _WALK_DIST_SCALE: float = 12.0
const _WALK_ANIM_LERP_PER_SEC: float = 8.0
const _LEG_AMPLITUDE: float = 1.4
const _STEP_STRIDE: float = 1.0  # short legs → shorter stride than cow

# Idle SFX roll — same rate as other animals (1/120 per random tick).
const _IDLE_SFX_ROLL_INTERVAL: float = 0.1
const _IDLE_SFX_CHANCE: float = 1.0 / 120.0

# Egg-lay timer — vanilla `ou.java` line 19: i = rand.nextInt(6000) +
# 6000 → ticks in [6000, 12000] = 5..10 minutes at 20 TPS.
const _EGG_TIMER_MIN: int = 6000
const _EGG_TIMER_MAX: int = 12000

# Slow-fall — vanilla `ou.k()` lines 37-39: `if (!onGround && motionY
# < 0) { motionY *= 0.6 }` per tick. Per-frame equivalent at 20 TPS:
# pow(0.6, 20 × delta) gives the same decay over the same wall time.
const _SLOW_FALL_FACTOR: float = 0.6

# Wing flap — vanilla `ou.k()` lines 23-40 + `fk.a(ou, partialTick)`:
#   c (wing_state) ranges 0..1; -0.3/tick on ground, +1.2/tick in air
#   f (flap_mult) resets to 1.0 when in air; ×0.9 decay per tick
#   b (flap_accum) += f × 2 per tick
#   wing_rotation_z = (sin(b) + 1) × c  (mirrored ±f for left/right)
# Per-frame deltas use `tick_scale = delta / _AI_TICK_DT` so the
# update rates stay frame-rate independent and the animation is
# smooth (vs the 20 Hz discrete tick steps).
const _WING_STATE_GROUND_DELTA: float = -0.3
const _WING_STATE_AIR_DELTA: float = 1.2
const _WING_FLAP_DECAY: float = 0.9
const _WING_FLAP_RATE: float = 2.0

# AI — direct copy of pig/cow wander+flee FSM. See pig.gd for vanilla
# source citations (fc.java, ak.java, hf.java).
const _AI_TICK_DT: float = 1.0 / 20.0
const _AI_WANDER_X_RANGE: int = 6
const _AI_WANDER_Y_RANGE: int = 3
const _AI_NEW_TARGET_DENOM: int = 80
const _AI_ABANDON_DENOM: int = 100
const _AI_YAW_TWITCH_CHANCE: float = 0.05
const _AI_YAW_TWITCH_RANGE: float = PI / 18.0
const _AI_SCORE_GRASS: float = 10.0
const _AI_SCORE_LIGHT_OFFSET: float = -0.5
const _AI_ARRIVE_DIST: float = 0.5  # smaller than pig/cow per smaller BB
const _AI_WALK_SPEED: float = 0.7
const _AI_MAX_YAW_STEP: float = PI / 6.0
const _AI_PATHFIND_RADIUS: float = 16.0
const _AI_PATHFIND_MAX_ITERS: int = 200
const _AI_FLEE_TICKS: int = 60
const _AI_FLEE_SPEED: float = 1.4
const _AI_JUMP_VELOCITY: float = 6.0
const _AI_STEP_BOOST_SPEED: float = 2.0

# Leg-mesh refs for walk animation.
var _leg_l: MeshInstance3D
var _leg_r: MeshInstance3D
# Wing pivot refs — Node3D parents of the wing meshes. Rotated around
# Z axis (entity forward) to swing wings up/down. Mirrored: right
# uses +rotation.z, left uses -rotation.z.
var _wing_pivot_l: Node3D
var _wing_pivot_r: Node3D

var _walk_dist: float = 0.0
var _walk_anim_amount: float = 0.0
var _step_accum: float = 0.0
var _idle_sfx_accum: float = 0.0

# Wing flap state (vanilla `ou` fields b, c, f).
var _wing_state: float = 0.0  # 0..1, vanilla `c`
var _wing_flap_mult: float = 0.0  # vanilla `f`
var _wing_flap_accum: float = 0.0  # vanilla `b`

# Egg-lay timer (ticks remaining until next egg).
var _egg_timer_ticks: int = 0

# AI state.
var _ai_tick_accum: float = 0.0
var _ai_path: Array = []
var _ai_flee_ticks_remaining: int = 0
var _ai_flee_from: Vector3 = Vector3.ZERO


# MobBase environment overrides. Vanilla `ou.a(0.3f, 0.4f)` set BB to
# 0.3 × 0.4 but the actual visible chicken silhouette (head + body +
# legs) is taller and slightly wider. We use the silhouette dims so
# downstream consumers (fire visual size, swim-check body center,
# arrow ellipsoid hit test) line up with what the player sees — same
# rationale as the collision box widening in _build_collision_shape.
# Eye height stays at the head position (~y=0.85 in the visible model)
# so head-aware checks read the real head, not the legacy BB top.
func _get_body_height() -> float:
	return 0.95


func _get_eye_height() -> float:
	return 0.85


func _get_body_width() -> float:
	return 0.5


func _ready() -> void:
	max_health = 4  # vanilla `ou.J = 4`
	# Vanilla `ou.g_() = dx.J.aW = FEATHER`, 0-2 per kill (matches
	# pig/cow's 0-2 drop count from base Entity.dropFewItems).
	drop_item_id = Items.FEATHER
	drop_count_min = 0
	drop_count_max = 2
	_build_collision_shape()
	_build_model()
	_reset_egg_timer()
	super._ready()


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	# Slow-fall — apply post-gravity dampening when in air + falling.
	# Vanilla per-tick decay; we use the equivalent per-frame decay
	# via pow(0.6, 20 × delta) so wall-time behavior is unchanged.
	if not is_on_floor() and velocity.y < 0.0:
		velocity.y *= pow(_SLOW_FALL_FACTOR, 20.0 * delta)
	if _dying:
		return
	_ai_tick_accum += delta
	while _ai_tick_accum >= _AI_TICK_DT:
		_ai_tick_accum -= _AI_TICK_DT
		_ai_tick()


func _process(delta: float) -> void:
	super._process(delta)
	_advance_walk_animation(delta)
	_update_wing_animation(delta)
	_roll_idle_sfx(delta)


# Vanilla `ou.k()` wing-state update (lines 23-40) + `fk.a()` wing
# rotation formula (`(sin(b) + 1) × c`). Run per-frame for smooth
# animation; deltas scaled by `tick_scale = delta / tick_dt` so the
# update rates match vanilla's per-tick deltas in wall-time.
func _update_wing_animation(delta: float) -> void:
	if _wing_pivot_r == null:
		return
	var tick_scale: float = delta / _AI_TICK_DT
	var on_ground: bool = is_on_floor()
	# c (wing_state): -0.3/tick on ground, +1.2/tick in air (clamped 0..1).
	var state_delta: float = _WING_STATE_GROUND_DELTA if on_ground else _WING_STATE_AIR_DELTA
	_wing_state = clampf(_wing_state + state_delta * tick_scale, 0.0, 1.0)
	# f (flap_mult): reset to 1.0 when in air, then ×0.9 decay per tick.
	# pow(0.9, tick_scale) is the smooth per-frame equivalent of the
	# vanilla per-tick ×0.9.
	if not on_ground and _wing_flap_mult < 1.0:
		_wing_flap_mult = 1.0
	_wing_flap_mult *= pow(_WING_FLAP_DECAY, tick_scale)
	# b (flap_accum): += f × 2 per tick. Drives the sin() oscillation.
	_wing_flap_accum += _wing_flap_mult * _WING_FLAP_RATE * tick_scale
	# Wing rotation around Z (entity forward axis). Vanilla `e.f = f4`,
	# `f.f = -f4` — but vanilla also applies a 180° Y entity rotation
	# at render time, which flips the X axis. Without that flip in our
	# Godot impl, +f4 rotates the wing TOWARD body center (folding in),
	# the opposite of what flapping should do. Negating the signs here
	# undoes the missing 180° Y flip: right wing -f4 raises tip UP +
	# OUTWARD (away from body), left wing +f4 mirrors it on the other
	# side. Net visual matches vanilla: wings spread up & out on flap.
	var f4: float = (sin(_wing_flap_accum) + 1.0) * _wing_state
	_wing_pivot_r.rotation.z = -f4
	_wing_pivot_l.rotation.z = f4


# Two-shape collision (MobBase helpers). Body capsule = physics-only
# (drives move_and_slide; symmetric around Y so yaw doesn't shift its
# world center; rounded edges slide off block corners). Head Area3D =
# hit-only (covers head + beak + wattle without ever participating in
# physics depenetration, which was the root cause of chickens getting
# stuck clipping through grass blocks).
#
# Head box covers:
#   * Head cube: HEAD_OFFSET (0, 0.75, -0.28125), 4×6×3 px
#   * Beak: BEAK_OFFSET (0, 0.75, -0.4375), 4×2×2 px, extends to z=-0.5
#   * Wattle: 2×2×2 px below the beak
# Box Z range [-0.515, -0.165] catches beak tip and head back face;
# Y range [0.55, 0.95] catches head top and bottom of beak.
func _build_collision_shape() -> void:
	_build_body_capsule(0.25, 0.95)
	_build_head_hit_area(Vector3(0.3, 0.4, 0.35), Vector3(0.0, 0.75, -0.34))


func _build_model() -> void:
	var tex: Texture2D = load(_CHICKEN_TEXTURE_PATH) as Texture2D
	var chicken_mat: StandardMaterial3D = _make_textured_material(tex)
	# Head — vanilla 4×6×3 cube, eyes on -Z face per the standard
	# vanilla convention (head front = MODEL -Z direction, matches
	# Godot forward = -Z; no rotation needed).
	_add_part(_HEAD_CUBE_PX, _HEAD_TEX_ORIGIN, _HEAD_OFFSET, chicken_mat)
	# Beak — protrudes forward of the head.
	_add_part(_BEAK_CUBE_PX, _BEAK_TEX_ORIGIN, _BEAK_OFFSET, chicken_mat)
	# Wattle — small cube under the beak (the red dangly bit).
	_add_part(_WATTLE_CUBE_PX, _WATTLE_TEX_ORIGIN, _WATTLE_OFFSET, chicken_mat)
	# Body — rotated -PI/2 X so the cube's long axis lays along Z
	# (chicken's front-to-back length). Same convention as pig/cow.
	var body_mesh := MeshInstance3D.new()
	var body_size := Vector3(
		_BODY_CUBE_PX.x * _PIXEL_TO_METER,
		_BODY_CUBE_PX.y * _PIXEL_TO_METER,
		_BODY_CUBE_PX.z * _PIXEL_TO_METER
	)
	body_mesh.mesh = MobCube.build_textured_cube(
		body_size, _CHICKEN_TEXTURE_SIZE, _BODY_TEX_ORIGIN, _BODY_CUBE_PX, false
	)
	body_mesh.position = _BODY_OFFSET
	body_mesh.rotation = Vector3(-PI * 0.5, 0, 0)
	body_mesh.material_override = chicken_mat
	add_child(body_mesh)
	# Two legs — each is a hip-pivot Node3D holding two child meshes:
	# a thin 1×4×1 LEG column above and a wider 3×1×3 FOOT pad below.
	# Both rotate together when the pivot's rotation.x changes (walk
	# anim). Solid-color material (no texture lookup) — vanilla
	# chicken leg UV is a near-uniform yellow with alpha=0 carving
	# that we replace with two opaque cubes for stable rendering.
	var leg_mat: StandardMaterial3D = _make_solid_material(_LEG_COLOR)
	_leg_r = _add_leg(_LEG_RIGHT_HIP, leg_mat)
	_leg_l = _add_leg(_LEG_LEFT_HIP, leg_mat)
	# Wings — built with a pivot Node3D at the SHOULDER so vanilla's
	# `pivot.rotation.z = ±f4` rotates the wing around its attach
	# point. Vanilla `mk.java` puts shoulders at MODEL (±4, 13, 0) =
	# 1 px OUTSIDE body's edge (body extends MODEL X ±3). Rotating
	# around that pivot sweeps the wing's inner-top corner AWAY from
	# body, leaving a visible "floating wing" gap during flap.
	#
	# DEVIATION: shift the pivot INWARD by 1 px to land exactly on
	# body's outer face at world ±0.1875. Wing's inner-top corner
	# now stays AT the pivot, so it never separates from body during
	# rotation. Cube position unchanged (mesh offset adjusts to
	# preserve the wing's world extent). Cosmetic improvement; loses
	# 1 px of vanilla pivot fidelity but fixes the disconnect.
	_wing_pivot_r = _add_wing(
		Vector3(-0.1875, 0.6875, 0.0), Vector3(-0.03125, -0.125, 0.0), chicken_mat, false
	)
	_wing_pivot_l = _add_wing(
		Vector3(0.1875, 0.6875, 0.0), Vector3(0.03125, -0.125, 0.0), chicken_mat, true
	)


# Wing with shoulder-pivot for vanilla-style flap rotation. `pivot_pos`
# is the shoulder world position; `mesh_offset` is the cube-center
# offset from the pivot (vanilla's cube_offset + cube_size/2 reduced).
func _add_wing(
	pivot_pos: Vector3, mesh_offset: Vector3, mat: StandardMaterial3D, mirror: bool
) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = pivot_pos
	add_child(pivot)
	var size := Vector3(
		_WING_CUBE_PX.x * _PIXEL_TO_METER,
		_WING_CUBE_PX.y * _PIXEL_TO_METER,
		_WING_CUBE_PX.z * _PIXEL_TO_METER
	)
	var mi := MeshInstance3D.new()
	mi.mesh = MobCube.build_textured_cube(
		size, _CHICKEN_TEXTURE_SIZE, _WING_TEX_ORIGIN, _WING_CUBE_PX, mirror
	)
	mi.position = mesh_offset
	mi.material_override = mat
	pivot.add_child(mi)
	return pivot


# Builds a static (unrotated, no-walk-anim) cube part and adds it as a
# child mesh. Used for head, beak, wattle, wings.
func _add_part(
	cube_px: Vector3i,
	tex_origin: Vector2i,
	pos: Vector3,
	mat: StandardMaterial3D,
	mirror: bool = false
) -> MeshInstance3D:
	var size := Vector3(
		cube_px.x * _PIXEL_TO_METER, cube_px.y * _PIXEL_TO_METER, cube_px.z * _PIXEL_TO_METER
	)
	var mi := MeshInstance3D.new()
	mi.mesh = MobCube.build_textured_cube(size, _CHICKEN_TEXTURE_SIZE, tex_origin, cube_px, mirror)
	mi.position = pos
	mi.material_override = mat
	add_child(mi)
	return mi


# Build a 2-piece leg — thin column at the BACK + wide foot pad at the
# FRONT — both pivoted at the hip. Vanilla's leg cube (3×5×3) centers
# on hip XZ but its alpha-carved texture only paints two opaque regions:
# a 1-px-wide leg stripe on the +Z (back) face and a 3-wide × 2-deep
# foot on the bottom's front portion. We approximate that as two solid
# cubes positioned via `_LEG_Z_OFFSET` (back) and `_FOOT_Z_OFFSET`
# (front). Both children rotate together via the shared pivot when the
# walk animation drives `pivot.rotation.x`. Returns the LEG mesh so the
# walk-anim code can keep a handle (it only needs one — both meshes
# share the same pivot).
func _add_leg(hip_pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var pivot := Node3D.new()
	pivot.position = hip_pos
	add_child(pivot)
	# Thin leg column at chicken's BACK position. World Y range below
	# hip: -leg_size.y to 0. World Z offset: +_LEG_Z_OFFSET puts the
	# column at the +Z face of vanilla's cube footprint, where the
	# vanilla texture stripe sits.
	var leg_size := Vector3(
		_LEG_CUBE_PX.x * _PIXEL_TO_METER,
		_LEG_CUBE_PX.y * _PIXEL_TO_METER,
		_LEG_CUBE_PX.z * _PIXEL_TO_METER
	)
	var leg_mi := MeshInstance3D.new()
	leg_mi.mesh = _build_solid_cube(leg_size)
	leg_mi.position = Vector3(0, -leg_size.y * 0.5, _LEG_Z_OFFSET)
	leg_mi.material_override = mat
	pivot.add_child(leg_mi)
	# Foot pad — full 3×3 vanilla footprint centered on hip XZ. Sits
	# flush against the ground (Y = -leg_size.y - half_height below
	# hip). Includes the cell directly under the leg column's back
	# position, so the leg doesn't hang over empty space.
	var foot_size := Vector3(
		_FOOT_CUBE_PX.x * _PIXEL_TO_METER,
		_FOOT_CUBE_PX.y * _PIXEL_TO_METER,
		_FOOT_CUBE_PX.z * _PIXEL_TO_METER
	)
	var foot_mi := MeshInstance3D.new()
	foot_mi.mesh = _build_solid_cube(foot_size)
	foot_mi.position = Vector3(0, -leg_size.y - foot_size.y * 0.5, 0)
	foot_mi.material_override = mat
	pivot.add_child(foot_mi)
	return leg_mi


# Solid-color material — no texture sampling, no transparency. Used
# for chicken legs/feet where vanilla's transparency-carved leg cube
# caused parts to vanish from side angles.
func _make_solid_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	return mat


# Build a simple BoxMesh of the given size — no UV mapping needed
# since the leg/foot use a solid-color material rather than the
# chicken sheet.
func _build_solid_cube(size: Vector3) -> BoxMesh:
	var box := BoxMesh.new()
	box.size = size
	return box


func _make_textured_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	# Chicken.png leg UV at (26, 0) has TRANSPARENT alpha=0 pixels that
	# carve the 3×5×3 leg cube into a thin-leg-plus-foot silhouette
	# (vanilla designed legs as cubes with most faces alpha=0). Without
	# transparency enabled, all cube faces render solid → legs look like
	# blocks. Alpha scissor (binary opacity test at threshold 0.5)
	# matches MC's binary alpha and avoids the depth-sort weirdness of
	# alpha-blended materials.
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	return mat


# --- AI tick (mirrors pig/cow; see pig.gd for vanilla-source citations) ---


func _ai_tick() -> void:
	# Egg-lay timer fires regardless of AI state (vanilla `ou.k()` runs
	# every tick before the entity's normal update). Decremented per
	# AI tick (20 Hz) which matches vanilla's per-tick decrement.
	_egg_timer_ticks -= 1
	if _egg_timer_ticks <= 0:
		_lay_egg()
		_reset_egg_timer()
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
	var current_cell_y: int = int(floor(global_position.y + 0.05))
	if next_node.y > current_cell_y and is_on_floor():
		velocity.y = _AI_JUMP_VELOCITY
		velocity.x = dir.x * _AI_STEP_BOOST_SPEED
		velocity.z = dir.z * _AI_STEP_BOOST_SPEED
	else:
		velocity.x = dir.x * _AI_WALK_SPEED
		velocity.z = dir.z * _AI_WALK_SPEED
	_face_walk_direction()


func _tick_idle() -> void:
	if randi() % _AI_NEW_TARGET_DENOM == 0:
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


# Vanilla `ak.java::a` — animals prefer grass (10) over lit cells (light - 0.5).
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
	amount: int, knockback_dir: Vector3 = Vector3.ZERO, knockback_strength: float = 1.0
) -> bool:
	var landed: bool = super.take_damage(amount, knockback_dir, knockback_strength)
	if landed and knockback_dir.length_squared() > 0.0001:
		_ai_flee_ticks_remaining = _AI_FLEE_TICKS
		_ai_flee_from = global_position - knockback_dir.normalized()
		_ai_path.clear()
	return landed


# --- Walk animation (2 legs, anti-phase, vanilla mk.a) ---


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
	if _leg_r != null:
		_leg_r.get_parent().rotation.x = swing_a
	if _leg_l != null:
		_leg_l.get_parent().rotation.x = swing_b
	_step_accum += speed * delta
	if _step_accum >= _STEP_STRIDE:
		_step_accum -= _STEP_STRIDE
		_play_block_step()


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


func _roll_idle_sfx(delta: float) -> void:
	_idle_sfx_accum += delta
	if _idle_sfx_accum < _IDLE_SFX_ROLL_INTERVAL:
		return
	_idle_sfx_accum -= _IDLE_SFX_ROLL_INTERVAL
	if randf() < _IDLE_SFX_CHANCE:
		_play_idle_sfx()


# Species SFX overrides — vanilla ou.java d/f_/f → mob.chicken,
# mob.chickenhurt (same for hurt and death).
func _play_idle_sfx() -> void:
	SFX.play_chicken_say(global_position)


func _play_hurt_sfx() -> void:
	SFX.play_chicken_hurt(global_position)


func _play_death_sfx() -> void:
	SFX.play_chicken_death(global_position)


# --- Egg-lay (vanilla ou.k() lines 41-45) ---


func _reset_egg_timer() -> void:
	_egg_timer_ticks = randi_range(_EGG_TIMER_MIN, _EGG_TIMER_MAX)


func _lay_egg() -> void:
	if _chunk_manager == null:
		return
	SFX.play_chicken_plop(global_position)
	var egg := DroppedItem.new()
	_chunk_manager.add_child(egg)
	egg.global_position = global_position + Vector3(0, 0.4, 0)
	egg.setup(Items.EGG)
