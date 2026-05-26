class_name Zombie
extends "res://scripts/entities/mob_base.gd"

# Vanilla Alpha 1.2.6 EntityZombie (`lk.java`). First hostile mob in
# the clone. Targets the nearest player within 16 m, pathfinds toward
# them with the existing Pathfinder voxel A*, and melee-attacks once
# adjacent. Burns in direct sunlight (vanilla EntityZombie.B()
# daylight-ignite, skylight ≥ 15 outdoors).
#
# Differences vs vanilla Alpha:
#   * No "armor" support — vanilla zombies have an armor inventory slot;
#     we just deal flat melee damage.
#   * No path randomization within the 20 m target radius — we
#     re-aim straight at the player every retarget interval.
#   * Drop count uses our standard 0-2 feather (Alpha 1.2.6 vanilla;
#     Beta 1.8 swapped to rotten flesh — we keep the Alpha drop).
#
# Visual model: vanilla 64×32 ModelBiped (Alpha `dc.java`) — head
# (8×8×8) + body (8×12×4) + 2 arms (4×12×4) + 2 legs (4×12×4). Walk
# anim swings legs only (`dc.java::a()`); ModelZombie (`ck.java`)
# overwrites the parent's arm swing with a locked horizontal pose +
# subtle idle sway. Attack animation is a Beta-era addition (Alpha's
# `eb.java::b_()` ticked swingProgress only on EntityPlayer; Beta
# moved swing handling to EntityLiving + EntityMob.attackEntity, so
# Beta zombies overhead-chomp on every melee hit).

const _ZOMBIE_TEXTURE_PATH: String = "res://assets/textures/mob/zombie.png"
const _ZOMBIE_TEXTURE_SIZE: Vector2i = Vector2i(64, 32)

# Vanilla model dimensions (mh.java ModelBiped). All in pixel-units;
# converted to meters via _PIXEL_TO_METER.
const _PIXEL_TO_METER: float = 1.0 / 16.0
const _HEAD_CUBE_PX: Vector3i = Vector3i(8, 8, 8)
const _BODY_CUBE_PX: Vector3i = Vector3i(8, 12, 4)
const _ARM_CUBE_PX: Vector3i = Vector3i(4, 12, 4)
const _LEG_CUBE_PX: Vector3i = Vector3i(4, 12, 4)

# UV origins per body part on the 64×32 vanilla ModelBiped sheet.
const _HEAD_TEX_ORIGIN: Vector2i = Vector2i(0, 0)
const _BODY_TEX_ORIGIN: Vector2i = Vector2i(16, 16)
const _ARM_RIGHT_TEX_ORIGIN: Vector2i = Vector2i(40, 16)
const _ARM_LEFT_TEX_ORIGIN: Vector2i = Vector2i(40, 16)  # mirrored at mesh time
const _LEG_RIGHT_TEX_ORIGIN: Vector2i = Vector2i(0, 16)
const _LEG_LEFT_TEX_ORIGIN: Vector2i = Vector2i(0, 16)  # mirrored

# World-space cube centers (feet at Y=0).
#   Legs: hip pivots at Y=0.75 (12 px × _PIXEL_TO_METER). Cube center
#     sits 6 px below pivot = 0.375. So leg cube center Y = 0.375.
#   Body: bottom at Y=0.75 (= leg top), 12 px tall → center Y = 1.125.
#   Head: bottom at Y=1.5 (= body top), 8 px tall → center Y = 1.75.
#   Arms: shoulder pivot at body top (Y=1.5). 12 px down → center
#     Y = 1.5 - 0.375 = 1.125. X offset = body half_width + arm half_width.
const _LEG_Y_OFFSET: float = 0.375
const _BODY_Y_OFFSET: float = 1.125
const _HEAD_Y_OFFSET: float = 1.75
const _ARM_Y_OFFSET: float = 1.125
const _ARM_X_OFFSET: float = 0.375  # body 4 px half + arm 2 px half = 6 px
const _LEG_X_OFFSET: float = 0.125  # legs sit at body's bottom corners

# Vanilla EntityZombie inherits EntityMonster.setSize(0.6, 1.8); we
# bump height to 1.95 to match the visual silhouette (body + legs +
# head = 0.5 + 0.75 + 0.75 = 2.0 m, close to 1.95). Hit-area covers
# the upper body + head separately so head-shots register.
const _BB_HEIGHT: float = 1.95
const _BB_WIDTH: float = 0.6

# AI cadence — 20 Hz tick rate matches vanilla integer-tick math.
const _AI_TICK_DT: float = 1.0 / 20.0

# Target acquisition window. Vanilla `nb.java` (EntityMob) targets the
# nearest player within 16 m via getClosestPlayerToEntity().
const _AI_DETECT_RADIUS: float = 16.0
# Vanilla path-give-up distance. If the player walks further than this
# during a chase, the zombie drops the path and re-rolls a target.
const _AI_ABANDON_RADIUS: float = 40.0
# How often to rebuild the path to a moving target. Re-pathing every
# tick is wasteful and produces jittery movement; every 1 s gives the
# zombie time to commit to the current path before re-aiming. Vanilla
# `ay.java::a(ao2)` rebuilds via `f` field every ~32 ticks.
const _AI_REPATH_TICKS: int = 20

# Melee. Vanilla `lk.java::e(ao2)` deals 3 HP on Normal difficulty.
const _AI_MELEE_RANGE: float = 1.8  # vanilla square-distance check ≤ 2.0² m
const _AI_MELEE_DAMAGE: int = 3
const _AI_MELEE_COOLDOWN_SEC: float = 0.5

# Walk speed. Vanilla `lk.java::A = 0.23F` per tick on horizontal = 4.6
# blocks/sec; our nq passive walks at 0.7. Zombies chase a bit faster
# to feel threatening.
const _AI_WALK_SPEED: float = 1.0
const _AI_JUMP_VELOCITY: float = 6.0
const _AI_STEP_BOOST_SPEED: float = 2.5
const _AI_MAX_YAW_STEP: float = PI / 4.0  # turn faster than passives
const _AI_PATHFIND_RADIUS: float = 24.0
const _AI_PATHFIND_MAX_ITERS: int = 300
const _AI_ARRIVE_DIST: float = 0.6

# Daylight burn. Vanilla EntityZombie.B() checks if sky-light at head
# Y is ≥ 15 (direct unobstructed sun) AND world is day AND not raining
# AND not in water. We approximate via WorldTime.is_day() + skylight
# read; rain not yet implemented.
const _AI_BURN_CHECK_INTERVAL: float = 1.0  # vanilla checks every tick; 1 s is plenty
const _AI_BURN_DURATION_SEC: float = 8.0  # vanilla `setFire(8)` (8 s)

# Walk-animation params — vanilla `dc.java::a()` (ModelBiped).
const _WALK_FREQ: float = 0.6662
const _WALK_DIST_SCALE: float = 12.0
const _WALK_ANIM_LERP_PER_SEC: float = 8.0
const _LEG_AMPLITUDE: float = 1.4  # vanilla: cos(phase) * 1.4 * walkAmount

# Vanilla Alpha zombie arm pose — `ck.java::a()`. Both arms locked to
# horizontal forward, parent ModelBiped's walk swing is OVERWRITTEN.
# Only motion is idle sway + (Beta) attack swing.
# Coord-system note: vanilla uses rotateAngleX = -π/2 because MC's Y
# axis is inverted (+Y points DOWN, limbs extend in +Y from the
# shoulder). Our pivot in Godot has the limb hanging in -Y, so rotating
# +π/2 around X aims it at -Z (Godot's "forward"). All pitch math is
# therefore SIGN-FLIPPED relative to `ck.java`: the chomp adds to pitch
# instead of subtracting.
const _ARM_HORIZONTAL_PITCH: float = PI * 0.5

# Idle pitch sway — vanilla `ck.java::20-21` (`sin(ageInTicks * 0.067) *
# 0.05`). 20 tps × 0.067 rad/tick = 1.34 rad/sec → ~4.7 s period;
# amplitude 0.05 rad ≈ 3°. We drop the vanilla yaw + Z-roll terms
# because (a) the roll axis is invisible under Godot's default YXZ
# rotation order (Z applies AFTER the X pitch, so it rotates around
# the limb's own forward axis — no visible tilt), and (b) the yaw
# sign convention differs between MC and Godot so the chomp ends up
# diverging instead of converging. Pitch-only is faithful to the
# silhouette without the sign-convention pitfalls.
const _IDLE_PITCH_FREQ_RPS: float = 20.0 * 0.067
const _IDLE_SWAY_AMP: float = 0.05

# Beta-style attack swing. `EntityLiving.swingItem()` set
# `isSwingInProgress=true`; `onLivingUpdate()` ticked `swingProgressInt`
# 0→6 (renderer reads `swingProgress = int/6`). EntityMob's melee path
# called `swingItem()` so Beta zombies DID animate their hit (Alpha did
# not — `b_()` was only overridden on EntityPlayer). 6 ticks at 20 tps
# = 300 ms swing duration. We drive it from a real-time accumulator
# rather than an int counter so the animation interpolates smoothly at
# 60 Hz process rate.
const _SWING_DURATION_SEC: float = 6.0 / 20.0
const _STEP_STRIDE: float = 1.4

# --- Visual node refs (rotated by walk animation) ---
var _head_mesh: MeshInstance3D
var _arm_l_pivot: Node3D
var _arm_r_pivot: Node3D
var _leg_l_pivot: Node3D
var _leg_r_pivot: Node3D

# --- AI state ---
var _ai_tick_accum: float = 0.0
var _ai_path: Array = []
var _ai_repath_counter: int = 0
var _ai_melee_cooldown_sec: float = 0.0
var _ai_burn_check_accum: float = 0.0
# Cached player ref (resolved lazily each AI tick — see _find_player).
var _ai_player_cache: Node3D = null

# --- Walk-anim state ---
var _walk_dist: float = 0.0
var _walk_anim_amount: float = 0.0
var _step_accum: float = 0.0
# Free-running clock for idle-sway oscillation. Matches vanilla
# `ageInTicks / 20` semantics.
var _age_seconds: float = 0.0
# Beta swing animation. > 0 ⇒ swing in progress; counts down each
# frame. _swing_progress is the eased 0→1 ratio the chomp math reads.
var _swing_remaining_sec: float = 0.0


# MobBase environment overrides.
func _get_body_height() -> float:
	return _BB_HEIGHT


func _get_eye_height() -> float:
	# Vanilla EntityHuman.bO = 1.62 — zombies match. Drives _check_head_in_water.
	return 1.62


func _get_body_width() -> float:
	return _BB_WIDTH


func _ready() -> void:
	max_health = 20  # vanilla `qy.java::aT = 20` (EntityLiving default)
	# Vanilla Alpha 1.2.6 lk.java::g_() returns FEATHER. 0-2 per kill
	# (same range as pig pork, cow leather).
	drop_item_id = Items.FEATHER
	drop_count_min = 0
	drop_count_max = 2
	_build_collision_shape()
	_build_model()
	super._ready()


# Modern MC zombies have a 2.5% chance to drop one iron ingot per kill
# (https://minecraft.wiki/w/Zombie#Drops). Alpha never had this, but
# it's a cheap, well-known QoL deviation that gives the early-game a
# non-ore iron source. Rolled after the base feather drop so both can
# fire on the same kill. We don't gate on player-kill or Looting yet.
func _spawn_drops() -> void:
	super._spawn_drops()
	if randf() < 0.025 and _chunk_manager != null:
		var item := DroppedItem.new()
		_chunk_manager.add_child(item)
		var jitter := Vector3(randf_range(-0.2, 0.2), 0.3, randf_range(-0.2, 0.2))
		item.global_position = global_position + Vector3(0, 0.4, 0) + jitter
		item.setup(Items.IRON_INGOT)


# Two-shape collision (MobBase helpers). Body capsule = physics-only
# (centered, symmetric → no stuck-clipping). Head Area3D = hit-only,
# covers the head cube so head-shots register without enlarging the
# physics footprint into 1-cell paths.
func _build_collision_shape() -> void:
	_build_body_capsule(_BB_WIDTH * 0.5, _BB_HEIGHT)
	# Head cube spans Y [1.5, 2.0] world-local with the cube center at
	# Y=1.75. Box sized to vanilla 0.5 × 0.5 × 0.5 (8 px head cube).
	_build_head_hit_area(Vector3(0.55, 0.55, 0.55), Vector3(0.0, _HEAD_Y_OFFSET, 0.0))


# Build the ModelBiped mesh: head + body + 2 arms (pivoted at shoulder
# for swing/shamble) + 2 legs (pivoted at hip for walk swing). Each
# limb uses MobCube.build_textured_cube to slice the appropriate UV
# rectangle out of the 64×32 zombie.png.
func _build_model() -> void:
	# Shared cached material — see MobBase.get_shared_material.
	var mat: StandardMaterial3D = MobBase.get_shared_material(_ZOMBIE_TEXTURE_PATH, false)
	# Head — static, no animation.
	var head_size := Vector3(
		_HEAD_CUBE_PX.x * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.y * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.z * _PIXEL_TO_METER
	)
	_head_mesh = MeshInstance3D.new()
	_head_mesh.mesh = MobCube.build_textured_cube(
		head_size, _ZOMBIE_TEXTURE_SIZE, _HEAD_TEX_ORIGIN, _HEAD_CUBE_PX, false
	)
	_head_mesh.position = Vector3(0.0, _HEAD_Y_OFFSET, 0.0)
	_head_mesh.material_override = mat
	add_child(_head_mesh)
	# Body.
	var body_size := Vector3(
		_BODY_CUBE_PX.x * _PIXEL_TO_METER,
		_BODY_CUBE_PX.y * _PIXEL_TO_METER,
		_BODY_CUBE_PX.z * _PIXEL_TO_METER
	)
	var body := MeshInstance3D.new()
	body.mesh = MobCube.build_textured_cube(
		body_size, _ZOMBIE_TEXTURE_SIZE, _BODY_TEX_ORIGIN, _BODY_CUBE_PX, false
	)
	body.position = Vector3(0.0, _BODY_Y_OFFSET, 0.0)
	body.material_override = mat
	add_child(body)
	# Arms — pivot at the shoulder (top of arm cube = top of body).
	_arm_r_pivot = _add_limb(
		Vector3(-_ARM_X_OFFSET, _BODY_Y_OFFSET + 0.375, 0.0),
		_ARM_CUBE_PX,
		_ARM_RIGHT_TEX_ORIGIN,
		mat,
		false
	)
	_arm_l_pivot = _add_limb(
		Vector3(_ARM_X_OFFSET, _BODY_Y_OFFSET + 0.375, 0.0),
		_ARM_CUBE_PX,
		_ARM_LEFT_TEX_ORIGIN,
		mat,
		true
	)
	# Legs — pivot at the hip (top of leg cube = body bottom = Y=0.75).
	_leg_r_pivot = _add_limb(
		Vector3(-_LEG_X_OFFSET, 0.75, 0.0), _LEG_CUBE_PX, _LEG_RIGHT_TEX_ORIGIN, mat, false
	)
	_leg_l_pivot = _add_limb(
		Vector3(_LEG_X_OFFSET, 0.75, 0.0), _LEG_CUBE_PX, _LEG_LEFT_TEX_ORIGIN, mat, true
	)


# Build a pivoted limb: a Node3D anchored at `pivot_pos` (the
# shoulder/hip in world-local coords) with a child MeshInstance3D
# whose cube center sits half-cube-height BELOW the pivot. Returns the
# pivot Node3D so the walk-anim code can rotate it around X.
func _add_limb(
	pivot_pos: Vector3,
	cube_px: Vector3i,
	tex_origin: Vector2i,
	mat: StandardMaterial3D,
	mirror: bool
) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = pivot_pos
	add_child(pivot)
	var size := Vector3(
		cube_px.x * _PIXEL_TO_METER, cube_px.y * _PIXEL_TO_METER, cube_px.z * _PIXEL_TO_METER
	)
	var mi := MeshInstance3D.new()
	mi.mesh = MobCube.build_textured_cube(size, _ZOMBIE_TEXTURE_SIZE, tex_origin, cube_px, mirror)
	# Cube center hangs half-height BELOW the pivot (pivot is at the
	# top of the limb — shoulder for arms, hip for legs).
	mi.position = Vector3(0.0, -size.y * 0.5, 0.0)
	mi.material_override = mat
	pivot.add_child(mi)
	return pivot


func _make_textured_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	return mat


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if _dying or _physics_gated:
		return
	# LOD-scaled tick rate — same pattern as skeleton/creeper.
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
	# Daylight burn poll — once per second is enough; the env tick in
	# MobBase handles the per-tick damage application once on-fire.
	_ai_burn_check_accum += delta
	if _ai_burn_check_accum >= _AI_BURN_CHECK_INTERVAL:
		_ai_burn_check_accum = 0.0
		_check_daylight_burn()


func _process(delta: float) -> void:
	super._process(delta)
	if _physics_gated:
		return
	if _lod_tier == LOD_FAR:
		return
	_advance_walk_animation(delta)


# --- Hostile AI ---


# Per-tick decision: if we have a path, walk it (and attack if adjacent
# to the target); otherwise find a target and start chasing. Re-pathing
# happens every _AI_REPATH_TICKS so a moving player stays trackable.
func _ai_tick() -> void:
	# Vanilla `hf.B()` rolls the idle-sound chance per tick. Centralized
	# on MobBase so every species uses the same `nextInt(1000) < a++`
	# pattern (mean ~1 fire per 6 s, matching vanilla `b() = 80`).
	if roll_idle_sfx_tick():
		_play_idle_sfx()
	_ai_repath_counter += 1
	var player: Node3D = _find_player()
	if player == null:
		# No target — wander. Vanilla zombies inherit EntityCreature's
		# random-target wander; without it the zombie freezes wherever
		# it spawned, which reads as a bug. See MobBase.pick_wander_target.
		_wander_tick()
		return
	var dist_sq: float = global_position.distance_squared_to(player.global_position)
	# Drop the chase when the player gets too far. _AI_ABANDON_RADIUS is
	# bigger than _AI_DETECT_RADIUS so we don't oscillate between chase
	# and idle at the boundary.
	if dist_sq > _AI_ABANDON_RADIUS * _AI_ABANDON_RADIUS:
		_ai_player_cache = null
		_wander_tick()
		return
	# In-melee? Vanilla EntityMob.l(EntityLiving target) attacks when
	# `distSqr < e²` where e is the attack-range setting (~2.0² for
	# zombies). Skip pathing this tick if we're already adjacent.
	if dist_sq < _AI_MELEE_RANGE * _AI_MELEE_RANGE:
		_face_target(player)
		_velocity_brake()
		if _ai_melee_cooldown_sec <= 0.0:
			_attack_player(player)
		return
	# Re-pathfind to the player's current cell every _AI_REPATH_TICKS or
	# whenever we run out of path mid-chase. Vanilla rebuilds via
	# `f` field on `ay.java::a` (PathNavigate).
	if _ai_path.is_empty() or _ai_repath_counter >= _AI_REPATH_TICKS:
		_ai_repath_counter = 0
		_repath_toward(player)
	if not _ai_path.is_empty():
		_tick_walk_path()


# Locate the player node under Main. Cached after first hit since the
# Player scene is long-lived. Returns null on the loading screen
# (Player not yet mounted) — _ai_tick treats null as "no target".
func _find_player() -> Node3D:
	if _ai_player_cache != null and is_instance_valid(_ai_player_cache):
		return _ai_player_cache
	var main: Node = get_tree().root.get_node_or_null("Main")
	if main == null:
		return null
	_ai_player_cache = main.find_child("Player", true, false) as Node3D
	return _ai_player_cache


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
	if next_node.y > current_cell_y and is_on_floor():
		velocity.y = _AI_JUMP_VELOCITY
		velocity.x = dir.x * _AI_STEP_BOOST_SPEED
		velocity.z = dir.z * _AI_STEP_BOOST_SPEED
	else:
		velocity.x = dir.x * _AI_WALK_SPEED
		velocity.z = dir.z * _AI_WALK_SPEED
	_face_walk_direction()


func _attack_player(player: Node3D) -> void:
	if not player.has_method("take_damage"):
		return
	# Vanilla EntityMob.l calls EntityHuman.a(this, attackDamage) which
	# routes to EntityHuman.attackEntityFrom. We mirror via
	# Player.take_damage(amount, source). Source tag is the literal
	# string "mob" instead of Player.DAMAGE_MOB because `Player` isn't
	# declared as a global class_name (player.gd just `extends
	# CharacterBody3D`), so the bare reference fails to parse at
	# script load. Player.gd's DAMAGE_MOB const is `"mob"`.
	player.call("take_damage", _AI_MELEE_DAMAGE, "mob")
	_ai_melee_cooldown_sec = _AI_MELEE_COOLDOWN_SEC
	# Beta `EntityLiving.swingItem()` — flip the swing flag so the
	# overhead-chomp animation plays. Vanilla restarts the swing even
	# mid-cycle by setting swingProgressInt = -1, so overlapping
	# attacks always look like a fresh hit.
	_swing_remaining_sec = _SWING_DURATION_SEC


# Slow the zombie to a near-stop on in-melee frames so it doesn't push
# the player around while attacking.
# Vanilla EntityCreature wander — picks a random nearby target every
# few seconds and pathfinds there at half walk speed. Uses the shared
# `MobBase.pick_wander_target` cooldown so other hostile mobs match.
# Without this the zombie freezes when no player is in detect range.
func _wander_tick() -> void:
	if not _ai_path.is_empty():
		_tick_walk_path()
		velocity.x *= 0.5
		velocity.z *= 0.5
		return
	var target: Vector3 = pick_wander_target(_AI_TICK_DT)
	if target != Vector3.ZERO:
		_repath_toward_position(target)
	else:
		_velocity_brake()


# Same as `_repath_toward(player)` but takes a raw world position so
# the wander tick can ask the pathfinder for an arbitrary point.
func _repath_toward_position(target_pos: Vector3) -> void:
	if _chunk_manager == null:
		return
	var origin: Vector3i = Vector3i(
		int(floor(global_position.x)), int(floor(global_position.y)), int(floor(global_position.z))
	)
	var goal: Vector3i = Vector3i(
		int(floor(target_pos.x)), int(floor(target_pos.y)), int(floor(target_pos.z))
	)
	_ai_path = Pathfinder.find_path(
		_chunk_manager, origin, goal, _AI_PATHFIND_RADIUS, _AI_PATHFIND_MAX_ITERS
	)


func _velocity_brake() -> void:
	velocity.x = 0.0
	velocity.z = 0.0


func _face_target(target: Node3D) -> void:
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return
	var target_yaw: float = atan2(-to_target.x, -to_target.z)
	var delta: float = wrapf(target_yaw - rotation.y, -PI, PI)
	delta = clampf(delta, -_AI_MAX_YAW_STEP, _AI_MAX_YAW_STEP)
	rotation.y += delta


func _face_walk_direction() -> void:
	var vx: float = velocity.x
	var vz: float = velocity.z
	if vx * vx + vz * vz < 0.0025:
		return
	var target_yaw: float = atan2(-vx, -vz)
	var delta: float = wrapf(target_yaw - rotation.y, -PI, PI)
	delta = clampf(delta, -_AI_MAX_YAW_STEP, _AI_MAX_YAW_STEP)
	rotation.y += delta


# --- Daylight burn ---


# Vanilla EntityZombie.B() (Beta): if it's daytime + no rain + the
# entity is exposed to sky (skylight reaches 15 at the entity's head)
# + not in water → setFire(8). We approximate via WorldTime.is_day()
# (no rain modeled yet) + sky-light read at the eye cell.
func _check_daylight_burn() -> void:
	if _chunk_manager == null:
		return
	if _in_water or _in_lava:
		return
	if _on_fire_ticks > 0:
		return
	if not _is_world_daytime():
		return
	var eye_cell := Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y + _get_eye_height())),
		int(floor(global_position.z))
	)
	if _chunk_manager.get_chunk_at_coord(Vector2i(eye_cell.x >> 4, eye_cell.z >> 4)) == null:
		return
	var sky: int = _chunk_manager.get_world_sky_light(eye_cell)
	if sky >= 15:
		_on_fire_ticks = int(_AI_BURN_DURATION_SEC * 20.0)


# Vanilla `oz.java::j(time)` sun-curve maxes out at noon (tick 6000)
# and is "day" roughly between tick 0 (sunrise) and 12000 (sunset).
# WorldTime.sky_factor() gives us 0.1 (midnight) .. 1.0 (noon) — use
# 0.5 as the "is day" threshold.
func _is_world_daytime() -> bool:
	return WorldTime.sky_factor() > 0.5


# --- Walk animation ---


func _advance_walk_animation(delta: float) -> void:
	_age_seconds += delta
	if _swing_remaining_sec > 0.0:
		_swing_remaining_sec = maxf(0.0, _swing_remaining_sec - delta)
	var vx: float = velocity.x
	var vz: float = velocity.z
	var sp_sq: float = vx * vx + vz * vz
	var speed: float = sqrt(sp_sq) if sp_sq > 0.0001 else 0.0
	var target_amount: float = clampf(speed / _AI_WALK_SPEED, 0.0, 1.0)
	var lerp_t: float = minf(_WALK_ANIM_LERP_PER_SEC * delta, 1.0)
	_walk_anim_amount = lerpf(_walk_anim_amount, target_amount, lerp_t)
	_walk_dist += _walk_anim_amount * delta * _WALK_DIST_SCALE
	var phase: float = _walk_dist * _WALK_FREQ
	# Legs: vanilla dc.java:70-71 — cos(phase) * 1.4 * walkAmount, hips
	# anti-phase. Period matches the arm-swing of a normal biped, but
	# here only legs swing.
	var leg_swing: float = cos(phase) * _LEG_AMPLITUDE * _walk_anim_amount
	if _leg_l_pivot != null:
		_leg_l_pivot.rotation.x = leg_swing
	if _leg_r_pivot != null:
		_leg_r_pivot.rotation.x = -leg_swing
	_apply_zombie_arm_pose()
	_step_accum += speed * delta
	if _step_accum >= _STEP_STRIDE:
		_step_accum -= _STEP_STRIDE
		_play_step()


# Apply the vanilla Alpha zombie arm pose — `ck.java::a()`. Arms hang
# horizontal forward (-π/2 pitch), idle-sway in pitch+roll, plus the
# Beta overhead-chomp added by `swingProgress`.
func _apply_zombie_arm_pose() -> void:
	var swing: float = 0.0
	if _swing_remaining_sec > 0.0:
		swing = 1.0 - (_swing_remaining_sec / _SWING_DURATION_SEC)
	# Vanilla ck.java:8-9: f8 = sin(swing * π); f9 = sin((1-(1-swing)²)*π).
	# Chomp peaks at swing=0.5 with arms ~46° above horizontal, returns
	# to horizontal at swing=1.
	var f8: float = sin(swing * PI)
	var inv: float = 1.0 - swing
	var f9: float = sin((1.0 - inv * inv) * PI)
	var chomp_pitch: float = f8 * 1.2 - f9 * 0.4
	# Idle sway mirrored L/R so arms wobble in counter-phase.
	var idle_pitch: float = sin(_age_seconds * _IDLE_PITCH_FREQ_RPS) * _IDLE_SWAY_AMP
	if _arm_r_pivot != null:
		_arm_r_pivot.rotation = Vector3(_ARM_HORIZONTAL_PITCH + chomp_pitch + idle_pitch, 0.0, 0.0)
	if _arm_l_pivot != null:
		_arm_l_pivot.rotation = Vector3(_ARM_HORIZONTAL_PITCH + chomp_pitch - idle_pitch, 0.0, 0.0)


func _play_step() -> void:
	if _chunk_manager == null:
		return
	var below := Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y - 0.05)),
		int(floor(global_position.z))
	)
	var block_id: int = _chunk_manager.get_world_block(below)
	if block_id == Blocks.AIR:
		return
	# Vanilla zombies have their own step pool (sound3/mob/zombie/
	# step{1..5}.ogg) rather than reusing the block step samples. SFX
	# helper handles the random pick + 3D positioning.
	SFX.play_zombie_step(global_position)


# Species SFX overrides — vanilla EntityZombie inherits getLivingSound /
# getHurtSound / getDeathSound from EntityMob and overrides them to
# `mob.zombie` / `mob.zombiehurt` / `mob.zombiedeath`.
func _play_idle_sfx() -> void:
	SFX.play_zombie_say(global_position)


func _play_hurt_sfx() -> void:
	SFX.play_zombie_hurt(global_position)


func _play_death_sfx() -> void:
	SFX.play_zombie_death(global_position)
