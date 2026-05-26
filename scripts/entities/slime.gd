class_name Slime
extends "res://scripts/entities/mob_base.gd"

# Vanilla Alpha 1.2.6 EntitySlime (`ns.java`). Hops around as a green
# cube, bounces off the ground every 10-30 ticks, splits into 4
# smaller slimes on death when size > 1, drops 0-2 slimeballs from
# size-1 slimes only.
#
# Spawn rules (vanilla `ns.java::a()`):
#   * Slime chunks ONLY: `world.chunk.random(987234911L).nextInt(10) == 0`
#     — 1-in-10 chunks per world seed, deterministic. See
#     `is_slime_chunk` below for our hash-based equivalent.
#   * Y < 16 (deep underground). Caves are the only place slimes spawn.
#   * Slimes IGNORE the normal hostile light gate (vanilla `ns::a()`
#     does NOT call `getBlockLightValue` — they can spawn in lit caves
#     as long as the chunk + Y check passes). Spawner upstream gates
#     by the chunk + Y rule alone.
#
# Size variants (vanilla):
#   * c = 1 << random.nextInt(3) → 1, 2, or 4.
#   * Body collision: 0.6 × c m wide / tall.
#   * HP: c² (1, 4, 16).
#   * Drop: size 1 → 0-2 slimeballs. Larger sizes drop nothing
#     directly but spawn 4 half-size children on death.
#
# Visual: vanilla `ik.java` ModelSlime has an OUTER translucent 8×8×8
# cube + INNER 6×6×6 core + 2 eye cubes + 1 mouth cube. We ship the
# outer-only single cube + inner core for v1; eyes/mouth are
# cosmetic and can land in a polish pass. Body texture is the
# 64×32 `mob/slime.png` extracted from the Alpha jar.

const _SLIME_TEXTURE_PATH: String = "res://assets/textures/mob/slime.png"
const _SLIME_TEXTURE_SIZE: Vector2i = Vector2i(64, 32)

# Vanilla cube dimensions + UV origins (from `ik.java`).
#   * Outer SHELL — translucent, 8×8×8 at UV (0, 0). Vanilla `ik(0)`
#     model — first pass, alpha-blended.
#   * Inner CORE — opaque, 6×6×6 at UV (0, 16). Vanilla `ik(16)` model
#     (the conditional `n2 > 0` branch swaps the 8×8 outer for the
#     6×6 inner at UV (0, 16)). Rendered second pass, opaque.
#   * Two eyes — 2×2×2 cubes at UV (32, 0) and (32, 4). Part of the
#     `ik(16)` model alongside the inner core.
#   * Mouth — 1×1×1 cube at UV (32, 8). Same pass as eyes.
const _OUTER_CUBE_PX: Vector3i = Vector3i(8, 8, 8)
const _OUTER_TEX_ORIGIN: Vector2i = Vector2i(0, 0)
const _INNER_CUBE_PX: Vector3i = Vector3i(6, 6, 6)
const _INNER_TEX_ORIGIN: Vector2i = Vector2i(0, 16)
const _EYE_CUBE_PX: Vector3i = Vector3i(2, 2, 2)
const _EYE_L_TEX_ORIGIN: Vector2i = Vector2i(32, 0)
const _EYE_R_TEX_ORIGIN: Vector2i = Vector2i(32, 4)
const _MOUTH_CUBE_PX: Vector3i = Vector3i(1, 1, 1)
const _MOUTH_TEX_ORIGIN: Vector2i = Vector2i(32, 8)
const _PIXEL_TO_METER: float = 1.0 / 16.0

# Vanilla eye + mouth offsets in pixel units, relative to the body
# CENTER (model space). Vanilla `ik.java`:
#   * Body cube spans vanilla y ∈ [16, 24] → center at vanilla y=20.
#   * Eye L origin (-3.25, 18, -3.5) size 2 → center (-2.25, 19, -2.5).
#     Relative to body center (0, 20, 0) → (-2.25, -1, -2.5).
#   * Eye R origin ( 1.25, 18, -3.5) size 2 → center  (2.25, 19, -2.5).
#     Relative → (2.25, -1, -2.5).
#   * Mouth origin ( 0.0, 21, -3.5) size 1 → center (0.5, 21.5, -3.0).
#     Relative → (0.5, 1.5, -3).
# Conversion to Godot space:
#   * Y: vanilla axis points DOWN (Y=24 is feet); we flip sign so
#     vanilla "above center" becomes Godot "above center".
#   * Z: vanilla front = -Z AND our locomotion convention (Godot
#     default) also has local -Z as the mob's forward direction. So
#     no flip needed — eyes/mouth land on the leading edge of the hop.
#     (The MobCube body's "front" UV unfold position on +Z is
#     irrelevant for the slime since the outer body is uniform green;
#     what matters is matching the hop direction.)
const _EYE_L_OFFSET_PX: Vector3 = Vector3(-2.25, 1.0, -2.5)
const _EYE_R_OFFSET_PX: Vector3 = Vector3(2.25, 1.0, -2.5)
const _MOUTH_OFFSET_PX: Vector3 = Vector3(0.5, -1.5, -3.0)

# AI tick rate — 20 Hz integer-tick parity with vanilla.
const _AI_TICK_DT: float = 1.0 / 20.0

# Vanilla `ns.java::b_()` sets `d = nextInt(20) + 10` ticks between
# hops when grounded. 10-30 ticks = 0.5-1.5 s @ 20 tps.
const _HOP_INTERVAL_MIN_TICKS: int = 10
const _HOP_INTERVAL_MAX_TICKS: int = 30
# Per-hop kick. Vanilla applies a per-tick impulse scaled by size,
# but our move_and_slide uses m/s. These values were tuned so a
# size-1 slime hops ~1 block forward and ~0.5 m high — clearly
# "bouncy" without launching across the room.
const _HOP_VELOCITY_Y_BASE: float = 4.5
const _HOP_VELOCITY_HORIZONTAL_BASE: float = 1.4

# Target detection. Vanilla `b_()` calls
# `world.getClosestPlayerToEntity(this, 16.0)` and damages with
# `b(target, c)` if size > 1.
const _AI_DETECT_RADIUS: float = 16.0

# Contact attack — vanilla `b(EntityHuman)` requires distance < 0.6×c
# and deals `c` HP. Cooldown is the global iframe (handled by
# Player.take_damage).
const _AI_ATTACK_DAMAGE_PER_SIZE: int = 1

# Spawn-chunk RNG salt. Vanilla `ns.java::a()` seeds a Random with
# `world.seed XOR (chunkMix + 987234911L)`. 1-in-10 chunks pass.
const _SLIME_CHUNK_SALT: int = 987234911
const _SLIME_CHUNK_ODDS: int = 10
# Vanilla uses `ax < 16.0` (Y < 16). Our caves carve a bit higher
# than Alpha — the band [0, 40] gives the same "deep cave" feel
# while still surfacing slimes during normal cave exploration.
const _SLIME_SPAWN_MAX_Y: int = 40

# --- Mutable state ---
# Slime size: 1, 2, or 4. Set once at spawn via setup_size().
var _size: int = 1
# Hop timer — counts DOWN; on zero, fires a hop impulse + resets to a
# random value in [HOP_INTERVAL_MIN_TICKS, HOP_INTERVAL_MAX_TICKS].
var _hop_cooldown_ticks: int = 0
# Per-hop yaw — vanilla rerolls direction each hop.
var _hop_yaw: float = 0.0
var _ai_tick_accum: float = 0.0
# Visual root — parent of outer shell + inner core + eyes + mouth.
# Squash animation scales THIS node so all visuals deform together
# while the underlying CollisionShape3D stays in place.
var _visual_root: Node3D
var _outer_mesh: MeshInstance3D
var _inner_mesh: MeshInstance3D
# Vanilla squash/stretch animation state from `ns.java`:
#   * `_squash` (vanilla `this.a`): current squash factor. Set to
#     1.0 at jump (stretches Y), -0.5 on landing (squashes Y), then
#     decays by 0.6 per tick toward 0.
#   * `_prev_squash` (vanilla `this.b`): saved at start of each tick
#     for per-frame interpolation toward `_squash`.
#   * `_was_on_floor` — landing edge detector. Vanilla checks
#     `aH && !bl2` ("on ground this tick, not last tick") to fire the
#     landing squash.
#   * `_tick_partial` — counts up from 0 to _AI_TICK_DT every frame
#     in `_process`; the ratio is the interp factor passed to the
#     vanilla scale formula.
var _squash: float = 0.0
var _prev_squash: float = 0.0
var _was_on_floor: bool = false
var _tick_partial: float = 0.0
# Cooldown for the attack SFX so we don't spam the clip every
# physics tick while the player is inside the contact range. 1 s
# matches the player's damage-cooldown so SFX cadence lines up with
# the damage cadence.
var _attack_sfx_cooldown_sec: float = 0.0
# Guards the deferred child spawn — `_tick_death_animation` checks
# this once per frame, and we only want the 4 half-size children to
# appear ONCE, right before queue_free fires.
var _split_spawned: bool = false


# True if the given chunk coord is a "slime chunk" for the active
# world seed. Mirrors vanilla `Chunk.getRandomWithSeed(L).nextInt(10)
# == 0` distribution: 1-in-10 chunks, deterministic per coord+seed.
# We don't reproduce java RNG bit-for-bit (Worldgen uses its own
# hashes throughout); the property that matters is "same coord +
# seed = same answer, ~10% pass rate, scattered evenly."
static func is_slime_chunk(world_seed: int, chunk_x: int, chunk_z: int) -> bool:
	var h: int = world_seed
	h ^= chunk_x * 4791777
	h ^= chunk_x * chunk_x * 5949307
	h ^= chunk_z * 389951
	h ^= chunk_z * chunk_z * 4392871
	h ^= _SLIME_CHUNK_SALT
	# xorshift-style mix so adjacent chunks don't bunch.
	h ^= h >> 13
	h *= 1274126177
	h ^= h >> 16
	return (h & 0x7FFFFFFF) % _SLIME_CHUNK_ODDS == 0


# MobBase env overrides — slime BB is size-dependent. Eye height is
# centered (slime is a cube, no separate "head" cell).
func _get_body_height() -> float:
	return 0.6 * float(_size)


func _get_eye_height() -> float:
	return 0.5 * 0.6 * float(_size)


func _get_body_width() -> float:
	return 0.6 * float(_size)


func _ready() -> void:
	# Default to size 1 if setup_size() wasn't called pre-_ready.
	if _size <= 0:
		_size = 1
	max_health = _size * _size  # vanilla J = c²
	# Drop slot — vanilla `ns::g_()` returns SLIMEBALL only when c == 1.
	# Larger slimes drop nothing directly; their loot comes via the
	# 4 half-size children spawned in `_spawn_drops`.
	if _size == 1:
		drop_item_id = Items.SLIMEBALL
		drop_count_min = 0
		drop_count_max = 2
	else:
		drop_item_id = 0
	_build_collision_shape()
	_build_model()
	_hop_cooldown_ticks = randi_range(_HOP_INTERVAL_MIN_TICKS, _HOP_INTERVAL_MAX_TICKS)
	_hop_yaw = randf() * TAU
	super._ready()


# Set the slime's size BEFORE adding to the tree. Once _ready runs,
# size determines HP, BB, and visual scale — calling after spawn is a
# no-op (would require rebuilding the mesh / collider).
func setup_size(size: int) -> void:
	_size = clampi(size, 1, 4)


# Vanilla `ns.java::J()` calls super.J() (drop slimeball) THEN spawns
# 4 children IMMEDIATELY — but in our 3D renderer that means the
# children appear on top of the parent while it's tilting over,
# which reads as a chaotic mess. Deviation: drop the slimeball here
# (vanilla-faithful), but defer the split until the parent's death
# animation finishes (see `_tick_death_animation` override below).
# Net effect: parent tilts and despawns, THEN 4 half-size children
# appear in its place. Same end state as vanilla, cleaner visual.
func _spawn_drops() -> void:
	super._spawn_drops()


# Box collision matches the slime's CUBE visual exactly. The earlier
# capsule (radius = w/2) inscribed inside the cube — its corners stuck
# out beyond the capsule by ~0.22 m at size 1, so arrows flying past
# the corners of a hopping slime missed entirely. A box covers the
# full cube footprint, including corners + edges, so every visible
# part of the slime registers arrow hits.
func _build_collision_shape() -> void:
	var w: float = _get_body_width()
	var h: float = _get_body_height()
	var body_col := CollisionShape3D.new()
	body_col.shape = _cached_box(Vector3(w, h, w))
	body_col.position = Vector3(0.0, h * 0.5, 0.0)
	add_child(body_col)


# Full vanilla ik.java visual: outer 8×8×8 translucent shell, inner
# 6×6×6 opaque core, 2 eyes (2×2×2 each), 1 mouth cube (1×1×1).
# All parented under `_visual_root` so the squash-stretch animation
# can scale them as a unit.
func _build_model() -> void:
	var tex: Texture2D = load(_SLIME_TEXTURE_PATH) as Texture2D
	var outer_size_m: float = float(_OUTER_CUBE_PX.x) * _PIXEL_TO_METER * float(_size)
	var inner_size_m: float = float(_INNER_CUBE_PX.x) * _PIXEL_TO_METER * float(_size)
	var pixel_m: float = _PIXEL_TO_METER * float(_size)
	# Visual root sits at the slime's CENTER (half body height above
	# feet). Children position themselves relative to this root.
	# Squashing scales `_visual_root` so the whole rig deforms; the
	# CollisionShape3D on `self` is unaffected.
	_visual_root = Node3D.new()
	_visual_root.position = Vector3(0.0, outer_size_m * 0.5, 0.0)
	add_child(_visual_root)
	# Outer shell — vanilla `ik(0).a` cube, alpha-blended.
	_outer_mesh = _make_mesh_instance(
		_OUTER_CUBE_PX, outer_size_m, _OUTER_TEX_ORIGIN, _make_outer_material(tex)
	)
	_visual_root.add_child(_outer_mesh)
	# Inner core — vanilla `ik(16).a` cube, opaque, sits centered with
	# the outer shell (both at vanilla model Y=20, our visual root).
	_inner_mesh = _make_mesh_instance(
		_INNER_CUBE_PX, inner_size_m, _INNER_TEX_ORIGIN, _make_inner_material(tex)
	)
	_visual_root.add_child(_inner_mesh)
	# Eyes + mouth — small detail cubes from `ik(16)`. Offsets in
	# `_EYE_L_OFFSET_PX` etc. are already converted to Godot space
	# (Y-flipped + Z-flipped from vanilla model coords). Scale to
	# meters via `pixel_m = (1/16) × size` so each eye stays
	# proportional on bigger slimes.
	var eye_l: MeshInstance3D = _make_mesh_instance(
		_EYE_CUBE_PX,
		float(_EYE_CUBE_PX.x) * pixel_m,
		_EYE_L_TEX_ORIGIN,
		_make_inner_material(tex),
	)
	eye_l.position = _EYE_L_OFFSET_PX * pixel_m
	_visual_root.add_child(eye_l)
	var eye_r: MeshInstance3D = _make_mesh_instance(
		_EYE_CUBE_PX,
		float(_EYE_CUBE_PX.x) * pixel_m,
		_EYE_R_TEX_ORIGIN,
		_make_inner_material(tex),
	)
	eye_r.position = _EYE_R_OFFSET_PX * pixel_m
	_visual_root.add_child(eye_r)
	var mouth: MeshInstance3D = _make_mesh_instance(
		_MOUTH_CUBE_PX,
		float(_MOUTH_CUBE_PX.x) * pixel_m,
		_MOUTH_TEX_ORIGIN,
		_make_inner_material(tex),
	)
	mouth.position = _MOUTH_OFFSET_PX * pixel_m
	_visual_root.add_child(mouth)


# Build a MeshInstance3D for one cube part. `cube_px` is the pixel
# dimensions on the texture sheet, `size_m` is the physical edge
# length in meters (uniform — all slime cubes are cubes).
func _make_mesh_instance(
	cube_px: Vector3i, size_m: float, tex_origin: Vector2i, mat: StandardMaterial3D
) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = MobCube.build_textured_cube(
		Vector3(size_m, size_m, size_m), _SLIME_TEXTURE_SIZE, tex_origin, cube_px, false
	)
	mi.material_override = mat
	return mi


# Outer body material — translucent so the inner core peeks through.
# Vanilla MC renders the outer with alpha-blending; we use a fixed
# 0.6 alpha to keep it simple.
func _make_outer_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.6)
	return mat


# Inner core — fully opaque, same texture sheet, sampled from the
# (0, 0) UV region.
func _make_inner_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	return mat


func _physics_process(delta: float) -> void:
	# Dying slimes still need to FALL during their death animation.
	# Base `MobBase._physics_process` early-returns + zeros velocity
	# when `_dying`, leaving a slime that was mid-hop frozen mid-air.
	# Apply our own minimal physics (gravity + move_and_slide) during
	# death so the cube actually lands. Also keep ticking the squash
	# DECAY — vanilla `e_()` runs every tick regardless of death state,
	# decaying `this.a *= 0.6` so any leftover stretch settles toward
	# neutral over the death window. Skipping that freezes the slime
	# in a permanent stretched pose while it tilts over.
	if _dying:
		if not is_on_floor():
			velocity.y = maxf(velocity.y + GRAVITY * delta, TERMINAL_VELOCITY)
		else:
			if velocity.y < 0.0:
				velocity.y = 0.0
			var f: float = pow(_GROUND_FRICTION, delta)
			velocity.x *= f
			velocity.z *= f
		move_and_slide()
		_ai_tick_accum += delta
		while _ai_tick_accum >= _AI_TICK_DT:
			_ai_tick_accum -= _AI_TICK_DT
			_tick_squash_decay()
		return
	super._physics_process(delta)
	_ai_tick_accum += delta
	while _ai_tick_accum >= _AI_TICK_DT:
		_ai_tick_accum -= _AI_TICK_DT
		_ai_tick()


# Vanilla `e_()` portion that keeps running while dying: save `b = a`,
# then decay `a *= 0.6`. Stripped of AI/landing/attack logic since
# those don't apply once isDead is true.
func _tick_squash_decay() -> void:
	_prev_squash = _squash
	_tick_partial = 0.0
	_squash *= 0.6


# Per-frame squash visual update. Vanilla `ht.a(ns, partial)`:
#   f3 = (b + (a - b) * partial) / (c * 0.5 + 1)
#   f4 = 1 / (f3 + 1)
#   GL.scale(f4 * c, 1/f4 * c, f4 * c)
# Because our base mesh is already sized in real meters per size, we
# only apply the RELATIVE scale (drop the * c factor). f3 > 0 means
# stretched tall (just jumped); f3 < 0 means squashed flat (just
# landed). f3 == 0 is the neutral pose.
#
# `partial` interpolates between the previous-tick and current-tick
# squash values for smooth motion at 60+ fps. Vanilla uses the same
# partialTick concept for all interpolated render state.
#
# IMPORTANT: `super._process` is what drives the hurt-flash decay,
# damage-cooldown decay, fire/stuck-arrow animation, and the death
# animation (tilt + queue_free). Skipping it leaves a damaged slime
# permanently red-tinted, with the cooldown stuck so subsequent hits
# bounce — and a killed slime frozen in mid-air. Always call super.
func _process(delta: float) -> void:
	super._process(delta)
	if _visual_root == null:
		return
	# Squash visual continues during death — vanilla `ht.a()` doesn't
	# gate on deathTime, so the cube stays in its decaying stretch
	# pose while it tilts via the base class's Z rotation.
	# Cap partial at the full AI tick — once we cross over, the next
	# physics frame will run another AI tick and reset.
	_tick_partial = minf(_tick_partial + delta, _AI_TICK_DT)
	var partial: float = _tick_partial / _AI_TICK_DT
	var interp: float = _prev_squash + (_squash - _prev_squash) * partial
	var f3: float = interp / (float(_size) * 0.5 + 1.0)
	var f4: float = 1.0 / (f3 + 1.0)
	_visual_root.scale = Vector3(f4, 1.0 / f4, f4)


# Vanilla `ns.java::b_()` (entity tick):
#   * Find nearest player ≤16 m; if size > 1 and within contact range,
#     damage the player and play attack SFX.
#   * If grounded, count down hop timer; on zero, fire impulse +
#     reset timer. Chase pivots `_hop_yaw` toward the player when one
#     is detected; otherwise random direction (wander).
func _ai_tick() -> void:
	# Vanilla `e_()` saves `b = a` at the start of every entity tick so
	# the renderer can interp from the previous squash factor to the
	# current one. We mirror by snapshotting the value before any
	# state changes happen below.
	_prev_squash = _squash
	# Reset the per-frame partial-tick counter so `_process` starts
	# its interpolation from zero again. Without this, the visual
	# scale snaps mid-tick on hosts running > 20 fps.
	_tick_partial = 0.0
	if _attack_sfx_cooldown_sec > 0.0:
		_attack_sfx_cooldown_sec = maxf(0.0, _attack_sfx_cooldown_sec - _AI_TICK_DT)
	var on_floor_now: bool = is_on_floor()
	var player: Node3D = _find_player()
	if player != null and _size > 1:
		var d: float = global_position.distance_to(player.global_position)
		var attack_range: float = 0.6 * float(_size) + 0.5
		if d < attack_range and player.has_method("take_damage"):
			# Vanilla `ns.b(EntityHuman)` deals `c` HP on contact. Player
			# take_damage returns void, so we can't gate the SFX on a
			# return — play it conditionally on damage-cooldown state
			# instead so we don't spam the clip during the 1 s iframe.
			# `_attack_sfx_cooldown_sec` is a slime-local 1 Hz limiter.
			if _attack_sfx_cooldown_sec <= 0.0:
				SFX.play_slime_attack(global_position)
				_attack_sfx_cooldown_sec = 1.0
			player.call("take_damage", _size * _AI_ATTACK_DAMAGE_PER_SIZE, "mob")
	# Hop logic. Only count down when grounded (vanilla `aH = onGround`).
	if on_floor_now:
		_hop_cooldown_ticks -= 1
		if _hop_cooldown_ticks <= 0:
			_hop_cooldown_ticks = randi_range(_HOP_INTERVAL_MIN_TICKS, _HOP_INTERVAL_MAX_TICKS)
			# If a player is in detect radius, hop TOWARD them; else
			# random direction (vanilla also chases when a target's
			# available, otherwise wanders).
			if player != null:
				var to_player: Vector3 = player.global_position - global_position
				to_player.y = 0.0
				if to_player.length_squared() > 0.01:
					_hop_yaw = atan2(-to_player.x, -to_player.z)
				# Vanilla: timer /= 3 when chasing → bigger slimes hop
				# more often. maxi(1, …) so the result never goes to 0.
				_hop_cooldown_ticks = maxi(1, _hop_cooldown_ticks / 3)
			else:
				_hop_yaw = randf() * TAU
			_do_hop()
	# Landing detection — vanilla `e_()` runs AFTER `b_()` and checks
	# `aH && !bl2` (on-ground this tick but not last). On a positive
	# edge, push the squash NEGATIVE (the cube flattens out as the
	# blob absorbs the impact). Vanilla also spawns 8*c particles
	# here; we skip the particles for v1.
	if on_floor_now and not _was_on_floor:
		_squash = -0.5
	_was_on_floor = on_floor_now
	# Per-tick decay — vanilla `a *= 0.6f` brings the factor smoothly
	# back to neutral over a handful of ticks (after ~10 ticks the
	# residual is < 0.005, indistinguishable from 0).
	_squash *= 0.6


# Apply vertical + horizontal impulse for a hop. Scaled with size —
# bigger slimes hop further AND higher (vanilla EntitySlime kicks
# proportional to `c`).
func _do_hop() -> void:
	var s: float = float(_size)
	velocity.y = _HOP_VELOCITY_Y_BASE + 0.4 * s
	velocity.x = -sin(_hop_yaw) * _HOP_VELOCITY_HORIZONTAL_BASE * s
	velocity.z = -cos(_hop_yaw) * _HOP_VELOCITY_HORIZONTAL_BASE * s
	rotation.y = _hop_yaw
	SFX.play_slime_hop(global_position, _size)


func _find_player() -> Node3D:
	var main: Node = get_tree().root.get_node_or_null("Main")
	if main == null:
		return null
	var p := main.find_child("Player", true, false) as Node3D
	if p == null:
		return null
	if (
		p.global_position.distance_squared_to(global_position)
		> _AI_DETECT_RADIUS * _AI_DETECT_RADIUS
	):
		return null
	return p


# Per-species SFX overrides.
func _play_idle_sfx() -> void:
	# Slimes don't have a standing idle sound — only the hop sound
	# that fires from `_do_hop`. No-op.
	pass


func _play_hurt_sfx() -> void:
	SFX.play_slime_hurt(global_position, _size)


func _play_death_sfx() -> void:
	SFX.play_slime_hurt(global_position, _size)


# Persistence — append size to base mob payload so split-on-death
# children round-trip through entities.bin with the correct HP / BB.
func to_save_dict() -> Dictionary:
	var d: Dictionary = super.to_save_dict()
	d["size"] = _size
	return d


func restore_from_dict(d: Dictionary) -> void:
	# Apply size BEFORE super so max_health gets the c² value when the
	# base restores `hp = clampi(d.get("hp", max_health), …)`.
	setup_size(int(d.get("size", 1)))
	max_health = _size * _size
	super.restore_from_dict(d)


# --- Hurt flash + death animation overrides ---
#
# MobBase's default hurt flash REPLACES each MeshInstance3D's
# `material_override` with a solid pink/red StandardMaterial3D
# (albedo_color = (1, 0.4, 0.4), no texture). For a slime this loses
# the green texture + translucent outer shell, leaving an opaque red
# brick — visually jarring against the rest of the world.
#
# Vanilla `ec.java` lines 67-99 instead renders the model TWICE:
# once with the normal texture, then again on top with a
# semi-transparent red overlay (glColor4f(red, 0, 0, 0.4) +
# alpha-blend). The effect is a red TINT over the original, not a
# replacement.
#
# We approximate by writing the red modulation directly into each
# mesh's existing `material_override.albedo_color`. The texture +
# transparency are preserved; only the RGB tint changes for the
# flash window. On clear, we restore the original albedo_color.
func _apply_hurt_flash() -> void:
	_clear_hurt_flash()  # idempotent — guard against stacked flashes
	_hurt_flash_remaining = _HURT_FLASH_SEC
	for mi in _find_mesh_instances(self):
		var mat: StandardMaterial3D = mi.material_override as StandardMaterial3D
		if mat == null:
			continue
		# Store the existing color so `_clear_hurt_flash` can restore.
		# Outer shell's pre-flash color is (1, 1, 1, 0.6) — preserving
		# alpha matters or the shell goes fully opaque mid-flash.
		_hurt_mat_overrides.append([mi, mat.albedo_color])
		var a: float = mat.albedo_color.a
		# Vanilla's overlay color is RGB (1, 0, 0). Multiplying that
		# into the existing albedo_color (modulated by the texture's
		# green) gives a vivid red wash, matching the vanilla feel.
		mat.albedo_color = Color(1.0, 0.3, 0.3, a)


func _clear_hurt_flash() -> void:
	for pair in _hurt_mat_overrides:
		var mi: MeshInstance3D = pair[0]
		var original_color: Color = pair[1]
		if not is_instance_valid(mi):
			continue
		var mat: StandardMaterial3D = mi.material_override as StandardMaterial3D
		if mat == null:
			continue
		mat.albedo_color = original_color
	_hurt_mat_overrides.clear()


# Death animation uses the base class's vanilla-faithful sqrt-curve Z
# tilt (`MobBase._tick_death_animation`) — 0° → 90° over the death
# duration. Vanilla `ec.java::a()` lines 39-45 apply that tilt to EVERY
# EntityLiving including slimes (there's no slime-specific override; the
# 90° default from `ec.a(hf)` flows through `ht extends ec`).
#
# Override here ONLY to defer the 4-children split until JUST BEFORE
# the parent despawns — vanilla `ns.J()` spawns them at t=0 of death,
# which causes them to appear ON TOP of the tilting parent and read
# as a chaotic mess. Spawning at the end of the animation keeps the
# same end state with a cleaner visual sequence.
func _tick_death_animation(delta: float) -> void:
	if not _split_spawned and _death_time + delta >= _DEATH_DURATION:
		_split_spawned = true
		_spawn_split_children()
	super._tick_death_animation(delta)


# Vanilla `ns.java::J()` split logic — size > 1 spawns 4 children at
# half size, jittered around the parent's position. Extracted into a
# named helper so `_tick_death_animation` can call it at the end of
# the death window instead of at `die()` time.
func _spawn_split_children() -> void:
	if _size <= 1 or _chunk_manager == null:
		return
	var child_size: int = _size / 2
	var child_script: GDScript = load("res://scripts/entities/slime.gd") as GDScript
	for i in range(4):
		var ox: float = (float(i % 2) - 0.5) * float(_size) * 0.5
		var oz: float = (float(i / 2) - 0.5) * float(_size) * 0.5
		var child = child_script.new()
		child.setup_size(child_size)
		_chunk_manager.add_child(child)
		var jitter := Vector3(randf_range(-0.2, 0.2), 0.5, randf_range(-0.2, 0.2))
		child.global_position = global_position + Vector3(ox, 0.4, oz) + jitter
