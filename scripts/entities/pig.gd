class_name Pig
extends "res://scripts/entities/mob_base.gd"

# Vanilla Alpha 1.2.6 EntityPig (op.java, entity id 90). First real mob
# — chosen as the M1 starter because it's the simplest possible mob:
#   * Passive (no targeting / no attack path to wire)
#   * Single drop (0-2 raw pork)
#   * No biome / light gating
#   * No special mechanics (no climbing, fuse, splitting, etc.)
#
# This M1a cut is the visual + drop layer only. PassiveAI (wander + flee
# on hit) lands in M1b. For now the pig just stands there like the
# test_mob, falls under gravity, takes damage with knockback, and dies
# dropping raw pork.
#
# Cube-stack model — procedural BoxMesh children for body + head + 4
# legs. Pink unshaded material so the silhouette reads at any light
# level. Will be swapped for a textured GLTF / per-mob spritesheet
# once asset pipeline lands (Phase M8 polish).

const _BODY_COLOR := Color(0.95, 0.7, 0.7, 1.0)  # vanilla pinkish
const _SNOUT_COLOR := Color(0.75, 0.5, 0.5, 1.0)  # darker pink for snout cue
const _SADDLE_COLOR := Color(0.5, 0.3, 0.15, 1.0)  # leather brown

# Vanilla pig texture sheet — 64×32, extracted from
# vendor/alpha-1.2.6-src/client.jar:/mob/pig.png. ModelQuadruped
# (dc.java) lays out head + body + 4 legs in this sheet via the cube-
# unfold pattern that MobCube.build_textured_cube emits.
const _PIG_TEXTURE_PATH: String = "res://assets/textures/mob/pig.png"
const _PIG_TEXTURE_SIZE: Vector2i = Vector2i(64, 32)
# Vanilla saddle.png — same 64×32 layout as pig.png with the saddle
# drawn into the body's UV region and alpha=0 everywhere else. Vanilla
# `hp.java::a(op, n=0)` swaps this texture in for a SECOND model pass
# scaled-up by 0.5/16 m to overlay the base body without z-fighting.
const _SADDLE_TEXTURE_PATH: String = "res://assets/textures/mob/saddle.png"
# Saddle cube is INFLATED by this many m on each side so it overlays
# the base body geometry without sharing depth. Vanilla cj(0.5f)
# passes 0.5 as the inflate-pixel arg to ka.addCube (`ij.java`
# constructor `f2` parameter) → 0.5/16 = 0.03125 m per side.
const _SADDLE_INFLATE: float = 0.5 / 16.0

# Vanilla pixel-size constants per `ij.java` (the actual EntityPig model
# in a1.2.6 — NOT dc.java/ModelQuadruped which is unused for pigs). For
# n=6 (pig's leg-height arg, passed via cj.java which extends ij):
#   head  d: cube 8×8×8  @ tex (0,  0)
#   body  e: cube 10×16×8 @ tex (28, 8)  — rotated PI/2 around X
#   legs f/g/h/i: cube 4×6×4 @ tex (0, 16)  — all four share same UV
# Body is MUCH bigger than ModelQuadruped's body (10×16×8 vs 8×12×4)
# and legs are HALF the height (6 vs 12). This is why earlier attempts
# with dc dimensions produced a tiny body on stilts.
const _PIXEL_TO_METER: float = 1.0 / 16.0
const _HEAD_CUBE_PX: Vector3i = Vector3i(8, 8, 8)
const _BODY_CUBE_PX: Vector3i = Vector3i(10, 16, 8)
const _LEG_CUBE_PX: Vector3i = Vector3i(4, 6, 4)
const _HEAD_TEX_ORIGIN: Vector2i = Vector2i(0, 0)
const _BODY_TEX_ORIGIN: Vector2i = Vector2i(28, 8)
const _LEG_FRONT_TEX_ORIGIN: Vector2i = Vector2i(0, 16)
const _LEG_REAR_TEX_ORIGIN: Vector2i = Vector2i(0, 16)

# Per-vanilla op.java: health 10 (`o = 10` via parent EntityAnimal default).
# Body cube_px (8, 12, 4) is "8 wide × 12 tall × 4 deep" in the vanilla
# MODEL coordinate frame — a vertical column whose UV unfold matches
# the column's faces. Vanilla `RenderQuadruped` then applies a -PI/2 X
# rotation in `preRenderCallback` to lay this column horizontal so the
# 12-axis becomes the pig's front-to-back length. We replicate that
# rotation here on the body MeshInstance3D itself.
#
# After -PI/2 X rotation (right-hand rule, +Y → -Z = Godot forward):
#   vanilla cube TOP face (+Y, 8×4 UV)   → pig FRONT face (-Z)
#   vanilla cube BOTTOM face (-Y, 8×4)   → pig BACK face (+Z)
#   vanilla cube FRONT face (+Z, 8×12)   → pig TOP face (+Y, visible from above)
#   vanilla cube BACK face (-Z, 8×12)    → pig BOTTOM face (-Y)
#   vanilla cube LEFT/RIGHT (±X, 4×12)   → pig LEFT/RIGHT (unchanged)
# This puts the LARGEST UV region (8×12) on the largest visible face
# (top of pig), as intended by vanilla.
#
# Post-rotation world-space extents (used for collision AABB + leg
# placement). Body cube 10×16×8 after -PI/2 X rotation becomes
# 0.625 × 0.5 × 1.0 m. Legs are short stubs at 6 px tall (vanilla).
const _BODY_SIZE := Vector3(0.625, 0.5, 1.0)
const _HEAD_SIZE := Vector3(0.5, 0.5, 0.5)
const _LEG_SIZE := Vector3(0.25, 0.375, 0.25)
# Body center Y. Per `ij.java` body pivot (0, 11, 2) + cube_y_local
# (-10 to 6) → post-rotation+translation world Y range 0.375 to 0.875,
# so body center at Y = 0.625. Replaces the earlier 0.875 which floated
# the body 0.25 m above the legs and made the pig look top-heavy.
const _BODY_Y_OFFSET: float = 0.625
# Head center: vanilla head pivot (0, 12, -6) + cube_local (-4,-4,-8)..
# (4,4,0) → world Y range 0.5..1.0 (center 0.75), Z range -0.875..
# -0.375 (center -0.625). Head sticks forward and up from body, no
# overlap with body's Z range so no z-fighting.
const _HEAD_OFFSET: Vector3 = Vector3(0, 0.75, -0.625)
# Leg pivot Y — at the leg's CENTER. _add_leg interprets hip_pos.y as
# the leg-cube center; with leg height 0.375 m, center = 0.1875 puts
# the leg cube at Y range 0 (feet) .. 0.375 (top, level with body
# bottom). Earlier 0.375 with 12-px legs gave Y range 0..0.75.
const _LEG_Y_OFFSET: float = 0.1875

# Walk-animation constants — vanilla `ij.java::a()` lines 47-50.
# Per-leg rotation: cos(walkDist × 0.6662 [+PI]) × 1.4 × limbAmount.
# All four legs swing at amplitude 1.4 rad (~80° peak). Diagonal gait:
# front-right + rear-left in phase (`cos(p)`), anti-phase to front-left
# + rear-right (`cos(p+PI)`). We use sin instead of cos (90° phase
# shift, identical loop).
#
# DEVIATION: _WALK_DIST_SCALE is non-vanilla. Vanilla's 0.6662 is
# "rad per block of walkDist", which at our 0.5 m/s effective walk
# speed gives ~19-second cycles (basically invisible). The ×12 scale
# maps motion → phase rate so cycles are ~1.5 s at walk, ~0.6 s at
# flee — perceptually correct for a stylized pig. Original phase
# math is preserved by leaving _WALK_FREQ at vanilla's 0.6662.
#
# _WALK_ANIM_LERP_PER_SEC mirrors vanilla EntityLiving.h_ which lerps
# `limbSwingAmount` toward the target by 0.4/tick × 20 TPS = 8/sec.
# Without smoothing, bumping the pig into a wall (velocity → 0 from
# collision) snaps `limb_amount` to 0 and the legs flicker between
# full swing and rest pose every frame.
const _WALK_FREQ: float = 0.6662
const _WALK_DIST_SCALE: float = 12.0
const _WALK_ANIM_LERP_PER_SEC: float = 8.0
const _LEG_AMPLITUDE_REAR: float = 1.4
const _LEG_AMPLITUDE_FRONT: float = 1.4
# Step-SFX stride — vanilla emits play_pig_step every ~2 m of horizontal
# travel; we accumulate walk_dist (= horizontal speed × delta) and emit
# when it crosses the threshold. Distance carries over between strides.
const _STEP_STRIDE: float = 1.6

# Idle SFX (mob.pig) — vanilla `lw.java` rolls `1/this.b()` per random
# tick. Per `ak.java::b() = 120`, that's 1/120 per random tick. Random
# ticks fire at ~10 Hz, so idle SFX averages once every 12 s. We track
# elapsed time + roll on a fixed interval to keep this self-contained.
const _IDLE_SFX_ROLL_INTERVAL: float = 0.1  # 10 Hz roll, matches vanilla rate
const _IDLE_SFX_CHANCE: float = 1.0 / 120.0  # vanilla's 1/120 odds per roll

# Wander AI — direct port of vanilla `fc.java::b_()` (EntityCreature)
# + `ak.java::a(x,y,z)` (EntityAnimal cell-scoring) + `hf.java::b_()`
# (idle yaw twitch from EntityLiving fallback). Runs at 20 TPS via the
# tick accumulator so probabilities (1/80, 1/100, 5%) match vanilla
# per-tick rates rather than per-frame.
#
# Each tick with NO active wander target:
#   * 1/80 chance: pick a new target by sampling 10 random cells in a
#     13×7×13 box centered on the mob, scored via grass-preference.
#     Animals prefer GRASS (score 10) over anything else (score
#     `lightValue - 0.5`) — `ak.java::a(int, int, int)`.
#   * Else: 5% chance to apply a random yaw twitch (-PI/18..+PI/18 rad)
#     mirroring vanilla `hf.java::b_()`'s `this.aj` random nudge.
#
# Each tick WITH a target:
#   * Walk toward it at _WALK_SPEED m/s, facing the heading.
#   * On arrival (within _ARRIVE_DIST), clear the target.
#   * Else 1/100 chance to abandon (vanilla `bd.nextInt(100) == 0`).
#
# DEVIATIONS from Alpha:
#   1. Vanilla also re-picks targets while walking (`bd.nextInt(20)`
#      branch in `fc.b_()` line 32); we only pick when no active path.
#      Reduces A* invocations without changing reachability.
#   2. FLEE-on-hit is OUR addition (not in Alpha) — `op.java` doesn't
#      override `a(lw, int)`. Triggered by `take_damage` and overrides
#      the wander tick for 60 ticks (3 s) at 2× speed. Tagged so this
#      stays the single non-vanilla AI behavior.
# Previously-deviations now matching vanilla:
#   * A* pathfinding via Pathfinder.find_path (algorithmic port of
#     `bt.findPath`) — mobs route around obstacles, no straight-line
#     stuck states.
#   * Yaw delta clamped to ±30°/tick (vanilla fc.b_() lines 89-93) so
#     turns are gradual instead of snap-to-face.
const _AI_TICK_DT: float = 1.0 / 20.0  # vanilla 20 TPS
const _AI_WANDER_X_RANGE: int = 6  # ±6 cells (rand[0..12] - 6)
const _AI_WANDER_Y_RANGE: int = 3
const _AI_NEW_TARGET_DENOM: int = 80  # 1/80 chance per tick
const _AI_ABANDON_DENOM: int = 100  # 1/100 chance per tick
const _AI_YAW_TWITCH_CHANCE: float = 0.05
const _AI_YAW_TWITCH_RANGE: float = PI / 18.0  # ±10°, vanilla aj * (PI/180)
const _AI_SCORE_GRASS: float = 10.0
const _AI_SCORE_LIGHT_OFFSET: float = -0.5
const _AI_ARRIVE_DIST: float = 0.7
const _AI_WALK_SPEED: float = 0.7
# Vanilla fc.b_() lines 89-93: yaw delta toward target heading is
# clamped to ±30° per tick (PI/6 rad). Gives the gradual head-turn
# that makes path-following look organic instead of robotic snap-to-
# face. At 20 TPS that's 600°/sec max turn rate — plenty fast for
# pigs but slow enough to read as a real turn.
const _AI_MAX_YAW_STEP: float = PI / 6.0
# Vanilla `fc.b_()` line 18: f2 = 16.0 — pathfind search radius.
# We also pass this as the max cumulative cost so A* gives up early
# on impossible long paths rather than thrashing for 200 iters.
const _AI_PATHFIND_RADIUS: float = 16.0
const _AI_PATHFIND_MAX_ITERS: int = 200
# Flee-on-hit (non-vanilla) — survives 60 ticks at 2× walk speed.
const _AI_FLEE_TICKS: int = 60
const _AI_FLEE_SPEED: float = 1.4
# Ridden walk speed (modern-MC steering, not Alpha — Alpha 1.2.6 pig
# riding is passive: pig wanders its own AI direction). 6.0 m/s puts
# the saddled pig slightly above player sprint (~5.6 m/s) — pig is a
# genuine speed upgrade over running. Modern MC's carrot-on-stick
# boost peaks around 7 m/s; we don't have that mechanic so 6.0 is
# the steady rate.
const _RIDDEN_WALK_SPEED: float = 6.0
# Saddle seat Y offset above pig origin. Body top is at
# _BODY_Y_OFFSET + _BODY_SIZE.y/2 = 0.875; +0.05 for the saddle
# thickness + slight clearance so the rider doesn't z-fight the body.
const _SADDLE_SEAT_Y: float = 0.93
# Jump impulse for stepping up a block edge. Vanilla `hf.F()` sets
# `aA = 0.42` (per-tick velocity = 8.4 m/s) which clears 2+ blocks —
# overkill for a 1-block step. We use 6.0 m/s, peak ~1.1 m, just
# enough to clear a single-block step. Triggered in _tick_walk_path
# when the next path node is at higher Y than the pig's current cell.
const _AI_JUMP_VELOCITY: float = 6.0
# Horizontal speed boost during step-up jumps. Normal walk × air time
# doesn't cover the 1-block gap — boost to ~2 m/s gets the mob across.
const _AI_STEP_BOOST_SPEED: float = 2.0

# Saddle field — vanilla op.java:6 `public boolean a = false`. Persisted
# in NBT under "Saddle" (op.java:17/22). When true, the pig drops a
# saddle item on death and (eventually) lets the player mount it.
var saddled: bool = false

# Leg-mesh refs for walk animation. Populated by _build_model.
var _leg_front_l: MeshInstance3D
var _leg_front_r: MeshInstance3D
var _leg_rear_l: MeshInstance3D
var _leg_rear_r: MeshInstance3D
# Saddle visual — small darker box on the pig's back; visibility toggled
# by `saddled`.
var _saddle_mesh: MeshInstance3D
var _walk_dist: float = 0.0
# Smoothed limb-swing amount (vanilla EntityLiving.h_'s limbSwingAmount).
# Lerps toward `clamp(speed / walk_speed, 0..1)` at _WALK_ANIM_LERP_PER_SEC.
# Persisting across frames + lerp-toward-target = no leg flicker when
# velocity oscillates (wall collisions, friction decay, etc.).
var _walk_anim_amount: float = 0.0
var _step_accum: float = 0.0
var _idle_sfx_accum: float = 0.0

var _ai_tick_accum: float = 0.0
# Remaining path nodes (cell coords). Empty = no active path. The mob
# walks toward `_ai_path[0]` each tick; on arrival, pop_front; when
# empty, target reached.
var _ai_path: Array = []
var _ai_flee_ticks_remaining: int = 0
var _ai_flee_from: Vector3 = Vector3.ZERO
# Mounted player (CharacterBody3D Player), or null if no rider. While
# set, AI is suspended and pig velocity is driven by rider's WASD input.
var _rider: Node3D = null


# MobBase environment overrides — pig BB total height = body + legs =
# 0.5 + 0.375 = 0.875 m. Eye height ~0.7 m (head sits at top of body).
# Width = body X axis (0.625 m); used by mob_base's fire-billboard
# stack to scale the flame sprites per vanilla `entity.width × 1.4`.
func _get_body_height() -> float:
	return _BODY_SIZE.y + _LEG_SIZE.y


func _get_eye_height() -> float:
	return 0.7


func _get_body_width() -> float:
	return _BODY_SIZE.x


func _ready() -> void:
	max_health = 10
	drop_item_id = Items.RAW_PORKCHOP
	drop_count_min = 0
	drop_count_max = 2
	_build_collision_shape()
	_build_model()
	super._ready()


# Drives AI by accumulating delta and firing _ai_tick at vanilla's 20
# TPS — keeps the 1/80, 1/100, 5% rolls equivalent to vanilla regardless
# of physics framerate. When ridden, AI is suspended and velocity is
# driven by `_tick_ridden_motion` reading WASD input from the rider —
# we run a custom physics path (gravity + move_and_slide, NO friction)
# instead of super so the rider's per-frame velocity isn't decayed.
func _physics_process(delta: float) -> void:
	if _dying:
		super._physics_process(delta)  # super handles dying short-circuit
		return
	if _rider != null:
		_tick_ridden_motion()
		if not is_on_floor():
			velocity.y = maxf(velocity.y + GRAVITY * delta, TERMINAL_VELOCITY)
		elif velocity.y < 0.0:
			velocity.y = 0.0
		move_and_slide()
		return
	super._physics_process(delta)
	_ai_tick_accum += delta
	while _ai_tick_accum >= _AI_TICK_DT:
		_ai_tick_accum -= _AI_TICK_DT
		_ai_tick()


# Modern-MC steering: pig follows rider's yaw, WASD drives motion, jump
# fires a vertical impulse. Not Alpha-faithful — Alpha pigs wander their
# own AI direction even when ridden — but makes riding actually useful.
# Yaw is set FROM the rider so the pig faces wherever the player's
# camera is pointing; WASD then maps into pig-local axes.
func _tick_ridden_motion() -> void:
	if _rider == null:
		return
	rotation.y = _rider.rotation.y
	var fwd: Vector3 = -global_transform.basis.z
	var rt: Vector3 = global_transform.basis.x
	var motion: Vector3 = Vector3.ZERO
	if Input.is_action_pressed("move_forward"):
		motion += fwd
	if Input.is_action_pressed("move_back"):
		motion -= fwd
	if Input.is_action_pressed("move_left"):
		motion -= rt
	if Input.is_action_pressed("move_right"):
		motion += rt
	if motion.length_squared() > 0.001:
		motion = motion.normalized() * _RIDDEN_WALK_SPEED
		velocity.x = motion.x
		velocity.z = motion.z
	else:
		# No input — stop immediately. We skipped MobBase's friction in
		# the ridden path so nothing else decays velocity; without this
		# zero-on-release the pig would coast indefinitely at 6 m/s.
		velocity.x = 0.0
		velocity.z = 0.0
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = _AI_JUMP_VELOCITY


# Vanilla op.java::a(eb) — right-click handler. Saddles pig if held
# item is SADDLE, else mounts/dismounts.
func mount(player: Node3D) -> bool:
	if _rider != null or not saddled:
		return false
	_rider = player
	# Suspend AI motion when ridden; player input drives velocity.
	_ai_path.clear()
	_ai_flee_ticks_remaining = 0
	if player.has_method("set_mount"):
		player.set_mount(self)
	return true


func dismount() -> void:
	if _rider == null:
		return
	var p: Node3D = _rider
	_rider = null
	if p.has_method("set_mount"):
		p.set_mount(null)


# One vanilla-equivalent tick. Mirrors fc.b_() structure: target?, walk
# along it; no target? maybe pick one, else idle yaw twitch. Flee
# override pre-empts (our non-vanilla addition).
func _ai_tick() -> void:
	if _ai_flee_ticks_remaining > 0:
		_ai_flee_ticks_remaining -= 1
		_tick_flee()
		return
	if not _ai_path.is_empty():
		_tick_walk_path()
	else:
		_tick_idle()


# Walk toward the next path node. Vanilla `fc.b_()` lines 65-75 pop
# path nodes within `aP * 2` (bb-doubled radius) — we use a fixed
# 0.7 m. On arrival, pop_front so we advance to the next node next
# tick; if the path is now empty, we're at the goal.
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
	# Vanilla `bd.nextInt(100) == 0` per-tick abandon-entire-path.
	if randi() % _AI_ABANDON_DENOM == 0:
		_ai_path.clear()
		return
	var dir: Vector3 = to_node.normalized()
	# Step-up: if next path node is HIGHER than the pig's current cell,
	# jump AND boost horizontal velocity. Without the boost, walk speed
	# × air time can't cover the 1-block gap. Mirrors vanilla `fc.b_()`
	# line 105 (`ao2.b - n8 > 0` → jump). Down-steps use gravity.
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
	# Vanilla `bd.nextInt(80) == 0` per-tick new-target roll.
	if randi() % _AI_NEW_TARGET_DENOM == 0:
		if _pick_wander_target():
			return
	# Vanilla hf.b_() yaw twitch fallback (5%/tick).
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


# Vanilla `fc.b_()` lines 40-54: best of 10 random samples within
# (±6, ±3, ±6) cells. After picking, vanilla calls `bt.findPath` to
# build the A* path; we do the same via Pathfinder. Returns true if a
# real reachable path was found.
func _pick_wander_target() -> bool:
	var best_score: float = -99999.0
	var best_cell: Vector3i = Vector3i.ZERO
	var found: bool = false
	var origin: Vector3i = Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y)),
		int(floor(global_position.z)),
	)
	for _i in range(10):
		# Vanilla `nextInt(13) - 6` → [-6, +6]. Y range 7 → [-3, +3].
		var x: int = origin.x + (randi() % (2 * _AI_WANDER_X_RANGE + 1)) - _AI_WANDER_X_RANGE
		var y: int = origin.y + (randi() % (2 * _AI_WANDER_Y_RANGE + 1)) - _AI_WANDER_Y_RANGE
		var z: int = origin.z + (randi() % (2 * _AI_WANDER_X_RANGE + 1)) - _AI_WANDER_X_RANGE
		var cell: Vector3i = Vector3i(x, y, z)
		# Prefilter unreachable goals. Vanilla `ak.a(x,y,z)` doesn't
		# check walkability; it returns 14.5 for sky-exposed AIR cells
		# and only 10 for grass cells, so the unfiltered pick almost
		# always lands on a HIGH-AIR cell (unreachable). Vanilla's
		# pathfinder is lenient and partial-paths somewhere close; ours
		# returns [] on unreachable goals. Without this prefilter the
		# pig sits idle ~95% of the time, never walking.
		if not Pathfinder.is_walkable(_chunk_manager, cell):
			continue
		var score: float = _score_cell(x, y, z)
		if score > best_score:
			best_score = score
			best_cell = cell
			found = true
	if not found:
		return false
	# Vanilla `this.a = this.as.a(this, n3, n2, n4, 10.0f)` — pathfind
	# to the chosen cell. We use `Pathfinder.find_path` (A* over
	# voxels, matching vanilla `bt.findPath` algorithmically).
	if _chunk_manager == null:
		return false
	_ai_path = Pathfinder.find_path(
		_chunk_manager, origin, best_cell, _AI_PATHFIND_RADIUS, _AI_PATHFIND_MAX_ITERS
	)
	return not _ai_path.is_empty()


# Vanilla `ak.java::a(int, int, int)` — animals prefer grass (score 10)
# over anything else (score = lightValue - 0.5).
func _score_cell(x: int, y: int, z: int) -> float:
	if _chunk_manager == null:
		return 0.0
	var below: int = _chunk_manager.get_world_block(Vector3i(x, y - 1, z))
	if below == Blocks.GRASS:
		return _AI_SCORE_GRASS
	# Vanilla uses cell-light (max of sky/block); skylight alone is a
	# close enough proxy for daytime spawns + lit caves.
	var light: int = _chunk_manager.get_world_sky_light(Vector3i(x, y, z))
	return float(light) + _AI_SCORE_LIGHT_OFFSET


# Rotate the pig around Y toward the walk-direction heading, but clamp
# the yaw delta to ±_AI_MAX_YAW_STEP per call (vanilla fc.b_() lines
# 89-93). At 20 TPS this gives a max turn rate of 600°/sec — quick
# enough to react to direction changes but slow enough to read as a
# real turn instead of a snap.
#
# Perf: target yaw via atan2 (no Basis rebuild like look_at would do).
# Convention: Godot forward = -Z. For velocity (vx, vz), entity's -Z
# basis should point in (vx, vz) — so θ = atan2(-vx, -vz).
func _face_walk_direction() -> void:
	var vx: float = velocity.x
	var vz: float = velocity.z
	if vx * vx + vz * vz < 0.0025:  # < 0.05 m/s — don't snap for jitter
		return
	var target_yaw: float = atan2(-vx, -vz)
	# Wrap angular delta to [-PI, PI) so we always turn the short way
	# (vanilla's two while-loops in fc.b_() lines 84-88 do the same).
	var delta: float = wrapf(target_yaw - rotation.y, -PI, PI)
	delta = clampf(delta, -_AI_MAX_YAW_STEP, _AI_MAX_YAW_STEP)
	rotation.y += delta


# Non-vanilla flee-on-hit. Alpha pigs don't react to damage beyond the
# knockback shove (op.java has no attackEntityFrom override). Kept
# because it makes the mob feel responsive — flagged as a deliberate
# deviation from strict Alpha behavior.
func take_damage(
	amount: int, knockback_dir: Vector3 = Vector3.ZERO, knockback_strength: float = 1.0
) -> bool:
	var landed: bool = super.take_damage(amount, knockback_dir, knockback_strength)
	if landed and knockback_dir.length_squared() > 0.0001:
		_ai_flee_ticks_remaining = _AI_FLEE_TICKS
		_ai_flee_from = global_position - knockback_dir.normalized()
		# Drop the active path so flee doesn't fight wander direction.
		_ai_path.clear()
	return landed


func _process(delta: float) -> void:
	super._process(delta)
	_advance_walk_animation(delta)
	_roll_idle_sfx(delta)
	if _saddle_mesh != null:
		_saddle_mesh.visible = saddled
	if _rider != null:
		_update_rider_transform()


# Two-shape collision (MobBase helpers). Body capsule = physics-only
# (centered on origin, symmetric around Y → no rotation-induced
# stuck-clipping). Head Area3D = hit-only, sticks forward over the
# snout so arrow + sword hits land on the visually-protruding head.
#
# Body capsule: radius = _BODY_SIZE.x / 2 = 0.3125, height covers
# body + legs (~0.875). Use 1.0 for a small vertical margin.
#
# Head box covers HEAD_OFFSET (0, 0.75, -0.625), an 8×8×8 px head cube
# (0.5 m). Box at the same position with a slight margin so edge
# hits register cleanly.
func _build_collision_shape() -> void:
	_build_body_capsule(_BODY_SIZE.x * 0.5, 1.0)
	_build_head_hit_area(Vector3(0.55, 0.55, 0.55), _HEAD_OFFSET)


# Vanilla pig model — head + body + 4 legs, each a UV-mapped cube
# sampling pig.png. Vanilla pig.png is 64×32 with the cube-unfold
# layout per ModelQuadruped (dc.java); MobCube.build_textured_cube
# emits the matching UV coords for each part.
func _build_model() -> void:
	var tex: Texture2D = load(_PIG_TEXTURE_PATH) as Texture2D
	var pig_mat: StandardMaterial3D = _make_textured_material(tex)
	# Body — build with VANILLA pixel dims (0.5×0.75×0.25 m, vertical
	# column) so the cube-unfold UV layout in MobCube matches the
	# texture's pixel rectangles 1:1. Then apply -PI/2 X rotation to
	# lay the column horizontal. This matches vanilla RenderQuadruped's
	# preRenderCallback rotation step.
	var body_mesh_size := Vector3(
		_BODY_CUBE_PX.x * _PIXEL_TO_METER,
		_BODY_CUBE_PX.y * _PIXEL_TO_METER,
		_BODY_CUBE_PX.z * _PIXEL_TO_METER
	)
	var body_mesh := MeshInstance3D.new()
	body_mesh.mesh = MobCube.build_textured_cube(
		body_mesh_size, _PIG_TEXTURE_SIZE, _BODY_TEX_ORIGIN, _BODY_CUBE_PX, false
	)
	body_mesh.position = Vector3(0, _BODY_Y_OFFSET, 0)
	# -PI/2 around X (right-hand rule: +Y → -Z = Godot forward). Puts
	# vanilla's large 8×12 FRONT-face UV region on the pig's TOP face
	# (visible from above) and the small 8×4 TOP UV on the pig's FRONT
	# face (the chest, between head and body). Previously this was
	# +PI/2 which put the chest patch on the BACK face and the
	# top-of-pig UV on the BELLY — backwards by 180° around X.
	body_mesh.rotation = Vector3(-PI * 0.5, 0, 0)
	body_mesh.material_override = pig_mat
	add_child(body_mesh)
	# Head — build with vanilla 8×8×8 dims. Vanilla pig.png places the
	# face (eyes + snout) at the -Z BACK UV region (l, l+pw) in pixels
	# 8-16, y 8-16; black eye pixels at y=11, dark-pink nostrils at
	# y=13-14. After MobCube's vanilla-faithful UV mapping, those
	# pixels land on the cube's -Z face. Since the pig faces -Z
	# (Godot's forward axis), NO head rotation is needed — eyes are
	# already on the correct side. Earlier code had a 180° Y rotation
	# here that compensated for an INCORRECT old UV layout; now that
	# MobCube matches vanilla, the rotation flips eyes to the back.
	var head_size := Vector3(
		_HEAD_CUBE_PX.x * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.y * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.z * _PIXEL_TO_METER
	)
	var head_mesh := MeshInstance3D.new()
	head_mesh.mesh = MobCube.build_textured_cube(
		head_size, _PIG_TEXTURE_SIZE, _HEAD_TEX_ORIGIN, _HEAD_CUBE_PX, false
	)
	head_mesh.position = _HEAD_OFFSET
	head_mesh.material_override = pig_mat
	add_child(head_mesh)
	# 4 legs per vanilla ij.java pivot positions:
	# Vanilla `ij.java` (n=6) leg pivots — h/i are FRONT (close to head
	# at MODEL Z=-6), f/g are REAR (far at MODEL Z=+7). Earlier code had
	# the magnitudes swapped (using f/g's |7| for front and h/i's |5|
	# for rear) which placed front legs 1 px too far forward and rear
	# legs 1 px too far forward too.
	#   front-right h: MODEL (-3, 18, -5) → Godot (+0.1875, hip, -0.3125)
	#   front-left  i: MODEL ( 3, 18, -5) → Godot (-0.1875, hip, -0.3125)
	#   rear-right  f: MODEL (-3, 18,  7) → Godot (+0.1875, hip, +0.4375)
	#   rear-left   g: MODEL ( 3, 18,  7) → Godot (-0.1875, hip, +0.4375)
	# Godot X is sign-flipped from vanilla (vanilla -X = entity right
	# when facing +Z south = Godot +X when facing -Z forward). Godot Z
	# uses vanilla MODEL Z directly (vanilla's "front" Z=-5 stays at -Z
	# in Godot, which is Godot forward). Vanilla shares one 4×6 leg
	# texture across all four legs via `mirror=true` on LEFT pair.
	var leg_x: float = 3.0 / 16.0
	var leg_z_front: float = -5.0 / 16.0
	var leg_z_rear: float = 7.0 / 16.0
	_leg_front_r = _add_leg(
		Vector3(leg_x, _LEG_Y_OFFSET, leg_z_front), pig_mat, _LEG_FRONT_TEX_ORIGIN, false
	)
	_leg_front_l = _add_leg(
		Vector3(-leg_x, _LEG_Y_OFFSET, leg_z_front), pig_mat, _LEG_FRONT_TEX_ORIGIN, true
	)
	_leg_rear_r = _add_leg(
		Vector3(leg_x, _LEG_Y_OFFSET, leg_z_rear), pig_mat, _LEG_REAR_TEX_ORIGIN, false
	)
	_leg_rear_l = _add_leg(
		Vector3(-leg_x, _LEG_Y_OFFSET, leg_z_rear), pig_mat, _LEG_REAR_TEX_ORIGIN, true
	)
	# Saddle overlay — vanilla `hp.java::a(op, n=0)` renders the whole
	# pig model a SECOND time with saddle.png swapped in, scaled-up by
	# 0.03125 m per side. saddle.png has alpha=0 outside the saddle
	# region so head/legs etc. are transparent; the saddle itself
	# appears on the body's back. Built as a body-shaped cube inflated
	# by _SADDLE_INFLATE, sharing pig.png's body UV layout (the saddle
	# texture intentionally maps to the same body region as pig.png).
	var saddle_tex: Texture2D = load(_SADDLE_TEXTURE_PATH) as Texture2D
	var saddle_mat: StandardMaterial3D = _make_textured_material(saddle_tex)
	saddle_mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	var saddle_size: Vector3 = body_mesh_size + Vector3.ONE * (_SADDLE_INFLATE * 2.0)
	_saddle_mesh = MeshInstance3D.new()
	_saddle_mesh.mesh = MobCube.build_textured_cube(
		saddle_size, _PIG_TEXTURE_SIZE, _BODY_TEX_ORIGIN, _BODY_CUBE_PX, false
	)
	_saddle_mesh.position = Vector3(0, _BODY_Y_OFFSET, 0)
	_saddle_mesh.rotation = Vector3(-PI * 0.5, 0, 0)
	_saddle_mesh.material_override = saddle_mat
	add_child(_saddle_mesh)
	_saddle_mesh.visible = false


# Build a textured leg with its rotation pivot at the HIP (top) so
# walk-anim rotation swings the foot forward without clipping.
func _add_leg(
	hip_pos: Vector3, mat: StandardMaterial3D, tex_origin: Vector2i, mirror: bool
) -> MeshInstance3D:
	var pivot := Node3D.new()
	var leg_size := Vector3(
		_LEG_CUBE_PX.x * _PIXEL_TO_METER,
		_LEG_CUBE_PX.y * _PIXEL_TO_METER,
		_LEG_CUBE_PX.z * _PIXEL_TO_METER
	)
	# Hip Y = leg_y_offset + half-height so rotation pivot is at top of leg.
	pivot.position = Vector3(hip_pos.x, hip_pos.y + leg_size.y * 0.5, hip_pos.z)
	add_child(pivot)
	var mi := MeshInstance3D.new()
	mi.mesh = MobCube.build_textured_cube(
		leg_size, _PIG_TEXTURE_SIZE, tex_origin, _LEG_CUBE_PX, mirror
	)
	mi.position = Vector3(0, -leg_size.y * 0.5, 0)
	mi.material_override = mat
	pivot.add_child(mi)
	return mi


# Solid-color part (for saddle overlay only). Different from leg/body
# meshes since the saddle isn't on the pig.png sheet — defer to M8.
func _add_solid_part(size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.position = pos
	mi.material_override = mat
	add_child(mi)
	return mi


# Textured material — vanilla pig.png with nearest-neighbor filter so
# the pixel art reads crisply at all distances. Unshaded so the
# hurt-flash override (red tint via MobBase._apply_hurt_flash) hits
# every part uniformly without needing to compose with lighting.
func _make_textured_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	return mat


# Vanilla `ij.java::a()` — leg rotation = sin(walkDist × 0.6662 [+PI])
# × 1.4 × limbSwingAmount. Diagonal gait (FR+RL in phase, FL+RR
# anti-phase). Front pair anti-phase to rear pair.
func _advance_walk_animation(delta: float) -> void:
	# Perf: direct sqrt vs Vector2 allocation.
	var vx: float = velocity.x
	var vz: float = velocity.z
	var sp_sq: float = vx * vx + vz * vz
	var speed: float = sqrt(sp_sq) if sp_sq > 0.0001 else 0.0
	# Vanilla EntityLiving.h_ lerps limbSwingAmount toward
	# clamp(motion_magnitude, 0..1) at 0.4/tick. Smoothing prevents
	# leg flicker when velocity oscillates (wall bumps, friction
	# transitions). Frame-rate independent: lerp_t = rate * delta.
	var target_amount: float = clampf(speed / _AI_WALK_SPEED, 0.0, 1.0)
	var lerp_t: float = minf(_WALK_ANIM_LERP_PER_SEC * delta, 1.0)
	_walk_anim_amount = lerpf(_walk_anim_amount, target_amount, lerp_t)
	# Use the SMOOTHED amount to drive walkDist accumulation too — phase
	# rate scales with motion magnitude, so the legs slow/speed smoothly
	# instead of snapping when velocity changes.
	_walk_dist += _walk_anim_amount * delta * _WALK_DIST_SCALE
	var phase: float = _walk_dist * _WALK_FREQ
	var swing_a: float = sin(phase) * _LEG_AMPLITUDE_REAR * _walk_anim_amount
	var swing_b: float = sin(phase + PI) * _LEG_AMPLITUDE_REAR * _walk_anim_amount
	# Diagonal gait: FR + RL on swing_a, FL + RR on swing_b.
	if _leg_rear_l != null:
		_leg_rear_l.get_parent().rotation.x = swing_a
	if _leg_rear_r != null:
		_leg_rear_r.get_parent().rotation.x = swing_b
	if _leg_front_l != null:
		_leg_front_l.get_parent().rotation.x = swing_b
	if _leg_front_r != null:
		_leg_front_r.get_parent().rotation.x = swing_a
	# Step SFX — emit on stride crossings. Use raw speed so we don't
	# step when standing still even though _walk_anim_amount might be
	# decaying away from 0.
	_step_accum += speed * delta
	if _step_accum >= _STEP_STRIDE:
		_step_accum -= _STEP_STRIDE
		_play_block_step()


# Vanilla `lw.java::a_` plays the BLOCK's step sound (step.grass etc.),
# NOT a mob-specific clip. The mob/pig/step files exist but vanilla
# uses them for non-walk events (impact, etc.). Look up the block
# under the pig and route through the standard step-sound dispatch.
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


# Vanilla lw.java random-tick idle sound roll: 1/this.b() chance per
# random tick (every 50 ms for active entities). ak.java::b() = 120, so
# average idle interval is 6 s.
func _roll_idle_sfx(delta: float) -> void:
	_idle_sfx_accum += delta
	if _idle_sfx_accum < _IDLE_SFX_ROLL_INTERVAL:
		return
	_idle_sfx_accum -= _IDLE_SFX_ROLL_INTERVAL
	if randf() < _IDLE_SFX_CHANCE:
		_play_idle_sfx()


# Species SFX overrides — vanilla op.java `d` / `f_` / `f` return
# "mob.pig" / "mob.pig" / "mob.pigdeath". d and f_ map to the same say
# clip pool.
func _play_idle_sfx() -> void:
	SFX.play_pig_say(global_position)


func _play_hurt_sfx() -> void:
	SFX.play_pig_say(global_position)


func _play_death_sfx() -> void:
	SFX.play_pig_death(global_position)


# Vanilla op.java drops a saddle alongside the regular pork drops when
# the pig dies saddled (`isSaddled() ? dropItem(SADDLE) : noop`). We
# extend MobBase.die() to add this conditional drop before the base
# class clears the entity.
func die() -> void:
	if saddled and _chunk_manager != null:
		var item := DroppedItem.new()
		_chunk_manager.add_child(item)
		item.global_position = global_position + Vector3(0, 0.4, 0)
		item.setup(Items.SADDLE)
	super.die()


# Vanilla op.java::a(eb player) — right-click handler. If unsaddled
# and the player holds a saddle, consume the saddle. If already
# saddled, toggle mount/dismount.
func right_click_with(item_id: int, player: Node) -> bool:
	if not saddled and item_id == Items.SADDLE:
		saddled = true
		return true
	if saddled:
		if _rider == null:
			mount(player as Node3D)
		else:
			dismount()
		return true
	return false


# Called by pig.gd::_process each frame when ridden — places the player
# on the saddle. Direct global_position assignment (no physics) since
# Player._physics_process short-circuits while mounted.
func _update_rider_transform() -> void:
	if _rider == null:
		return
	_rider.global_position = global_position + Vector3(0.0, _SADDLE_SEAT_Y, 0.0)


func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	return mat


# Persistence — extends MobBase to include the saddle flag. Vanilla
# op.java NBT (lines 17-22) persists this as "Saddle" boolean.
func to_save_dict() -> Dictionary:
	var d: Dictionary = super.to_save_dict()
	d["saddled"] = saddled
	return d


func restore_from_dict(d: Dictionary) -> void:
	super.restore_from_dict(d)
	saddled = d.get("saddled", false)
