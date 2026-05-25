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
# Visual model: vanilla 64×32 `mh.java` ModelBiped — head (8×8×8) +
# body (8×12×4) + 2 arms (4×12×4) + 2 legs (4×12×4). Limb-swing
# animation on walk drives both arms (anti-phase) and both legs
# (anti-phase). Arms swing FORWARD when chasing (vanilla raises arms
# horizontally — the famous "shamble" pose).

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

# Walk-animation params — matches the pig/cow/sheep convention.
const _WALK_FREQ: float = 0.6662
const _WALK_DIST_SCALE: float = 12.0
const _WALK_ANIM_LERP_PER_SEC: float = 8.0
const _LEG_AMPLITUDE: float = 1.0  # legs swing through ±~57°
const _ARM_AMPLITUDE: float = 0.8  # arms swing slightly less
# Vanilla zombie pose: arms raised horizontally forward when targeting
# a player. We add a fixed forward-pitch offset to the arm rotation
# when chasing (i.e. when we have a path active).
const _ARM_CHASE_PITCH: float = -PI * 0.4  # ~72° forward of vertical
const _STEP_STRIDE: float = 1.4

# Idle SFX. Vanilla EntityLiving.B() rolls 1/120 per tick to play the
# species' "living" sound. Same pattern as passive mobs.
const _IDLE_SFX_ROLL_INTERVAL: float = 0.1
const _IDLE_SFX_CHANCE: float = 1.0 / 120.0

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
var _idle_sfx_accum: float = 0.0
# `true` while we have an active chase path — drives the arm-forward
# shamble pose.
var _is_chasing: bool = false


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
	var tex: Texture2D = load(_ZOMBIE_TEXTURE_PATH) as Texture2D
	var mat: StandardMaterial3D = _make_textured_material(tex)
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
	if _dying:
		return
	_ai_tick_accum += delta
	while _ai_tick_accum >= _AI_TICK_DT:
		_ai_tick_accum -= _AI_TICK_DT
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
	_advance_walk_animation(delta)
	_roll_idle_sfx(delta)


# --- Hostile AI ---


# Per-tick decision: if we have a path, walk it (and attack if adjacent
# to the target); otherwise find a target and start chasing. Re-pathing
# happens every _AI_REPATH_TICKS so a moving player stays trackable.
func _ai_tick() -> void:
	_ai_repath_counter += 1
	var player: Node3D = _find_player()
	if player == null:
		_is_chasing = false
		_ai_path.clear()
		return
	var dist_sq: float = global_position.distance_squared_to(player.global_position)
	# Drop the chase when the player gets too far. _AI_ABANDON_RADIUS is
	# bigger than _AI_DETECT_RADIUS so we don't oscillate between chase
	# and idle at the boundary.
	if dist_sq > _AI_ABANDON_RADIUS * _AI_ABANDON_RADIUS:
		_is_chasing = false
		_ai_path.clear()
		_ai_player_cache = null
		return
	# In-melee? Vanilla EntityMob.l(EntityLiving target) attacks when
	# `distSqr < e²` where e is the attack-range setting (~2.0² for
	# zombies). Skip pathing this tick if we're already adjacent.
	if dist_sq < _AI_MELEE_RANGE * _AI_MELEE_RANGE:
		_face_target(player)
		_velocity_brake()
		if _ai_melee_cooldown_sec <= 0.0:
			_attack_player(player)
		_is_chasing = false
		return
	# Re-pathfind to the player's current cell every _AI_REPATH_TICKS or
	# whenever we run out of path mid-chase. Vanilla rebuilds via
	# `f` field on `ay.java::a` (PathNavigate).
	if _ai_path.is_empty() or _ai_repath_counter >= _AI_REPATH_TICKS:
		_ai_repath_counter = 0
		_repath_toward(player)
	if not _ai_path.is_empty():
		_tick_walk_path()
		_is_chasing = true
	else:
		_is_chasing = false


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
	# Player.take_damage(amount, source).
	player.call("take_damage", _AI_MELEE_DAMAGE, Player.DAMAGE_MOB)
	_ai_melee_cooldown_sec = _AI_MELEE_COOLDOWN_SEC


# Slow the zombie to a near-stop on in-melee frames so it doesn't push
# the player around while attacking.
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
	var vx: float = velocity.x
	var vz: float = velocity.z
	var sp_sq: float = vx * vx + vz * vz
	var speed: float = sqrt(sp_sq) if sp_sq > 0.0001 else 0.0
	var target_amount: float = clampf(speed / _AI_WALK_SPEED, 0.0, 1.0)
	var lerp_t: float = minf(_WALK_ANIM_LERP_PER_SEC * delta, 1.0)
	_walk_anim_amount = lerpf(_walk_anim_amount, target_amount, lerp_t)
	_walk_dist += _walk_anim_amount * delta * _WALK_DIST_SCALE
	var phase: float = _walk_dist * _WALK_FREQ
	var leg_swing: float = sin(phase) * _LEG_AMPLITUDE * _walk_anim_amount
	var arm_swing: float = sin(phase + PI) * _ARM_AMPLITUDE * _walk_anim_amount
	# Vanilla ModelZombie raises both arms forward (parallel) while
	# chasing — the "shamble" pose. Without a chase, arms swing
	# anti-phase to legs (normal walk).
	var arm_base: float = _ARM_CHASE_PITCH if _is_chasing else 0.0
	if _leg_l_pivot != null:
		_leg_l_pivot.rotation.x = leg_swing
	if _leg_r_pivot != null:
		_leg_r_pivot.rotation.x = -leg_swing
	if _arm_l_pivot != null:
		_arm_l_pivot.rotation.x = arm_base + arm_swing
	if _arm_r_pivot != null:
		_arm_r_pivot.rotation.x = arm_base - arm_swing
	_step_accum += speed * delta
	if _step_accum >= _STEP_STRIDE:
		_step_accum -= _STEP_STRIDE
		_play_step()


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


func _roll_idle_sfx(delta: float) -> void:
	_idle_sfx_accum += delta
	if _idle_sfx_accum < _IDLE_SFX_ROLL_INTERVAL:
		return
	_idle_sfx_accum -= _IDLE_SFX_ROLL_INTERVAL
	if randf() < _IDLE_SFX_CHANCE:
		_play_idle_sfx()


# Species SFX overrides — vanilla EntityZombie inherits getLivingSound /
# getHurtSound / getDeathSound from EntityMob and overrides them to
# `mob.zombie` / `mob.zombiehurt` / `mob.zombiedeath`.
func _play_idle_sfx() -> void:
	SFX.play_zombie_say(global_position)


func _play_hurt_sfx() -> void:
	SFX.play_zombie_hurt(global_position)


func _play_death_sfx() -> void:
	SFX.play_zombie_death(global_position)
