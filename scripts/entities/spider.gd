class_name Spider
extends "res://scripts/entities/mob_base.gd"

# Vanilla Alpha 1.2.6 EntitySpider (`be.java`). Second hostile mob in
# the clone. Light-gated targeting (hostile in darkness, neutral in
# day), 0-2 string drops, melee with an Alpha-faithful pounce instead
# of the Beta wall-climb (vanilla be.java pre-Beta has no `bz`
# climbable-block flag, just the leap toward the target in attackEntity).
#
# Differences vs vanilla Alpha:
#   * No daylight burn (zombies have it via lk.java::B; vanilla spider
#     stays neutral in light but doesn't ignite — matches our impl).
#   * Pathfinding uses the existing voxel A*; spider doesn't climb
#     walls in Alpha so the standard path is fine.
#   * Pounce kick strength halved from vanilla's per-tick × 20 scaling
#     because vanilla's 8 m/s vertical sends the spider out of frame.
#
# Vanilla-faithful elements (cited inline):
#   * Body cube layout (head/front/abdomen) + UV coords from lm.java::lm()
#   * 8-leg gait with cos yaw + |sin| roll deltas, 4 phase offsets
#     (0, π, π/2, 3π/2) per vanilla `lm.java::a` lines 93-116
#   * Light-gated targeting + daytime abandon roll per be.java::c_/a
#   * 0-2 string drop per be.java::g_
#
# Visual model: vanilla 64×32 `lm.java` ModelSpider — head 8×8×8 +
# front body 6×6×6 + abdomen 10×8×12 + 8 legs 16×2×2. Texture
# coords match `lm.java::lm()` constructor:
#   head      (32, 4)
#   front     (0, 0)
#   abdomen   (0, 12)
#   legs      (18, 0) shared

const _TEXTURE_PATH: String = "res://assets/textures/mob/spider.png"
const _TEXTURE_SIZE: Vector2i = Vector2i(64, 32)

# Vanilla model dimensions in pixel-units; converted via _PIXEL_TO_METER.
const _PIXEL_TO_METER: float = 1.0 / 16.0
const _HEAD_CUBE_PX: Vector3i = Vector3i(8, 8, 8)
const _FRONT_BODY_CUBE_PX: Vector3i = Vector3i(6, 6, 6)
const _ABDOMEN_CUBE_PX: Vector3i = Vector3i(10, 8, 12)
const _LEG_CUBE_PX: Vector3i = Vector3i(16, 2, 2)

# UV origins on the 64×32 sheet (lm.java::lm() lines 21, 24, 27, 30+).
const _HEAD_TEX_ORIGIN: Vector2i = Vector2i(32, 4)
const _FRONT_BODY_TEX_ORIGIN: Vector2i = Vector2i(0, 0)
const _ABDOMEN_TEX_ORIGIN: Vector2i = Vector2i(0, 12)
const _LEG_TEX_ORIGIN: Vector2i = Vector2i(18, 0)

# Body cube placement — vanilla `lm.java::lm()` pivots all three body
# cubes at Y=15 px (= 0.9375 m) with Z offsets head=-3, front=0,
# abdomen=+9 (in px). Cube centers (= pivot + half-cube-offset):
#   head:       (0, 0.9375, -0.4375)
#   front body: (0, 0.9375, 0)
#   abdomen:    (0, 0.9375, 0.5625)
# In our world space (no Y-flip), 0.9375 m puts the body high in the
# 0.9 m BB (the top cubes poke slightly above the AABB — matches
# vanilla, the BB is conservative for hitreg, not the visible body).
# Spider faces -Z (matches cow/pig/zombie convention; head goes forward).
const _BODY_Y: float = 0.9375
const _HEAD_Z: float = -0.4375  # vanilla pivot(-3) + cube-center(-4)
const _FRONT_BODY_Z: float = 0.0
const _ABDOMEN_Z: float = 0.5625  # vanilla pivot Z=9 px

# Leg pivots — vanilla pairs at Z = 2, 1, 0, -1 px (rear→front) and
# X = ±4 px (body sides). 16 px legs, 2 px thick. Rest pose: roll
# -PI/4 (vanilla; in our positive-Y space that's +PI/4 to droop DOWN),
# yaw varies per pair per `lm.java::a` lines 75-92.
const _LEG_PIVOT_Y: float = _BODY_Y
const _LEG_PIVOT_X: float = 0.25  # vanilla 4 px = 0.25 m
const _LEG_DROOP: float = PI * 0.25  # +45° roll (Godot Y-up convention)
const _LEG_YAW_OUTER: float = PI * 0.25  # vanilla f10 * 2.0 = ±45°
const _LEG_YAW_MID: float = PI * 0.125  # vanilla f10 * 1.0 = ±22.5°
# Z offsets for the 4 pairs, front→back (matching vanilla `j/m`, `h/i`,
# `f/g`, `d/e` ordering — vanilla puts d/e at Z=2 (rear) and j/m at Z=-1
# (front)). Our positive-Z = backward so rear pair has +Z, front pair
# has -Z.
const _LEG_Z_REAR: float = 0.125
const _LEG_Z_MID_BACK: float = 0.0625
const _LEG_Z_MID_FRONT: float = 0.0
const _LEG_Z_FRONT: float = -0.0625

# Bounding box. Vanilla `be.java::be(cy)` calls `setSize(1.4, 0.9)` —
# width 1.4 m, height 0.9 m. We use a BoxShape3D matching the vanilla
# AABB exactly (X-Z symmetric 1.4 × 1.4, Y=0.9). A capsule would miss
# the abdomen — the body cube extends back to Z=+1.15 m and a capsule
# centered at origin can't reach it. Trade-off: spider needs a 2-wide
# gap to walk through (matches vanilla — spiders can't fit through
# 1-wide doorways).
const _BB_HEIGHT: float = 0.9
const _BB_WIDTH: float = 1.4  # vanilla AABB X-Z extent
const _EYE_HEIGHT: float = 0.175  # vanilla j() = aQ * 0.75 - 0.5

# AI cadence — 20 Hz tick rate matches vanilla integer-tick math.
const _AI_TICK_DT: float = 1.0 / 20.0

# Target acquisition window. Vanilla `be.java::c_()` returns the
# nearest player within 16 m IF `World.getBrightness(pos) < 0.5` (= night
# or dark cell). Otherwise no target.
const _AI_DETECT_RADIUS: float = 16.0
const _AI_ABANDON_RADIUS: float = 40.0
# Brightness threshold for hostile gate. Vanilla compares `f2 < 0.5f`
# (the world's getBrightness output). For us the closest analogue is
# the cell-light LUT at the entity's position; a sky_light < 8 gives
# brightness ≈ 0.45 in the standard LUT — close enough to vanilla's
# 0.5 cutoff. Block-light (torches) also counts: brightness is the max
# of sky × time-of-day and block_light.
const _AI_BRIGHTNESS_THRESHOLD: int = 8

# Daytime "abandon target" roll — vanilla `be.java::a` lines 41-43:
# `if (f3 > 0.5f && this.bd.nextInt(100) == 0) { this.g = null; return; }`.
# Translates to a 1 % per-AI-tick chance to drop the chase when the
# spider is currently in lit space, even if it had previously acquired
# a target while dark. The AI tick fires at 20 Hz so this is 1 %/tick.
const _AI_DAYTIME_ABANDON_CHANCE: float = 0.01

# Revenge duration — when shot/hit by the player, spider chases for
# this many seconds regardless of light level. Vanilla
# `hf.java::a(lw, int)` sets `this.g = this.aH` (target = attacker)
# and the chase persists until next damage cooldown or 100 ticks
# elapse, whichever sets a new target.
const _AI_REVENGE_DURATION_SEC: float = 5.0

# Pounce — vanilla `be.java::a` lines 45-52: if (distSq in 2..6) AND
# `bd.nextInt(10) == 0` AND on ground → motX/Z toward target × 0.5 ×
# 0.8, motY = 0.4. Vanilla per-tick = 20 Hz so this is 10 %/tick = 2 Hz
# chance. Translates poorly across our 20-Hz AI cadence too — keep the
# 0.1 probability and apply when in range.
const _AI_POUNCE_RANGE_MIN: float = 2.0  # blocks, NOT squared
const _AI_POUNCE_RANGE_MAX: float = 6.0
const _AI_POUNCE_CHANCE: float = 0.1
# Pounce kick strengths. Vanilla `motX = dx/d * 0.5 * 0.8 + motX * 0.2`,
# `motZ = dz/d * 0.5 * 0.8 + motZ * 0.2`, `motY = 0.4`. In vanilla
# motY=0.4 b/tick + gravity 0.08 b/tick² + drag 0.98 produces a ~1.1
# block peak hop with ~0.6 s airtime. Our gravity is -16 m/s² (stronger)
# so we need v=6 m/s to match the 1.1 m peak: peak = v²/(2g) = 36/32 ≈
# 1.13 m. Horizontal: vanilla averages ~6 m/s over the airtime; we use
# 6 m/s constant (no in-air drag) so total horizontal distance per
# pounce ≈ 3.6 m, matching vanilla.
const _AI_POUNCE_HORIZ: float = 6.0
const _AI_POUNCE_VERT: float = 6.0

# Re-pathfind every _AI_REPATH_TICKS at 20 Hz (= 1 s). Vanilla
# PathNavigate's `f` field rebuilds via per-tick checks; we cap to a
# coarser cadence to avoid CPU churn from re-running A* every frame.
const _AI_REPATH_TICKS: int = 20

# Wander — vanilla `fc.b_()` (EntityCreature pathToRandomDirection).
# Spider doesn't override this, so it inherits the same random-walk
# behavior all hostile mobs use when idle: 1/80 chance per tick to
# pick a random nearby cell, find the best of 10 samples, A*-path to
# it. Without this, spiders stand frozen when the player is far away
# or out of sight — they only animate when actively chasing.
const _AI_WANDER_X_RANGE: int = 6  # ±6 cells (vanilla nextInt(13) - 6)
const _AI_WANDER_Y_RANGE: int = 3
const _AI_NEW_TARGET_DENOM: int = 80
const _AI_YAW_TWITCH_CHANCE: float = 0.05
const _AI_YAW_TWITCH_RANGE: float = PI / 18.0

# Melee. Vanilla EntityMob default attackStrength = 2 HP (vanilla
# difficulty.Easy is 2, Normal also 2 in Alpha — set in EntityMob.aS).
const _AI_MELEE_RANGE: float = 1.5
const _AI_MELEE_DAMAGE: int = 2
const _AI_MELEE_COOLDOWN_SEC: float = 0.5

# Walk speed. Vanilla `am = 0.8f` per tick is much higher than zombie's
# `am = 0.23f` — spider is ~3.5× faster in vanilla. With zombie at our
# 1.0 m/s, vanilla-faithful spider speed is ~3.5 m/s. That's intentionally
# aggressive; vanilla spider is faster than a walking player.
const _AI_WALK_SPEED: float = 3.5
const _AI_JUMP_VELOCITY: float = 6.0
const _AI_STEP_BOOST_SPEED: float = 2.5
const _AI_MAX_YAW_STEP: float = PI / 4.0
const _AI_PATHFIND_RADIUS: float = 24.0
const _AI_PATHFIND_MAX_ITERS: int = 300
const _AI_ARRIVE_DIST: float = 0.7

# Beta wall-climb. Vanilla `EntitySpider.onUpdate()` from Beta 1.5+ sets
# the spider's `isOnLadder` flag to `isCollidedHorizontally`, and
# `EntityLiving.moveEntityWithHeading` then writes `motY = 0.2/tick`
# (= 4 m/sec) while on a ladder + horizontally collided. The effect is
# a steady vertical climb up any wall the spider runs into. The slow
# falling cap (motY clamped at -0.15/tick = -3 m/s) is the "sticky to
# wall" portion. Alpha 1.2.6's `be.java` doesn't have wall climb yet —
# this is one of the Beta physics behaviors our `feedback_alpha_clone
# _scope` carve-out explicitly pulls in.
const _AI_WALL_CLIMB_VELOCITY: float = 4.0
const _AI_WALL_FALL_CAP: float = -3.0
# Phys ticks at 60 Hz to keep applying the climb after the last
# horizontal collision — covers ~2 AI ticks (50 ms × 2 = 100 ms) so
# the spider keeps moving up while the AI re-pushes into the wall.
const _WALL_CLIMB_PERSIST_TICKS: int = 6

# Walk-anim params — leg pairs sway around their pivot in opposing
# phase pairs. Driven by walk distance; amplitude scales with speed.
# Vanilla `lm.java::a` lines 93-100 use `f2 * 0.6662 * 2` (yaw cos
# phase) and `f2 * 0.6662` (roll sin phase) where f2 is walkDistance.
# Vanilla walkDistance grows at ~entity-speed-per-tick × 20 m/s, so
# our delta-driven _walk_dist accumulates 1:1 with horizontal motion
# (no extra scaling — the 0.6662 constant already sets the natural
# stride cadence).
const _WALK_FREQ: float = 0.6662
# Vanilla amplitude — `* 0.4 * f3` (f3 = walkAnimAmount). Yaw + roll
# both share this scalar. Matches the visible spider leg sway exactly.
const _LEG_ANIM_AMPLITUDE: float = 0.4

# --- Visual node refs (rotated by walk animation) ---
# 8 leg pivots in pair-of-2 order: [rear_l, rear_r, mid_back_l,
# mid_back_r, mid_front_l, mid_front_r, front_l, front_r]. Matches
# vanilla `lm.java`'s d/e, f/g, h/i, j/m ordering. Parallel arrays
# below store the per-leg REST yaw + roll so each frame's anim deltas
# layer over the rest pose without drift.
var _leg_pivots: Array[Node3D] = []
var _leg_base_yaws: Array[float] = []
var _leg_base_rolls: Array[float] = []

# --- AI state ---
var _ai_tick_accum: float = 0.0
var _ai_path: Array = []
var _ai_repath_counter: int = 0
var _ai_melee_cooldown_sec: float = 0.0
var _ai_player_cache: Node3D = null
# Revenge timer — vanilla `hf.java::a(lw,int)` sets `this.g = this.aH`
# (target = attacker) on damage, overriding the normal target gate.
# Spider goes hostile FOR THIS DURATION regardless of light level. 5 s
# matches vanilla EntityLiving's revenge persistence (~100 ticks).
var _ai_revenge_remaining_sec: float = 0.0
# Phys-frame counter for wall climb. Reset to _WALL_CLIMB_PERSIST_TICKS
# each time mob_base flags a horizontal collision; decrements per
# physics tick. While > 0 we override velocity.y with the climb speed.
var _wall_climb_persist_ticks: int = 0

# --- Walk-anim state ---
var _walk_dist: float = 0.0
var _walk_anim_amount: float = 0.0


# MobBase environment overrides.
func _get_body_height() -> float:
	return _BB_HEIGHT


func _get_eye_height() -> float:
	return _EYE_HEIGHT


func _get_body_width() -> float:
	return _BB_WIDTH


func _ready() -> void:
	# Vanilla EntitySpider has 16 HP (be.java inherits EntityMob's
	# default after `aT = 16` override) — lower than zombie's 20.
	max_health = 16
	# Vanilla Alpha 1.2.6 be.java::g_() returns ITEM_STRING (id 31 vanilla;
	# Items.STRING in ours). 0-2 per kill, same range zombie uses.
	drop_item_id = Items.STRING
	drop_count_min = 0
	drop_count_max = 2
	_build_collision_shape()
	_build_model()
	super._ready()


# Spider uses a BoxShape3D matching the vanilla AABB (1.4 × 0.9 × 1.4)
# rather than mob_base's default capsule helper. Capsules can't cover
# the spider's wide-and-shallow body (abdomen extends back to Z=+1.15
# but the body cubes are centered at Y=0.94 — a Y-centered capsule
# misses the upper body / abdomen entirely, which is why arrows fired
# at the spider's back passed through). The vanilla AABB box covers
# head + body + abdomen + the inner half of the leg span; the protrud-
# ing leg tips are intentionally outside the hit volume in vanilla too.
#
# No separate head_area — the box already encloses the head cube, so
# the entire visible body is one contiguous hit volume.
func _build_collision_shape() -> void:
	var body_col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(_BB_WIDTH, _BB_HEIGHT, _BB_WIDTH)
	body_col.shape = box
	# Box centered on its origin — position Y at half-height so the
	# bottom sits at the entity's feet (Y=0).
	body_col.position = Vector3(0.0, _BB_HEIGHT * 0.5, 0.0)
	add_child(body_col)


# Vanilla `lm.java` ModelSpider — three body cubes + 8 legs sourced
# from the 64×32 spider.png. Layout (model-local, +Y up, -Z forward):
#   • head cube at front (Z=-0.4375)
#   • front body cube at center (Z=0)
#   • abdomen cube at back (Z=+0.5625)
#   • 4 leg pairs splayed outward with -45° Z-roll droop
func _build_model() -> void:
	# Shared cached material — see MobBase.get_shared_material.
	var mat: StandardMaterial3D = MobBase.get_shared_material(_TEXTURE_PATH, false)
	# Head.
	var head_size := Vector3(
		_HEAD_CUBE_PX.x * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.y * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.z * _PIXEL_TO_METER
	)
	var head := MeshInstance3D.new()
	head.mesh = MobCube.build_textured_cube(
		head_size, _TEXTURE_SIZE, _HEAD_TEX_ORIGIN, _HEAD_CUBE_PX, false
	)
	head.position = Vector3(0.0, _BODY_Y, _HEAD_Z)
	head.material_override = mat
	add_child(head)
	# Front body cube.
	var fb_size := Vector3(
		_FRONT_BODY_CUBE_PX.x * _PIXEL_TO_METER,
		_FRONT_BODY_CUBE_PX.y * _PIXEL_TO_METER,
		_FRONT_BODY_CUBE_PX.z * _PIXEL_TO_METER
	)
	var fb := MeshInstance3D.new()
	fb.mesh = MobCube.build_textured_cube(
		fb_size, _TEXTURE_SIZE, _FRONT_BODY_TEX_ORIGIN, _FRONT_BODY_CUBE_PX, false
	)
	fb.position = Vector3(0.0, _BODY_Y, _FRONT_BODY_Z)
	fb.material_override = mat
	add_child(fb)
	# Abdomen.
	var ab_size := Vector3(
		_ABDOMEN_CUBE_PX.x * _PIXEL_TO_METER,
		_ABDOMEN_CUBE_PX.y * _PIXEL_TO_METER,
		_ABDOMEN_CUBE_PX.z * _PIXEL_TO_METER
	)
	var ab := MeshInstance3D.new()
	ab.mesh = MobCube.build_textured_cube(
		ab_size, _TEXTURE_SIZE, _ABDOMEN_TEX_ORIGIN, _ABDOMEN_CUBE_PX, false
	)
	ab.position = Vector3(0.0, _BODY_Y, _ABDOMEN_Z)
	ab.material_override = mat
	add_child(ab)
	# Legs — 4 pairs. Vanilla yaw pattern: rear pair (d/e) ±45°,
	# mid-back pair (f/g) ±22.5°, mid-front pair (h/i) ∓22.5° (note
	# inversion!), front pair (j/m) ∓45°. We mirror that so the legs
	# fan OUTWARD on each side — front legs angle forward, rear legs
	# angle backward.
	_build_leg_pair(mat, _LEG_Z_REAR, _LEG_YAW_OUTER)
	_build_leg_pair(mat, _LEG_Z_MID_BACK, _LEG_YAW_MID)
	_build_leg_pair(mat, _LEG_Z_MID_FRONT, -_LEG_YAW_MID)
	_build_leg_pair(mat, _LEG_Z_FRONT, -_LEG_YAW_OUTER)


# Build a left+right leg pair pivoted at the body side. Rest pose:
# yaw ±f_yaw (per vanilla `lm.java::a` lines 85-92), roll ±_LEG_DROOP.
# Pivots + base yaws + base rolls appended in left-then-right order so
# _advance_walk_animation can layer vanilla's per-frame deltas without
# losing the rest pose to Euler decomposition drift.
func _build_leg_pair(mat: StandardMaterial3D, z_offset: float, f_yaw: float) -> void:
	var size := Vector3(
		_LEG_CUBE_PX.x * _PIXEL_TO_METER,
		_LEG_CUBE_PX.y * _PIXEL_TO_METER,
		_LEG_CUBE_PX.z * _PIXEL_TO_METER
	)
	# LEFT leg.
	var left_pivot := Node3D.new()
	left_pivot.position = Vector3(-_LEG_PIVOT_X, _LEG_PIVOT_Y, z_offset)
	left_pivot.transform.basis = Basis(Vector3.UP, f_yaw) * Basis(Vector3.BACK, _LEG_DROOP)
	add_child(left_pivot)
	var left_leg := MeshInstance3D.new()
	left_leg.mesh = MobCube.build_textured_cube(
		size, _TEXTURE_SIZE, _LEG_TEX_ORIGIN, _LEG_CUBE_PX, true
	)
	# Leg cube origin sits inside the body — offset by -size.x * 0.5 so
	# the mesh extends OUTWARD from the pivot, NOT through the body.
	left_leg.position = Vector3(-size.x * 0.5, 0.0, 0.0)
	left_leg.material_override = mat
	left_pivot.add_child(left_leg)
	_leg_pivots.append(left_pivot)
	_leg_base_yaws.append(f_yaw)
	_leg_base_rolls.append(_LEG_DROOP)
	# RIGHT leg — mirror X. Vanilla `this.e.e = -this.d.e` pattern:
	# yaw negated, droop negated (so the leg tip falls on the right
	# side instead of crossing through the body).
	var right_pivot := Node3D.new()
	right_pivot.position = Vector3(_LEG_PIVOT_X, _LEG_PIVOT_Y, z_offset)
	right_pivot.transform.basis = Basis(Vector3.UP, -f_yaw) * Basis(Vector3.BACK, -_LEG_DROOP)
	add_child(right_pivot)
	var right_leg := MeshInstance3D.new()
	right_leg.mesh = MobCube.build_textured_cube(
		size, _TEXTURE_SIZE, _LEG_TEX_ORIGIN, _LEG_CUBE_PX, false
	)
	right_leg.position = Vector3(size.x * 0.5, 0.0, 0.0)
	right_leg.material_override = mat
	right_pivot.add_child(right_leg)
	_leg_pivots.append(right_pivot)
	_leg_base_yaws.append(-f_yaw)
	_leg_base_rolls.append(-_LEG_DROOP)


func _make_textured_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	return mat


func _physics_process(delta: float) -> void:
	# Beta wall-climb. Vanilla `EntitySpider.onUpdate()` writes
	# `motY = 0.2/tick` after moveEntity whenever the spider is
	# collidedHorizontally. Two wrinkles port awkwardly to our
	# decoupled tick rates:
	#   1. mob_base zeros the horizontal velocity component the
	#      collider clipped (so AI knows it's stuck). Between AI
	#      ticks (20 Hz vs physics 60 Hz), velocity.x is 0 — no push
	#      into the wall, no further collision flag, no climb. Result:
	#      spider hops 1 frame then stops. We hold the climb intent
	#      for _WALL_CLIMB_PERSIST_TICKS phys frames after the last
	#      horizontal collision so the climb bridges the gap.
	#   2. Velocity is written BEFORE super so the upcoming move
	#      receives it — same prev-tick/next-tick coupling vanilla
	#      uses between onUpdate and moveEntityWithHeading.
	if _was_collided_horizontally and not _dying and not _physics_gated:
		_wall_climb_persist_ticks = _WALL_CLIMB_PERSIST_TICKS
	if _wall_climb_persist_ticks > 0 and not _dying and not _physics_gated:
		velocity.y = maxf(velocity.y, _AI_WALL_CLIMB_VELOCITY)
		velocity.y = maxf(velocity.y, _AI_WALL_FALL_CAP)
		_wall_climb_persist_ticks -= 1
	super._physics_process(delta)
	if _dying or _physics_gated:
		return
	# LOD-scaled tick rate — same pattern as skeleton/creeper/zombie.
	var tick_scale: float = 1.0
	if _lod_tier == LOD_MID:
		tick_scale = 4.0
	elif _lod_tier == LOD_FAR:
		tick_scale = 20.0
	var effective_dt: float = _AI_TICK_DT * tick_scale
	_ai_tick_accum += delta
	while _ai_tick_accum >= effective_dt:
		_ai_tick_accum -= effective_dt
		_ai_tick()
	# Melee cooldown ticks independently of the AI Hz so the cooldown
	# expires precisely 0.5 s after the last hit landed.
	if _ai_melee_cooldown_sec > 0.0:
		_ai_melee_cooldown_sec = maxf(0.0, _ai_melee_cooldown_sec - delta)
	# Revenge persists for _AI_REVENGE_DURATION_SEC after a hit.
	if _ai_revenge_remaining_sec > 0.0:
		_ai_revenge_remaining_sec = maxf(0.0, _ai_revenge_remaining_sec - delta)


# Vanilla `hf.java::a(EntityLiving attacker, int damage)` — on damage,
# set the attacker as the target and refresh the chase even in light.
# Players are the only damage source against mobs in our impl, so the
# revenge timer always retargets the player (no need for an explicit
# attacker reference).
func take_damage(
	amount: int,
	knockback_dir: Vector3 = Vector3.ZERO,
	knockback_strength: float = 1.0,
	attacker: Node = null
) -> bool:
	var landed: bool = super.take_damage(amount, knockback_dir, knockback_strength, attacker)
	if landed:
		_ai_revenge_remaining_sec = _AI_REVENGE_DURATION_SEC
		# Force re-acquisition next AI tick — drop any stale path so
		# the spider repaths toward the player on the next tick.
		_ai_path.clear()
		_ai_repath_counter = _AI_REPATH_TICKS  # trigger immediate repath
	return landed


func _process(delta: float) -> void:
	super._process(delta)
	if _physics_gated:
		return
	if _lod_tier == LOD_FAR:
		return
	_advance_walk_animation(delta)


# --- Hostile AI ---


# Per-tick decision: target acquisition is GATED on light level (vanilla
# c_() returns null in bright cells). Once we have a target, attack
# behavior matches `be.java::a(target, distSq)`. WITHOUT a target,
# vanilla EntityCreature.h_() (inherited; spider doesn't override)
# wanders via pathToRandomDirection — so spider doesn't just stand
# still when the player is far/light is too bright.
func _ai_tick() -> void:
	# Vanilla `hf.B()` rolls the idle-sound chance per tick. Centralized
	# on MobBase so every species uses the same `nextInt(1000) < a++`
	# pattern (mean ~1 fire per 6 s, matching vanilla `b() = 80`).
	if roll_idle_sfx_tick():
		_play_idle_sfx()
	_ai_repath_counter += 1
	var bright: bool = _is_brightly_lit()
	var revenge_active: bool = _ai_revenge_remaining_sec > 0.0
	# Daytime abandon — vanilla `be.java::a` lines 41-43. Suspended
	# during revenge so a player who hits the spider in daylight can't
	# kite + abandon-roll their way out.
	if bright and not revenge_active and not _ai_path.is_empty() and _ai_player_cache != null:
		if randf() < _AI_DAYTIME_ABANDON_CHANCE:
			_ai_path.clear()
			_ai_player_cache = null
	# Acquire / re-acquire target. Vanilla c_() returns null in bright
	# cells, but `hf.java::a` (revenge on damage) overrides that — once
	# hit, the spider targets the attacker regardless of light. Caching
	# logic: target ALWAYS resolves to the player while revenge is
	# active; otherwise only resolves in darkness (or if we already had
	# a cached target from an earlier dark moment).
	var player: Node3D = _find_player() if (not bright or revenge_active) else _ai_player_cache
	var has_chase_target: bool = false
	if player != null:
		var dist_sq: float = global_position.distance_squared_to(player.global_position)
		if dist_sq <= _AI_ABANDON_RADIUS * _AI_ABANDON_RADIUS:
			has_chase_target = true
		else:
			_ai_path.clear()
			_ai_player_cache = null
	if has_chase_target:
		_tick_chase(player)
		return
	# No target — wander. Vanilla `fc.b_()` inherited from EntityCreature.
	_tick_idle()


# Chase tick — runs only when we have a valid in-range target.
func _tick_chase(player: Node3D) -> void:
	var dist_sq: float = global_position.distance_squared_to(player.global_position)
	# In melee range — face target, brake horizontal velocity, attack.
	if dist_sq < _AI_MELEE_RANGE * _AI_MELEE_RANGE:
		_face_target(player)
		_velocity_brake()
		if _ai_melee_cooldown_sec <= 0.0:
			_attack_player(player)
		return
	# Pounce — vanilla `be.java::a` lines 45-52. 10 % per 20 Hz tick
	# when 2 m < dist < 6 m AND on ground. Vanilla onGround check skips
	# the pounce roll mid-air; we mirror via mob_is_on_floor().
	var dist: float = sqrt(dist_sq)
	if (
		dist > _AI_POUNCE_RANGE_MIN
		and dist < _AI_POUNCE_RANGE_MAX
		and mob_is_on_floor()
		and randf() < _AI_POUNCE_CHANCE
	):
		_pounce(player)
		return
	# Re-pathfind to the player's current cell every _AI_REPATH_TICKS
	# or whenever we run out of path mid-chase.
	if _ai_path.is_empty() or _ai_repath_counter >= _AI_REPATH_TICKS:
		_ai_repath_counter = 0
		_repath_toward(player)
	if not _ai_path.is_empty():
		_tick_walk_path()


# Vanilla `fc.b_()` (EntityCreature pathToRandomDirection) — inherited
# by spider. Every ~80 ticks (4 s) without an active path, pick the
# best-scored cell from 10 random samples within ±6/±3/±6 and A* to
# it. While idle, also roll a small yaw twitch (vanilla hf.b_() line
# 211-213). When a path IS active (from a previous wander), continue
# walking it instead of picking a new one.
func _tick_idle() -> void:
	if not _ai_path.is_empty():
		_tick_walk_path()
		return
	if roll_wander_gate(_AI_NEW_TARGET_DENOM):
		if _pick_wander_target():
			return
	if randf() < _AI_YAW_TWITCH_CHANCE:
		rotation.y += randf_range(-_AI_YAW_TWITCH_RANGE, _AI_YAW_TWITCH_RANGE)


# Vanilla `fc.b_()` lines 40-54 — best of 10 random samples within
# (±6, ±3, ±6) cells, scored by `World.a(x, y, z)`. Vanilla scores
# grass higher than other terrain (animals prefer grass), but spider
# is neutral so we just score sky-exposed cells higher (open ground)
# and skip unreachable goals.
func _pick_wander_target() -> bool:
	if _chunk_manager == null:
		return false
	var best_score: float = -99999.0
	var best_cell: Vector3i = Vector3i.ZERO
	var found: bool = false
	var origin: Vector3i = Vector3i(
		int(floor(global_position.x)), int(floor(global_position.y)), int(floor(global_position.z))
	)
	for _i in range(10):
		var x: int = origin.x + (randi() % (2 * _AI_WANDER_X_RANGE + 1)) - _AI_WANDER_X_RANGE
		var y: int = origin.y + (randi() % (2 * _AI_WANDER_Y_RANGE + 1)) - _AI_WANDER_Y_RANGE
		var z: int = origin.z + (randi() % (2 * _AI_WANDER_X_RANGE + 1)) - _AI_WANDER_X_RANGE
		var cell: Vector3i = Vector3i(x, y, z)
		# Prefilter unreachable goals — Pathfinder.find_path returns []
		# for those, so the wander would no-op without the check.
		if not Pathfinder.is_walkable(_chunk_manager, cell):
			continue
		# Score = sky_light at the cell. Spider has no biome preference,
		# but slight bias toward open ground keeps wander visible.
		var score: float = float(_chunk_manager.get_world_sky_light(cell))
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


# Locate the player node under Main. Cached after first hit since the
# Player scene is long-lived.
func _find_player() -> Node3D:
	if _ai_player_cache != null and is_instance_valid(_ai_player_cache):
		return _ai_player_cache
	var main: Node = get_tree().root.get_node_or_null("Main")
	if main == null:
		return null
	_ai_player_cache = main.find_child("Player", true, false) as Node3D
	return _ai_player_cache


# Sample the cell light at the spider's eye position. Returns true if
# the cell is "bright" by Alpha standards (vanilla compares World
# .getBrightness < 0.5; our analogue is sky_light × time-of-day vs
# block_light, with the threshold at level 8 ≈ 0.45 brightness in
# the standard LUT).
func _is_brightly_lit() -> bool:
	if _chunk_manager == null:
		return false  # treat as dark when CM not available (test envs)
	var eye_cell := Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y + _EYE_HEIGHT)),
		int(floor(global_position.z))
	)
	var sky: int = 15
	var block: int = 0
	if _chunk_manager.has_method("get_world_sky_light"):
		sky = _chunk_manager.get_world_sky_light(eye_cell)
	if _chunk_manager.has_method("get_world_block_light"):
		block = _chunk_manager.get_world_block_light(eye_cell)
	var sky_factor: float = WorldTime.sky_factor() if WorldTime != null else 1.0
	var effective: int = maxi(int(round(float(sky) * sky_factor)), block)
	return effective >= _AI_BRIGHTNESS_THRESHOLD


func _repath_toward(player: Node3D) -> void:
	if _chunk_manager == null:
		return
	var origin: Vector3i = Vector3i(
		int(floor(global_position.x)), int(floor(global_position.y)), int(floor(global_position.z))
	)
	var goal: Vector3i = Vector3i(
		int(floor(player.global_position.x)),
		int(floor(player.global_position.y)),
		int(floor(player.global_position.z))
	)
	_ai_path = Pathfinder.find_path(
		_chunk_manager, origin, goal, _AI_PATHFIND_RADIUS, _AI_PATHFIND_MAX_ITERS
	)


# Same walk-path routine as the passive mobs (pig/cow/sheep) — pops
# nodes within _AI_ARRIVE_DIST, step-up jumps for upward steps,
# straight velocity assignment otherwise.
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
	var dir: Vector3 = to_node.normalized()
	var current_cell_y: int = int(floor(global_position.y + 0.05))
	if next_node.y > current_cell_y and mob_is_on_floor():
		velocity.y = _AI_JUMP_VELOCITY
		velocity.x = dir.x * _AI_STEP_BOOST_SPEED
		velocity.z = dir.z * _AI_STEP_BOOST_SPEED
	else:
		velocity.x = dir.x * _AI_WALK_SPEED
		velocity.z = dir.z * _AI_WALK_SPEED
	_face_walk_direction()


# Vanilla `be.java::a` pounce branch — short upward+forward leap toward
# the target. Vanilla writes motX/Z = dx/d * 0.5 * 0.8 + motX * 0.2 and
# motY = 0.4 (vanilla per-tick); we scale to m/s and dampen by ~½ so
# the leap lands inside the same neighborhood as the player.
func _pounce(player: Node3D) -> void:
	var to_target: Vector3 = player.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return
	var dir: Vector3 = to_target.normalized()
	velocity.x = dir.x * _AI_POUNCE_HORIZ + velocity.x * 0.2
	velocity.z = dir.z * _AI_POUNCE_HORIZ + velocity.z * 0.2
	velocity.y = _AI_POUNCE_VERT
	_face_walk_direction()


func _attack_player(player: Node3D) -> void:
	if not player.has_method("take_damage"):
		return
	# Vanilla EntityMob.l calls EntityHuman.attackEntityFrom(this, attackDamage).
	# Player.take_damage(amount, source) — "mob" matches Player.DAMAGE_MOB.
	player.call("take_damage", _AI_MELEE_DAMAGE, "mob")
	_ai_melee_cooldown_sec = _AI_MELEE_COOLDOWN_SEC


func _velocity_brake() -> void:
	velocity.x = 0.0
	velocity.z = 0.0


func _face_target(target: Node3D) -> void:
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return
	var target_yaw: float = atan2(-to_target.x, -to_target.z)
	var diff: float = wrapf(target_yaw - rotation.y, -PI, PI)
	diff = clampf(diff, -_AI_MAX_YAW_STEP, _AI_MAX_YAW_STEP)
	rotation.y += diff


func _face_walk_direction() -> void:
	var vx: float = velocity.x
	var vz: float = velocity.z
	if vx * vx + vz * vz < 0.0025:
		return
	var target_yaw: float = atan2(-vx, -vz)
	var diff: float = wrapf(target_yaw - rotation.y, -PI, PI)
	diff = clampf(diff, -_AI_MAX_YAW_STEP, _AI_MAX_YAW_STEP)
	rotation.y += diff


# --- Walk animation ---


# Verbatim port of `lm.java::a` lines 93-116 — the spider's iconic
# 8-leg gait. Each of 4 pairs has BOTH a yaw delta (cos-driven, X-Z
# plane sweep) AND a roll delta (|sin|-driven, lift-up off the droop
# floor). Phase offsets 0 / π / π/2 / 3π/2 stagger the pairs so
# opposite pairs lift in phase (left-rear + right-front step
# together, then right-rear + left-front, repeating).
#
# Pair index → leg slots in _leg_pivots:
#   0 = rear (d/e in vanilla; pair phase 0)
#   1 = mid-back (f/g; π)
#   2 = mid-front (h/i; π/2)
#   3 = front (j/m; 3π/2)
#
# Vanilla pseudocode:
#   f11..f14 = -cos(walkDist * 0.6662 * 2 + offset[i]) * 0.4 * speed
#   f15..f18 = |sin(walkDist * 0.6662 + offset[i])| * 0.4 * speed
#   leg.e += f1{1..4}  (yaw)  — left leg adds, right subtracts (anti-phase)
#   leg.f += f1{5..8}  (roll) — left adds POSITIVE (lift toward zero from
#                                 vanilla's -PI/4 droop); in Godot's
#                                 positive-droop space, left leg gets
#                                 SUBTRACTED so the result lifts up.
func _advance_walk_animation(delta: float) -> void:
	if _leg_pivots.is_empty():
		return
	var sp_sq: float = velocity.x * velocity.x + velocity.z * velocity.z
	var speed: float = sqrt(sp_sq) if sp_sq > 0.0001 else 0.0
	var target_amount: float = clampf(speed / _AI_WALK_SPEED, 0.0, 1.0)
	# Lerp toward target so sudden stops decay smoothly into idle.
	_walk_anim_amount = lerpf(_walk_anim_amount, target_amount, minf(8.0 * delta, 1.0))
	# Vanilla walkDistance ≈ horizontal_speed × elapsed_seconds (the in-
	# game accumulator amplifies per-tick motion × 4 then * 0.4 smooth,
	# which simplifies to ~1.0 × speed per second). Mirror that with
	# `speed × delta` so leg cadence scales with the spider's actual
	# velocity, not just amount.
	_walk_dist += speed * delta
	var yaw_phase: float = _walk_dist * _WALK_FREQ * 2.0
	var roll_phase: float = _walk_dist * _WALK_FREQ
	var pair_offsets: Array = [0.0, PI, PI * 0.5, PI * 1.5]
	for pair_idx in range(4):
		var off: float = pair_offsets[pair_idx]
		var yaw_delta: float = -cos(yaw_phase + off) * _LEG_ANIM_AMPLITUDE * _walk_anim_amount
		var roll_delta: float = (
			absf(sin(roll_phase + off)) * _LEG_ANIM_AMPLITUDE * _walk_anim_amount
		)
		var l_idx: int = pair_idx * 2
		var r_idx: int = l_idx + 1
		# Left: base_yaw + cos_delta. Roll - sin_delta (lift up from
		# Godot's positive droop — vanilla adds POSITIVE to its negative
		# droop, equivalent under our axis convention).
		var l_yaw: float = _leg_base_yaws[l_idx] + yaw_delta
		var l_roll: float = _leg_base_rolls[l_idx] - roll_delta
		_leg_pivots[l_idx].transform.basis = (
			Basis(Vector3.UP, l_yaw) * Basis(Vector3.BACK, l_roll)
		)
		# Right: mirror — yaw subtracts the same delta, roll adds.
		var r_yaw: float = _leg_base_yaws[r_idx] - yaw_delta
		var r_roll: float = _leg_base_rolls[r_idx] + roll_delta
		_leg_pivots[r_idx].transform.basis = (
			Basis(Vector3.UP, r_yaw) * Basis(Vector3.BACK, r_roll)
		)


# --- SFX overrides ---
# Vanilla EntitySpider sound triplet — `be.java::d()` (hurt) and `f_()`
# (idle/say) both return "mob.spider" so play_spider_hurt is wired in
# sfx.gd to the SAY pool. `f()` returns "mob.spiderdeath".
func _play_idle_sfx() -> void:
	SFX.play_spider_say(global_position)


func _play_hurt_sfx() -> void:
	SFX.play_spider_hurt(global_position)


func _play_death_sfx() -> void:
	SFX.play_spider_death(global_position)
