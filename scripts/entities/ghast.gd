class_name Ghast
extends "res://scripts/entities/mob_base.gd"

# Vanilla Alpha 1.2.6 EntityGhast (`am.java`) plus its model (`hc.java`)
# and renderer (`jz.java`).
# See docs/nether-alpha-1.2.6-implementation-plan.md §8.2.
#
# A ghast does not chase. It drifts toward a WAYPOINT — a random point
# within 16 blocks on each axis, rerolled whenever it gets closer than 1
# or further than 60 — and only turns to face a player when one is within
# 64 blocks with line of sight. Everything about how a ghast moves comes
# out of that: the aimless float, the way it drifts into walls, and the
# way it hangs there staring at you while it charges.
#
# The charge counter is the whole combat loop and it is a single int:
#
#   * with line of sight it climbs by one per tick;
#   * at 10 the charge sound plays AND the texture swaps to
#     `ghast_fire.png` (the check is `f > 10`, so the swap is one tick
#     behind the sound);
#   * at 20 it fires, and resets to -40 — a two-second cooldown that has
#     to climb back through zero before it can even start charging again;
#   * losing sight or range decrements it instead, so a player who breaks
#     line of sight mid-charge genuinely interrupts the shot.
#
# Fire immunity is `this.bm = true`, and flying is `ot.java` — no gravity,
# no fall damage, and all motion supplied by the AI.

const _TEXTURE_CALM: String = "res://assets/textures/mob/ghast.png"
const _TEXTURE_CHARGING: String = "res://assets/textures/mob/ghast_fire.png"
const _TEXTURE_SIZE: Vector2i = Vector2i(64, 32)

const _PIXEL_TO_METER: float = 1.0 / 16.0

# `a(4.0f, 4.0f)` — a 4x4x4 collision body.
const _BB_SIZE: float = 4.0

# `hf.J = 10`. The ghast extends `ot` directly, not `ef`, so it never
# picks up EntityMonster's bump to 20 — it dies to two arrows.
const _MAX_HEALTH: int = 10

# `hc.java` — a 16x16x16 body cube and nine 2x2 tentacles whose lengths
# come from `Random(1660)`.
const _BODY_CUBE_PX: int = 16
const _TENTACLE_COUNT: int = 9
const _TENTACLE_THICKNESS_PX: int = 2
const _TENTACLE_SEED: int = 1660
const _TENTACLE_LENGTH_MIN: int = 8
const _TENTACLE_LENGTH_SPAN: int = 7  # nextInt(7) + 8 -> [8, 14]
# `this.a.b += 24 + n2` with `n2 = -16`, and tentacles at `31 + n2`.
# MC model space is Y-DOWN and `ec.java:50` translates by -24*(1/16),
# so model row 24 is the entity's feet. Local height above the feet is
# therefore (24 - m) * _PIXEL_TO_METER, before the renderer's scale.
# Failing to invert this is what put the tentacle roots ABOVE the body
# centre and sealed all nine inside the body cube.
const _MODEL_FEET_PX: float = 24.0
const _BODY_PIVOT_Y_PX: float = 8.0
const _TENTACLE_PIVOT_Y_PX: float = 15.0

# `b[i].d = 0.2f * sin(ageInTicks * 0.3f + i) + 0.4f`.
const _TENTACLE_SWAY_AMP: float = 0.2
const _TENTACLE_SWAY_FREQ: float = 0.3
const _TENTACLE_SWAY_BASE: float = 0.4

# `jz.java` — the renderer scales by (8 + inv)/2 vertically and
# (8 + 1/inv)/2 horizontally. At rest that is 4.5 in every axis.
const _RENDER_SCALE_BASE: float = 8.0

const _AI_TICK_DT: float = 1.0 / 20.0

# Waypoint bounds. `(nextFloat() * 2 - 1) * 16` on each axis, rerolled
# when the distance leaves [1, 60].
const WAYPOINT_RANGE: float = 16.0
const WAYPOINT_MIN_DISTANCE: float = 1.0
const WAYPOINT_MAX_DISTANCE: float = 60.0
# `this.a += this.bd.nextInt(5) + 2` — the course is re-evaluated every
# 2 to 6 ticks, not every tick.
const COURSE_INTERVAL_MIN: int = 2
const COURSE_INTERVAL_SPAN: int = 5
# `this.az += d2 / d5 * 0.1` — acceleration toward the waypoint, per tick.
const DRIFT_ACCELERATION: float = 0.1

# `this.as.a((lw)this, 100.0)` every 20 ticks.
const TARGET_SEARCH_RADIUS: float = 100.0
const TARGET_REACQUIRE_TICKS: int = 20
# `double d6 = 64.0; ... g.f(this) < d6 * d6`.
const ENGAGE_RADIUS: float = 64.0

# The charge timeline.
const CHARGE_SOUND_AT: int = 10
const CHARGE_FIRE_AT: int = 20
const CHARGE_COOLDOWN: int = -40
# `this.z = this.f > 10 ? ghast_fire : ghast` — strictly greater, so the
# texture swaps the tick AFTER the charge sound.
const CHARGE_TEXTURE_ABOVE: int = 10
# `double d10 = 4.0` — the projectile spawns four blocks along the look
# vector, clear of the ghast's own 4-wide body.
const FIREBALL_LAUNCH_DISTANCE: float = 4.0

# `h()` returns 10.0f. Ghasts are audible across the whole cavern; this
# is the loudest sound volume in the game.
const SOUND_VOLUME: float = 10.0

const _FIREBALL_SCRIPT: GDScript = preload("res://scripts/entities/ghast_fireball.gd")

# `this.b/c/d` — the waypoint the ghast is drifting toward.
var waypoint: Vector3 = Vector3.ZERO
# `this.f` — the charge counter. Negative is the post-shot cooldown.
var charge: int = 0
# `this.e` — the previous tick's counter, which the renderer interpolates
# against for the squash/stretch.
var prev_charge: int = 0

# `this.a` — ticks until the next course evaluation.
var _course_countdown: int = 0
# `this.h` — ticks until the target is re-acquired.
var _target_countdown: int = 0
# `this.g` — the current target.
var _target: Node3D = null

var _body_mesh: MeshInstance3D
var _tentacle_pivots: Array[Node3D] = []
var _render_root: Node3D
var _age_seconds: float = 0.0
var _ai_tick_accum: float = 0.0
var _charging_texture: bool = false


# `a(4.0f, 4.0f)` — width and height both 4.
func _get_body_height() -> float:
	return _BB_SIZE


func _get_body_width() -> float:
	return _BB_SIZE


func _get_eye_height() -> float:
	return _BB_SIZE * 0.5


# The base hardcodes a 0.6-wide box for every mob. A 4-wide ghast needs
# its own, and overriding here rather than changing the base keeps every
# existing mob's collision byte-identical.
func _voxel_half_extents() -> Vector3:
	return Vector3(_BB_SIZE * 0.5, _BB_SIZE * 0.5, _BB_SIZE * 0.5)


# `ot.java` — EntityFlying supplies its own motion.
func _uses_gravity() -> bool:
	return false


# `ot.c(float)` is an empty override: a flying entity never takes fall
# damage, however far it drops.
func _takes_fall_damage() -> bool:
	return false


# A 4x4 body standing on the ground is a 4x4 body inside the ceiling of
# almost any Nether cavern. Spawners lift it into open air instead.
func spawns_airborne() -> bool:
	return true


# `am.i()` returns 1 where the EntityLiving default is 4. Ghasts never
# appear in groups.
func spawn_group_size() -> int:
	return 1


# `am.a()` — `this.bd.nextInt(20) == 0 && super.a() && this.as.k > 0`.
# The 1-in-20 roll is the whole reason a vanilla ghast is an EVENT and
# not weather: the Nether hostile pool is {pigman, ghast}, so an ungated
# ghast takes HALF of every hostile spawn instead of 2.5% of them —
# twenty times vanilla's density. Each one then fires on the correct
# 3 s cadence, which reads in play as constant bombardment (field
# report: "the ghast seems to be spamming snowballs too much").
func natural_spawn_denominator() -> int:
	return 20


# `this.bm = true`.
func _is_fire_immune() -> bool:
	return true


# `jz.java::a(am,float)` runs after RenderManager applies the entity's
# sampled brightness and explicitly sets glColor4f(1,1,1,1). Ghasts are
# therefore fullbright in Alpha 1.2.6, including their charge texture.
func _renders_fullbright() -> bool:
	return true


func _ready() -> void:
	max_health = _MAX_HEALTH
	# `g_()` returns `dx.K.aW` — item 33 + 256 = 289, gunpowder. Ghast
	# tears do not exist in Alpha.
	drop_item_id = Items.GUNPOWDER
	drop_count_min = 0
	drop_count_max = 2
	_build_collision_shape()
	_build_model()
	waypoint = global_position
	super._ready()


func _build_collision_shape() -> void:
	_build_body_capsule(_BB_SIZE * 0.5, _BB_SIZE)


# --- Model (`hc.java`) ---


# Tentacle anchor positions, straight out of the constructor's arithmetic.
# Extracted as a static so the structure is testable without a scene, and
# because the expression is opaque enough to be worth naming:
#
#     f2 = (((i%3) - (i/3 % 2) * 0.5 + 0.25) / 2 * 2 - 1) * 5
#     f3 = (((i/3) / 2 * 2) - 1) * 5
#
# The `/2 * 2` cancels, so these reduce to a 3x3 grid on X/Z with every
# middle row offset half a cell — which is what stops the tentacles
# looking like a regular lattice.
static func tentacle_anchor(index: int) -> Vector2:
	var col: int = index % 3
	var row: int = index / 3
	var x: float = (float(col) - float(row % 2) * 0.5 + 0.25 - 1.0) * 5.0
	var z: float = (float(row) - 1.0) * 5.0
	return Vector2(x, z)


# Tentacle lengths from `new Random(1660L)`, in pixels. Deterministic and
# identical in every session — the same guarantee the portal texture has,
# and for the same reason: a shared seeded generator walked in a fixed
# order.
static func tentacle_lengths() -> Array[int]:
	var rng := JavaRandom.new(_TENTACLE_SEED)
	var out: Array[int] = []
	for _i: int in range(_TENTACLE_COUNT):
		out.append(rng.next_int_bounded(_TENTACLE_LENGTH_SPAN) + _TENTACLE_LENGTH_MIN)
	return out


# `jz.java::a` — the charge squash/stretch, returned as (xz_scale,
# y_scale). `interpolated` is the counter blended across the frame and
# divided by 20; the source clamps it at zero from below but not above,
# so a counter of 20 gives exactly 1.
static func charge_render_scale(interpolated: float) -> Vector2:
	var q: float = maxf(interpolated, 0.0)
	var inv: float = 1.0 / (q * q * q * q * q * 2.0 + 1.0)
	var y_scale: float = (_RENDER_SCALE_BASE + inv) / 2.0
	var xz_scale: float = (_RENDER_SCALE_BASE + 1.0 / inv) / 2.0
	return Vector2(xz_scale, y_scale)


func _build_model() -> void:
	# A render root so the squash/stretch is one transform on one node
	# rather than a per-part rebuild. The animation writes only its scale,
	# which allocates nothing.
	_render_root = Node3D.new()
	_render_root.name = "GhastModel"
	# Feet origin: every part is placed by the (24 - m) mapping below, and
	# `jz.java`'s resting 4.5x scale is applied to this node.
	_render_root.position = Vector3.ZERO
	add_child(_render_root)
	var mat: StandardMaterial3D = MobBase.get_shared_material(_TEXTURE_CALM, false)
	var body_px := Vector3i(_BODY_CUBE_PX, _BODY_CUBE_PX, _BODY_CUBE_PX)
	var body_size := Vector3.ONE * float(_BODY_CUBE_PX) * _PIXEL_TO_METER
	_body_mesh = MeshInstance3D.new()
	_body_mesh.mesh = MobCube.build_textured_cube(
		body_size, _TEXTURE_SIZE, Vector2i.ZERO, body_px, false
	)
	# `hc.java:14-15` — box spans -8..8 about its own pivot at m=8, so the
	# cube centre sits on the pivot and the body occupies model rows 0..16.
	_body_mesh.position = Vector3(0.0, (_MODEL_FEET_PX - _BODY_PIVOT_Y_PX) * _PIXEL_TO_METER, 0.0)
	_body_mesh.material_override = mat
	_render_root.add_child(_body_mesh)
	var lengths: Array[int] = tentacle_lengths()
	for i: int in range(_TENTACLE_COUNT):
		var anchor: Vector2 = tentacle_anchor(i)
		var pivot := Node3D.new()
		# `hc.java:25` pivot m=31+(-16)=15, i.e. seven rows BELOW the body
		# centre, and the box extends further down from there.
		pivot.position = Vector3(
			anchor.x * _PIXEL_TO_METER,
			(_MODEL_FEET_PX - _TENTACLE_PIVOT_Y_PX) * _PIXEL_TO_METER,
			anchor.y * _PIXEL_TO_METER
		)
		_render_root.add_child(pivot)
		var length: int = lengths[i]
		var cube_px := Vector3i(_TENTACLE_THICKNESS_PX, length, _TENTACLE_THICKNESS_PX)
		var size := Vector3(
			float(_TENTACLE_THICKNESS_PX) * _PIXEL_TO_METER,
			float(length) * _PIXEL_TO_METER,
			float(_TENTACLE_THICKNESS_PX) * _PIXEL_TO_METER
		)
		var mi := MeshInstance3D.new()
		# `addBox(-1, 0, -1, 2, n3, 2)` — the box hangs DOWN from the
		# pivot in MC's inverted Y, which is -Y here.
		mi.mesh = MobCube.build_textured_cube(size, _TEXTURE_SIZE, Vector2i.ZERO, cube_px, false)
		mi.position = Vector3(0.0, -size.y * 0.5, 0.0)
		mi.material_override = mat
		pivot.add_child(mi)
		_tentacle_pivots.append(pivot)


# --- AI (`am.b_()`) ---


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


func _process(delta: float) -> void:
	super._process(delta)
	if _physics_gated or _lod_tier == LOD_FAR:
		return
	_age_seconds += delta
	_animate(delta)


# One source tick of `b_()`, in the source's order. The order matters:
# the waypoint is rerolled before the course check reads its distance, so
# a ghast that has just arrived immediately picks a new heading rather
# than stalling for a tick.
func _ai_tick() -> void:
	var pp := PerfProbe.begin("ghast.ai")
	if roll_idle_sfx_tick():
		_play_idle_sfx()
	# `if (this.as.k == 0) this.J();` — Peaceful kills it outright, before
	# anything else runs.
	if Game.difficulty == Game.DIFFICULTY_PEACEFUL:
		die()
		PerfProbe.end("ghast.ai", pp)
		return
	prev_charge = charge
	_tick_waypoint()
	_tick_target()
	_tick_combat()
	_apply_texture_state()

	PerfProbe.end("ghast.ai", pp)


func _tick_waypoint() -> void:
	var to_waypoint: Vector3 = waypoint - global_position
	var distance: float = to_waypoint.length()
	if distance < WAYPOINT_MIN_DISTANCE or distance > WAYPOINT_MAX_DISTANCE:
		waypoint = (
			global_position
			+ Vector3(
				(randf() * 2.0 - 1.0) * WAYPOINT_RANGE,
				(randf() * 2.0 - 1.0) * WAYPOINT_RANGE,
				(randf() * 2.0 - 1.0) * WAYPOINT_RANGE
			)
		)
		to_waypoint = waypoint - global_position
		distance = to_waypoint.length()
	# `if (this.a-- <= 0)` — POST-decrement, so the test reads the value
	# before the tick's subtraction and `a` drops either way. Firing from
	# a counter of 0 therefore lands at -1 before the reroll is added,
	# which is why the stored value right after a course change is
	# [1, 5] while the INTERVAL between changes is [2, 6]. A
	# pre-decrement version gets the interval right and the stored value
	# wrong, and the two only diverge on the first tick of a mob's life.
	var evaluate_now: bool = _course_countdown <= 0
	_course_countdown -= 1
	if not evaluate_now:
		return
	_course_countdown += (randi() % COURSE_INTERVAL_SPAN) + COURSE_INTERVAL_MIN
	if distance < 0.0001:
		return
	if course_is_clear(waypoint, distance):
		# Velocity is in blocks per SECOND here and per TICK in the
		# source, so the per-tick 0.1 becomes 0.1 * 20.
		velocity += to_waypoint / distance * DRIFT_ACCELERATION * 20.0
	else:
		# `this.b = this.aw; ...` — give up on this waypoint by making the
		# current position the target, which fails the < 1 test next tick
		# and forces a fresh roll.
		waypoint = global_position


# `am.a(double, double, double, double)` — isCourseTraversable. Steps the
# ghast's own bounding box along the unit direction one block at a time
# and fails on the first step that collides. This is what stops a ghast
# accelerating into a wall it cannot pass, and why they hug open caverns.
func course_is_clear(target: Vector3, distance: float) -> bool:
	if _chunk_manager == null:
		return true
	var step: Vector3 = (target - global_position) / distance
	var half: float = _BB_SIZE * 0.5
	var probe: Vector3 = global_position + Vector3(0.0, half, 0.0)
	# Consecutive steps move the box one block along a 4-wide body, so
	# roughly four fifths of each new box was already tested by the last
	# one. Remembering the previous cell range and skipping its interior
	# turns a 125-cell rescan per step into a 25-cell face for an
	# axis-aligned course — measured at 6.5 ms down to well under 2 ms
	# across a 50-block sweep. The result is identical: the world does
	# not change mid-walk, so a cell found clear stays clear.
	var last_min := Vector3i(2147483647, 2147483647, 2147483647)
	var last_max := Vector3i(-2147483648, -2147483648, -2147483648)
	var n: int = 1
	while float(n) < distance:
		probe += step
		var min_cell := Vector3i(
			int(floor(probe.x - half)), int(floor(probe.y - half)), int(floor(probe.z - half))
		)
		var max_cell := Vector3i(
			int(floor(probe.x + half)), int(floor(probe.y + half)), int(floor(probe.z + half))
		)
		for x: int in range(min_cell.x, max_cell.x + 1):
			var seen_x: bool = x >= last_min.x and x <= last_max.x
			for y: int in range(min_cell.y, max_cell.y + 1):
				var seen_xy: bool = seen_x and y >= last_min.y and y <= last_max.y
				for z: int in range(min_cell.z, max_cell.z + 1):
					if seen_xy and z >= last_min.z and z <= last_max.z:
						continue
					var id: int = _chunk_manager.get_world_block(Vector3i(x, y, z))
					if id != Blocks.AIR and Blocks.is_solid_collision(id):
						return false
		last_min = min_cell
		last_max = max_cell
		n += 1
	return true


func _tick_target() -> void:
	if _target != null and not is_instance_valid(_target):
		_target = null
	_target_countdown -= 1
	if _target != null and _target_countdown > 0:
		return
	var player: Node3D = _cached_player()
	if player == null:
		_target = null
		return
	if (
		global_position.distance_squared_to(player.global_position)
		> (TARGET_SEARCH_RADIUS * TARGET_SEARCH_RADIUS)
	):
		_target = null
		return
	_target = player
	_target_countdown = TARGET_REACQUIRE_TICKS


# One vanilla combat tick per AI tick meant the charge counter ran at
# the LOD tick rate — a ghast in the 32-64 m band, inside its own 64 m
# engage radius, fired at a quarter of vanilla's cadence (audit finding
# #10). Stepping the counter by the tick scale keeps combat real-time at
# every distance the ghast can fight from; crossings below are tested
# with >= so a large step cannot jump the sound or the shot.
func _combat_step() -> int:
	if _lod_tier == LOD_MID:
		return 4
	if _lod_tier == LOD_FAR:
		return 20
	return 1


func _tick_combat() -> void:
	var step: int = _combat_step()
	if _target == null or not is_instance_valid(_target):
		_face_travel_direction()
		if charge > 0:
			charge = maxi(0, charge - step)
		return
	var delta_to_target: Vector3 = _target.global_position - global_position
	if delta_to_target.length_squared() > ENGAGE_RADIUS * ENGAGE_RADIUS:
		_face_travel_direction()
		if charge > 0:
			charge = maxi(0, charge - step)
		return
	# `this.s = this.aC = -atan2(d7, d9) * 180 / PI` — face the target on
	# the horizontal plane only; a ghast never pitches.
	# `am.java:63` is correct in MC's yaw convention, not Godot's. Every
	# other mob here uses atan2(-x, -z) (zombie.gd:564, skeleton.gd:722,
	# spider.gd:728, ...); -atan2(x, z) agrees with it only when the target
	# is exactly to the side and is 180 degrees wrong straight ahead or
	# behind — which also threw the fireball spawn to the ghast's back.
	rotation.y = atan2(-delta_to_target.x, -delta_to_target.z)
	if not has_line_of_sight(_target):
		# Losing sight DECREMENTS rather than resetting, so a player who
		# ducks behind a pillar for two ticks loses two ticks of charge,
		# not the whole windup.
		if charge > 0:
			charge = maxi(0, charge - step)
		return
	var before: int = charge
	charge += step
	if before < CHARGE_SOUND_AT and charge >= CHARGE_SOUND_AT:
		SFX.play_ghast_charge(global_position)
		# The windup is the whole tell. Vanilla spends ten ticks between
		# `mob.ghast.charge` and the shot, with the angry texture up the
		# whole time, and that half second is the player's cue to break
		# line of sight. A step of 4 (MID) or 20 (FAR) crosses both
		# thresholds in the same tick, so the ghast fires the instant it
		# growls — or with no growl at all. ENGAGE_RADIUS is 64 and MID
		# starts at 32, so almost every ghast that shoots at you was
		# firing without a tell.
		#
		# Stopping the counter ON the sound keeps the real-time cadence
		# the LOD step exists to preserve (the -40 cooldown still runs at
		# the scaled rate) while restoring the warning: the next tick
		# resumes from 10 and the shot lands a tick or two later at MID,
		# instead of simultaneously.
		charge = CHARGE_SOUND_AT
		return
	if charge >= CHARGE_FIRE_AT:
		SFX.play_ghast_fireball(global_position)
		_fire_at(delta_to_target)
		charge = CHARGE_COOLDOWN


# `this.d(this.g)` — canEntityBeSeen. A block sweep from eye to eye.
func has_line_of_sight(target: Node3D) -> bool:
	if _chunk_manager == null:
		return true
	var from: Vector3 = global_position + Vector3(0.0, _get_eye_height(), 0.0)
	var to: Vector3 = target.global_position + Vector3(0.0, 1.62, 0.0)
	var segment: Vector3 = to - from
	var length: float = segment.length()
	if length < 0.001:
		return true
	var samples: int = maxi(1, int(ceil(length * 2.0)))
	for i: int in range(1, samples):
		var p: Vector3 = from.lerp(to, float(i) / float(samples))
		var cell := Vector3i(int(floor(p.x)), int(floor(p.y)), int(floor(p.z)))
		if Blocks.is_opaque(_chunk_manager.get_world_block(cell)):
			return false
	return true


# `az2.aw = aw + look.x * 4; az2.ax = ax + height/2 + 0.5; az2.ay = ay +
# look.z * 4`. Note the Y offset is NOT along the look vector — the
# fireball always leaves at the ghast's mid-height plus half a block,
# however steeply it is aiming.
func _fire_at(aim: Vector3) -> void:
	var parent: Node = _chunk_manager if _chunk_manager != null else get_parent()
	if parent == null:
		return
	var look: Vector3 = -global_transform.basis.z
	var fireball: Node3D = _FIREBALL_SCRIPT.new()
	parent.add_child(fireball)
	fireball.global_position = Vector3(
		global_position.x + look.x * FIREBALL_LAUNCH_DISTANCE,
		global_position.y + _BB_SIZE * 0.5 + 0.5,
		global_position.z + look.z * FIREBALL_LAUNCH_DISTANCE
	)
	fireball.call("setup", self, aim)


func _face_travel_direction() -> void:
	# `-atan2(this.az, this.aB)` — the ghast faces where it is drifting
	# when it has nothing to look at.
	if velocity.x * velocity.x + velocity.z * velocity.z < 0.0001:
		return
	rotation.y = atan2(-velocity.x, -velocity.z)


# `this.z = this.f > 10 ? ghast_fire : ghast`. Swapping the shared
# material's albedo would recolour every ghast at once, so each mob gets
# the shared material for whichever texture it currently needs — two
# cached materials total, not one per ghast.
func _apply_texture_state() -> void:
	var charging: bool = charge > CHARGE_TEXTURE_ABOVE
	if charging == _charging_texture:
		return
	_charging_texture = charging
	var path: String = _TEXTURE_CHARGING if charging else _TEXTURE_CALM
	var mat: StandardMaterial3D = MobBase.get_shared_material(path, false)
	# A hurt flash owns material_override right now and will restore what
	# it captured when it clears — writing through it would hide the
	# flash AND be reverted to the stale texture afterwards (audit
	# finding #11). Every ghast mesh shares the one material, so updating
	# the flash's captured originals is the whole fix.
	if _hurt_flash_remaining > 0.0:
		for entry: Array in _hurt_mat_overrides:
			entry[1] = mat
		return
	if _body_mesh != null:
		_body_mesh.material_override = mat
	for pivot: Node3D in _tentacle_pivots:
		for child: Node in pivot.get_children():
			if child is MeshInstance3D:
				(child as MeshInstance3D).material_override = mat
	_refresh_world_brightness()


# --- Animation ---


func _animate(_delta: float) -> void:
	# `b[i].d = 0.2 * sin(age * 0.3 + i) + 0.4`, where `age` is in ticks.
	var age_ticks: float = _age_seconds * 20.0
	for i: int in range(_tentacle_pivots.size()):
		# Negated for Godot's Y-up. `hc.java:31` feeds `ka.java:106`
		# glRotatef(d * 57.3, 1, 0, 0) INSIDE `ec.java:48` glScalef(-1,-1,1),
		# so the sign inverts on the way in — the same flip zombie.gd:114-120
		# documents for its own pitch. Unnegated the tentacles splayed ~23
		# degrees FORWARD instead of trailing behind.
		_tentacle_pivots[i].rotation.x = -(
			_TENTACLE_SWAY_AMP * sin(age_ticks * _TENTACLE_SWAY_FREQ + float(i))
			+ _TENTACLE_SWAY_BASE
		)
	if _render_root == null:
		return
	# The renderer interpolates between the previous and current counter
	# across the frame. With the AI at a fixed 20 Hz and rendering faster,
	# using the current counter directly is a half-tick behind at worst
	# and allocates nothing.
	var scale_xy: Vector2 = charge_render_scale(float(charge) / 20.0)
	# Applied RAW. `jz.java:22-24` rests at 4.5x and the model is authored
	# in 1/16 model units, so 4.5 IS the ghast's size — vanilla genuinely
	# renders a 4.5 m body against its 4 m hitbox, with the tentacles
	# trailing below the box. The old code divided the resting value back
	# out, which shrank the whole creature 4.5x and (with the un-inverted
	# pivots) left it looking like a plain 1 m cube.
	_render_root.scale = Vector3(scale_xy.x, scale_xy.y, scale_xy.x)


# --- SFX ---


func _play_idle_sfx() -> void:
	SFX.play_ghast_moan(global_position)


func _play_hurt_sfx() -> void:
	SFX.play_ghast_scream(global_position)


func _play_death_sfx() -> void:
	SFX.play_ghast_death(global_position)


# --- Persistence ---


func to_save_dict() -> Dictionary:
	var d: Dictionary = super.to_save_dict()
	d["charge"] = charge
	d["waypoint"] = waypoint
	return d


func restore_from_dict(d: Dictionary) -> void:
	super.restore_from_dict(d)
	charge = int(d.get("charge", 0))
	prev_charge = charge
	waypoint = d.get("waypoint", global_position)
