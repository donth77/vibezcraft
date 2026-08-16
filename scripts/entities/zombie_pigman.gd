class_name ZombiePigman
extends "res://scripts/entities/mob_base.gd"

# Vanilla Alpha 1.2.6 EntityPigZombie (`pt.java`) — the Nether's neutral
# hostile. See docs/nether-alpha-1.2.6-implementation-plan.md §8.1.
#
# `pt extends nt` (EntityZombie) in the source, and the renderer map has
# no entry of its own — `mn.java:37` registers `nt.class → new m(new
# ck(), 0.5f)` and the lookup walks superclasses, so a pigman is drawn
# with ModelZombie's locked-horizontal arms and RenderBiped's held-item
# pass. That is why it holds its sword straight out in front of it.
#
# Neutrality is the whole character of this mob, and it is three small
# pieces of `pt.java` working together:
#
#   * `c_()` returns null while `Anger == 0`, so a calm pigman never
#     acquires a target no matter how close the player stands;
#   * `a(lw, int)` — being hit BY A PLAYER angers every pigman in an AABB
#     grown 32 blocks on each axis, then this one;
#   * `Anger` is set to `400 + nextInt(400)` and **never decremented
#     anywhere in the class**. Once angered, a pigman stays angry for the
#     life of the world. Alpha has no forgiveness timer; the modern
#     20-40 second one is a later addition and is deliberately absent.
#
# The other Alpha-specific quirk preserved here is the angry-sound
# countdown. `c()` sets it to `nextInt(40)`, and `e_()` fires the sound
# on the tick it reaches zero — but the check is `if (b > 0 && --b == 0)`,
# so a countdown that STARTS at zero never enters the branch and that
# pigman simply never shouts. One in forty angered pigmen is silent.
#
# Fire immunity is `this.bm = true`, handled by MobBase._is_fire_immune.
# It also silently cancels the daylight burn `pt` inherits from `nt.k()` —
# see the note there.

const _TEXTURE_PATH: String = "res://assets/textures/mob/pigzombie.png"
const _TEXTURE_SIZE: Vector2i = Vector2i(64, 32)

# ModelBiped geometry, identical to the zombie's — pigmen use the same
# `ck.java` ModelZombie. Pixel units, converted via _PIXEL_TO_METER.
const _PIXEL_TO_METER: float = 1.0 / 16.0
const _HEAD_CUBE_PX: Vector3i = Vector3i(8, 8, 8)
const _BODY_CUBE_PX: Vector3i = Vector3i(8, 12, 4)
const _ARM_CUBE_PX: Vector3i = Vector3i(4, 12, 4)
const _LEG_CUBE_PX: Vector3i = Vector3i(4, 12, 4)

const _HEAD_TEX_ORIGIN: Vector2i = Vector2i(0, 0)
const _BODY_TEX_ORIGIN: Vector2i = Vector2i(16, 16)
const _ARM_TEX_ORIGIN: Vector2i = Vector2i(40, 16)
const _LEG_TEX_ORIGIN: Vector2i = Vector2i(0, 16)

const _LEG_Y_OFFSET: float = 0.375
const _BODY_Y_OFFSET: float = 1.125
const _HEAD_Y_OFFSET: float = 1.75
const _ARM_X_OFFSET: float = 0.375
const _LEG_X_OFFSET: float = 0.125

const _BB_HEIGHT: float = 1.95
const _BB_WIDTH: float = 0.6

const _AI_TICK_DT: float = 1.0 / 20.0

# `ef.c_()` — EntityMonster looks for the closest player within 16 m.
const _AI_DETECT_RADIUS: float = 16.0
const _AI_ABANDON_RADIUS: float = 40.0
const _AI_REPATH_TICKS: int = 20

# `pt` sets `this.f = 5` in its constructor, overriding EntityMonster's
# default of 2. Five is a lot — a pigman two-shots an unarmoured player
# down to half health.
const _AI_MELEE_RANGE: float = 1.8
const _AI_MELEE_DAMAGE: int = 5
const _AI_MELEE_COOLDOWN_SEC: float = 0.5

# `e_()` line 1: `this.am = this.g != null ? 0.95f : 0.5f`. The zombie's
# `am` is 0.5 and walks at 1.0 m/s here, so the angry figure scales to
# 0.95 / 0.5 = 1.9x. Neutral pigmen amble; angry ones outrun a walking
# player, which is the entire threat of the mob.
const _AI_WALK_SPEED_CALM: float = 1.0
const _AI_WALK_SPEED_ANGRY: float = 1.9
const _AI_JUMP_VELOCITY: float = 6.0
const _AI_STEP_BOOST_SPEED: float = 2.5
const _AI_MAX_YAW_STEP: float = PI / 4.0
const _AI_PATHFIND_RADIUS: float = 24.0
const _AI_PATHFIND_MAX_ITERS: int = 300
const _AI_ARRIVE_DIST: float = 0.6

# `pt.a(lw, int)` — `this.as.b(this, this.aG.b(32.0, 32.0, 32.0))`.
# AxisAlignedBB.grow expands the box by this much in BOTH directions on
# each axis, so the alert region is the pigman's own body box plus 32
# blocks every way. Deliberately a BOX, not a sphere: a pigman at the
# corner of the region is alerted and one just past the face is not, and
# the tests check exactly that boundary.
const ANGER_ALERT_RANGE: float = 32.0

# `c()` — `this.a = 400 + this.bd.nextInt(400)`.
const ANGER_BASE: int = 400
const ANGER_SPREAD: int = 400
# `c()` — `this.b = this.bd.nextInt(40)`.
const ANGRY_SOUND_DELAY_MAX: int = 40

# Held item. `pt.c` is `new fp(dx.E, 1)` — dx.E is item 27 + 256 = 283,
# the gold sword. Vanilla never drops it; see _spawn_drops.
const _HELD_ITEM_ID: int = Items.GOLD_SWORD
const _HELD_ITEM_PIXEL_SCALE: float = 1.0 / 22.0

# `lw2 instanceof eb` — how the group-aggro check identifies a player.
# See _is_player for why it is a script path and a group rather than a
# class reference.
const _PLAYER_SCRIPT_PATH: String = "res://scripts/player/player.gd"
const PLAYER_GROUP: String = "player"

# Walk animation — same ModelBiped pace as the zombie.
const _WALK_FREQ: float = 0.6662
const _WALK_DIST_SCALE: float = 12.0
const _WALK_ANIM_LERP_PER_SEC: float = 8.0
const _LEG_AMPLITUDE: float = 1.4
const _ARM_HORIZONTAL_PITCH: float = PI * 0.5
const _IDLE_PITCH_FREQ_RPS: float = 20.0 * 0.067
const _IDLE_SWAY_AMP: float = 0.05
const _SWING_DURATION_SEC: float = 6.0 / 20.0
const _STEP_STRIDE: float = 1.4

# --- Anger state (`pt.a` and `pt.b`) ---
# Persisted as a short. Nonzero means hostile, forever.
var anger: int = 0
# Ticks until the angry shout. Zero means "not pending" — which is also
# what a `nextInt(40)` roll of 0 produces, and vanilla never fires in that
# case either.
var angry_sound_countdown: int = 0

# --- Visual node refs ---
var _head_mesh: MeshInstance3D
var _arm_l_pivot: Node3D
var _arm_r_pivot: Node3D
var _leg_l_pivot: Node3D
var _leg_r_pivot: Node3D
var _sword_mesh: MeshInstance3D

# --- AI state ---
var _ai_tick_accum: float = 0.0
var _ai_path: Array = []
var _ai_repath_counter: int = 0
var _ai_path_failed: bool = false
var _ai_melee_cooldown_sec: float = 0.0
var _ai_player_cache: Node3D = null
# Vanilla `this.g` (the current target). Distinct from _ai_player_cache,
# which is just a node lookup: `g` is what drives the speed switch and
# what `c()` assigns when the group is alerted.
var _ai_target: Node3D = null

# --- Walk-anim state ---
var _walk_dist: float = 0.0
var _walk_anim_amount: float = 0.0
var _step_accum: float = 0.0
var _age_seconds: float = 0.0
var _swing_remaining_sec: float = 0.0


func _get_body_height() -> float:
	return _BB_HEIGHT


func _get_eye_height() -> float:
	return 1.62


func _get_body_width() -> float:
	return _BB_WIDTH


# `pt` constructor line 4: `this.bm = true`.
func _is_fire_immune() -> bool:
	return true


func _ready() -> void:
	max_health = 20  # inherited from ef.java's `this.J = 20`
	# `g_()` returns `dx.ap.aW` — item 64 + 256 = 320, cooked porkchop.
	# `hf.b(lw)` drops `nextInt(3)` of it, so 0-2.
	drop_item_id = Items.COOKED_PORKCHOP
	drop_count_min = 0
	drop_count_max = 2
	_build_collision_shape()
	_build_model()
	super._ready()


func _build_collision_shape() -> void:
	_build_body_capsule(_BB_WIDTH * 0.5, _BB_HEIGHT)
	_build_head_hit_area(Vector3(0.55, 0.55, 0.55), Vector3(0.0, _HEAD_Y_OFFSET, 0.0))


func _build_model() -> void:
	var mat: StandardMaterial3D = MobBase.get_shared_material(_TEXTURE_PATH, false)
	_head_mesh = _add_cube(_HEAD_CUBE_PX, _HEAD_TEX_ORIGIN, _HEAD_Y_OFFSET, mat)
	_add_cube(_BODY_CUBE_PX, _BODY_TEX_ORIGIN, _BODY_Y_OFFSET, mat)
	_arm_r_pivot = _add_limb(
		Vector3(-_ARM_X_OFFSET, _BODY_Y_OFFSET + 0.375, 0.0),
		_ARM_CUBE_PX,
		_ARM_TEX_ORIGIN,
		mat,
		false
	)
	_arm_l_pivot = _add_limb(
		Vector3(_ARM_X_OFFSET, _BODY_Y_OFFSET + 0.375, 0.0),
		_ARM_CUBE_PX,
		_ARM_TEX_ORIGIN,
		mat,
		true
	)
	_leg_r_pivot = _add_limb(
		Vector3(-_LEG_X_OFFSET, 0.75, 0.0), _LEG_CUBE_PX, _LEG_TEX_ORIGIN, mat, false
	)
	_leg_l_pivot = _add_limb(
		Vector3(_LEG_X_OFFSET, 0.75, 0.0), _LEG_CUBE_PX, _LEG_TEX_ORIGIN, mat, true
	)
	_build_sword()


# The gold sword, in the right hand. `m.java::b` applies the right arm's
# transform before drawing the held item, which is what parenting to the
# arm pivot reproduces — the sword tracks the walk swing and the chomp
# for free.
func _build_sword() -> void:
	_sword_mesh = attach_held_item(
		_arm_r_pivot,
		_HELD_ITEM_ID,
		MobBase.held_item_basis_full_3d(_HELD_ITEM_PIXEL_SCALE),
		# The hand is at the far end of the 12 px arm.
		Vector3(0.0, -0.75, 0.0)
	)


func _add_cube(
	cube_px: Vector3i, tex_origin: Vector2i, y_offset: float, mat: StandardMaterial3D
) -> MeshInstance3D:
	var size := Vector3(
		cube_px.x * _PIXEL_TO_METER, cube_px.y * _PIXEL_TO_METER, cube_px.z * _PIXEL_TO_METER
	)
	var mi := MeshInstance3D.new()
	mi.mesh = MobCube.build_textured_cube(size, _TEXTURE_SIZE, tex_origin, cube_px, false)
	mi.position = Vector3(0.0, y_offset, 0.0)
	mi.material_override = mat
	add_child(mi)
	return mi


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
	mi.mesh = MobCube.build_textured_cube(size, _TEXTURE_SIZE, tex_origin, cube_px, mirror)
	mi.position = Vector3(0.0, -size.y * 0.5, 0.0)
	mi.material_override = mat
	pivot.add_child(mi)
	return pivot


# --- Anger ---


# True while this pigman is hostile. `c_()` in the source: a pigman with
# `Anger == 0` cannot acquire a target at all.
func is_angry() -> bool:
	return anger != 0


# `pt.c(lw2)` — become angry at `target`. Called on self and on every
# pigman in range when a player lands a hit.
func become_angry_at(target: Node3D) -> void:
	_ai_target = target
	_ai_player_cache = target
	anger = ANGER_BASE + (randi() % ANGER_SPREAD)
	# `nextInt(40)`, which INCLUDES zero — and a zero never fires, because
	# `e_()` guards with `b > 0` before decrementing. Reproduced exactly;
	# see the class comment.
	angry_sound_countdown = randi() % ANGRY_SOUND_DELAY_MAX


# The alert region: this pigman's body box grown 32 blocks on each axis,
# matching `this.aG.b(32.0, 32.0, 32.0)`.
func alert_region() -> AABB:
	var half_w: float = _BB_WIDTH * 0.5
	var body := AABB(
		global_position - Vector3(half_w, 0.0, half_w), Vector3(_BB_WIDTH, _BB_HEIGHT, _BB_WIDTH)
	)
	return body.grow(ANGER_ALERT_RANGE)


# `pt.a(lw2, n2)` — a hit from a PLAYER (and only a player) alerts the
# group. Damage from lava, another mob, or a skeleton's arrow does not:
# the source check is `lw2 instanceof eb`, EntityPlayer.
func take_damage(
	amount: int,
	knockback_dir: Vector3 = Vector3.ZERO,
	knockback_strength: float = 1.0,
	attacker: Node = null
) -> bool:
	if attacker != null and _is_player(attacker):
		_alert_group(attacker as Node3D)
		become_angry_at(attacker as Node3D)
	return super.take_damage(amount, knockback_dir, knockback_strength, attacker)


func _alert_group(attacker: Node3D) -> void:
	var region: AABB = alert_region()
	var mobs: Dictionary = MobBase.active_mobs()
	for id: int in mobs:
		var other: Variant = mobs[id]
		if not is_instance_valid(other) or other == self:
			continue
		if not (other is ZombiePigman):
			continue
		# Vanilla tests the OTHER entity's bounding box against the region,
		# not its origin — `World.getEntities` returns anything whose box
		# intersects. A pigman straddling the boundary is alerted.
		var pigman: ZombiePigman = other as ZombiePigman
		if region.intersects(pigman.body_aabb()):
			pigman.become_angry_at(attacker)


# This mob's own collision box in world space. Used by the group alert.
func body_aabb() -> AABB:
	var half_w: float = _BB_WIDTH * 0.5
	return AABB(
		global_position - Vector3(half_w, 0.0, half_w), Vector3(_BB_WIDTH, _BB_HEIGHT, _BB_WIDTH)
	)


# `lw2 instanceof eb`. Matched by SCRIPT PATH rather than by class,
# because player.gd declares no `class_name` — a bare `Player` reference
# fails to parse at script load. EntitySave uses the same idiom for Boat
# and Minecart for the same reason.
#
# The group is the second route in, and it is not a test-only affordance:
# player.gd joins PLAYER_GROUP in _ready, so anything that needs to ask
# "is this the player" can, without a script dependency.
func _is_player(node: Node) -> bool:
	if node == null or not (node is Node3D):
		return false
	var script: Script = node.get_script() as Script
	if script != null and script.resource_path == _PLAYER_SCRIPT_PATH:
		return true
	return node.is_in_group(PLAYER_GROUP)


# --- Persistence ---


# `a(iq2)` writes `Anger` as a short. The angry-sound countdown is NOT
# persisted in vanilla — it is a transient render-tick detail — so it is
# left out here too, and a pigman loaded from disk simply does not shout.
func to_save_dict() -> Dictionary:
	var d: Dictionary = super.to_save_dict()
	d["anger"] = anger
	return d


func restore_from_dict(d: Dictionary) -> void:
	super.restore_from_dict(d)
	# Clamped to a signed short's range, which is the width vanilla's NBT
	# tag gives it. A save written by a future version with a wider field
	# still loads as "angry" rather than as garbage.
	anger = clampi(int(d.get("anger", 0)), -32768, 32767)


# --- AI ---


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if _dying or _physics_gated:
		return
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
	if _ai_melee_cooldown_sec > 0.0:
		_ai_melee_cooldown_sec = maxf(0.0, _ai_melee_cooldown_sec - delta)


func _process(delta: float) -> void:
	super._process(delta)
	if _physics_gated or _lod_tier == LOD_FAR:
		return
	_advance_walk_animation(delta)


func _ai_tick() -> void:
	if roll_idle_sfx_tick():
		_play_idle_sfx()
	# `e_()` — the angry shout fires on the tick the countdown reaches
	# zero, and only if it was positive to begin with.
	if angry_sound_countdown > 0:
		angry_sound_countdown -= 1
		if angry_sound_countdown == 0:
			_play_angry_sfx()
	_ai_repath_counter += 1
	var player: Node3D = _find_target()
	if player == null:
		_ai_target = null
		_wander_tick()
		return
	_ai_target = player
	var dist_sq: float = global_position.distance_squared_to(player.global_position)
	if dist_sq > _AI_ABANDON_RADIUS * _AI_ABANDON_RADIUS:
		# Vanilla drops the target reference but NOT the anger — the
		# pigman goes back to wandering and re-acquires the moment a
		# player is in range again.
		_ai_player_cache = null
		_ai_target = null
		_wander_tick()
		return
	if dist_sq < _AI_MELEE_RANGE * _AI_MELEE_RANGE:
		_face_target(player)
		_velocity_brake()
		if _ai_melee_cooldown_sec <= 0.0:
			_attack_player(player)
		return
	var repath_due: bool = _ai_repath_counter >= _AI_REPATH_TICKS
	if _ai_path.is_empty():
		repath_due = not _ai_path_failed or _ai_repath_counter >= _AI_REPATH_TICKS / 2
	if repath_due:
		_ai_repath_counter = 0
		_repath_toward(player)
	if not _ai_path.is_empty():
		_tick_walk_path()


# `c_()` — EntityMonster's 16 m closest-player search, gated on anger.
# A calm pigman returns null here no matter what is standing next to it,
# which is the whole of its neutrality.
func _find_target() -> Node3D:
	if not is_angry():
		return null
	var player: Node3D = _find_player()
	if player == null:
		return null
	# After a save/load the target reference is gone but the anger is not,
	# so an angry pigman re-acquires as soon as a player comes within the
	# same 16 m EntityMonster uses.
	if (
		global_position.distance_squared_to(player.global_position)
		> (_AI_DETECT_RADIUS * _AI_DETECT_RADIUS)
	):
		# Already chasing someone? Keep them until the abandon radius.
		if _ai_target != null and is_instance_valid(_ai_target):
			return _ai_target
		return null
	return player


func _find_player() -> Node3D:
	if _ai_player_cache != null and is_instance_valid(_ai_player_cache):
		return _ai_player_cache
	var main: Node = get_tree().root.get_node_or_null("Main")
	if main == null:
		return null
	_ai_player_cache = main.find_child("Player", true, false) as Node3D
	return _ai_player_cache


# `e_()` line 1 — speed follows whether a target is held, not whether the
# mob is angry. An angry pigman that has lost sight of its target ambles.
func _walk_speed() -> float:
	if _ai_target != null and is_instance_valid(_ai_target):
		return _AI_WALK_SPEED_ANGRY
	return _AI_WALK_SPEED_CALM


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
	_ai_path_failed = _ai_path.is_empty()


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
	var speed: float = _walk_speed()
	var current_cell_y: int = int(floor(global_position.y + 0.05))
	if next_node.y > current_cell_y and mob_is_on_floor():
		velocity.y = _AI_JUMP_VELOCITY
		velocity.x = dir.x * _AI_STEP_BOOST_SPEED
		velocity.z = dir.z * _AI_STEP_BOOST_SPEED
	else:
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
	_face_walk_direction()


func _wander_tick() -> void:
	if not _ai_path.is_empty():
		_tick_walk_path()
		velocity.x *= 0.5
		velocity.z *= 0.5
		return
	if roll_wander_gate(80):
		if _pick_wander_target():
			return
	_velocity_brake()


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
		var cell := Vector3i(
			origin.x + (randi() % 13) - 6,
			origin.y + (randi() % 7) - 3,
			origin.z + (randi() % 13) - 6
		)
		if not Pathfinder.is_walkable(_chunk_manager, cell):
			continue
		var score: float = float(_chunk_manager.get_world_effective_light(cell))
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


func _attack_player(player: Node3D) -> void:
	if not player.has_method("take_damage"):
		return
	player.call("take_damage", _AI_MELEE_DAMAGE, "mob", player.global_position - global_position)
	_ai_melee_cooldown_sec = _AI_MELEE_COOLDOWN_SEC
	_swing_remaining_sec = _SWING_DURATION_SEC


func _velocity_brake() -> void:
	velocity.x = 0.0
	velocity.z = 0.0


func _face_target(target: Node3D) -> void:
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return
	_turn_toward(atan2(-to_target.x, -to_target.z))


func _face_walk_direction() -> void:
	if velocity.x * velocity.x + velocity.z * velocity.z < 0.0025:
		return
	_turn_toward(atan2(-velocity.x, -velocity.z))


func _turn_toward(target_yaw: float) -> void:
	var delta: float = wrapf(target_yaw - rotation.y, -PI, PI)
	rotation.y += clampf(delta, -_AI_MAX_YAW_STEP, _AI_MAX_YAW_STEP)


# --- Drops ---


# `g_()` gives cooked porkchop and nothing else. The gold sword is a
# render-only held item in Alpha — `pt` has no drop override for it, and
# the gold-nugget drop is a much later addition. Both deliberately absent.
func _spawn_drops() -> void:
	super._spawn_drops()


# --- Animation ---


func _advance_walk_animation(delta: float) -> void:
	_age_seconds += delta
	if _swing_remaining_sec > 0.0:
		_swing_remaining_sec = maxf(0.0, _swing_remaining_sec - delta)
	var sp_sq: float = velocity.x * velocity.x + velocity.z * velocity.z
	var speed: float = sqrt(sp_sq) if sp_sq > 0.0001 else 0.0
	var target_amount: float = clampf(speed / _AI_WALK_SPEED_ANGRY, 0.0, 1.0)
	_walk_anim_amount = lerpf(
		_walk_anim_amount, target_amount, minf(_WALK_ANIM_LERP_PER_SEC * delta, 1.0)
	)
	_walk_dist += _walk_anim_amount * delta * _WALK_DIST_SCALE
	var leg_swing: float = cos(_walk_dist * _WALK_FREQ) * _LEG_AMPLITUDE * _walk_anim_amount
	if _leg_l_pivot != null:
		_leg_l_pivot.rotation.x = leg_swing
	if _leg_r_pivot != null:
		_leg_r_pivot.rotation.x = -leg_swing
	_apply_arm_pose()
	_step_accum += speed * delta
	if _step_accum >= _STEP_STRIDE:
		_step_accum -= _STEP_STRIDE
		_play_step()


# ModelZombie's locked-horizontal arms plus the Beta chomp — identical to
# the zombie, because the renderer map hands `pt` the same `ck.java`.
func _apply_arm_pose() -> void:
	var swing: float = 0.0
	if _swing_remaining_sec > 0.0:
		swing = 1.0 - (_swing_remaining_sec / _SWING_DURATION_SEC)
	var inv: float = 1.0 - swing
	var chomp_pitch: float = sin(swing * PI) * 1.2 - sin((1.0 - inv * inv) * PI) * 0.4
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
	if _chunk_manager.get_world_block(below) == Blocks.AIR:
		return
	SFX.play_pigman_step(global_position)


# --- SFX ---
#
# `d()`, `f_()`, `f()` and the `e_()` shout name the four
# `mob.zombiepig.*` events. The OGGs are not in the repo; SFX resolves
# them silently until they are, per plan section 11.


func _play_idle_sfx() -> void:
	SFX.play_pigman_say(global_position)


func _play_hurt_sfx() -> void:
	SFX.play_pigman_hurt(global_position)


func _play_death_sfx() -> void:
	SFX.play_pigman_death(global_position)


func _play_angry_sfx() -> void:
	SFX.play_pigman_angry(global_position)
