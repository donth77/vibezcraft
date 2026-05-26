class_name Creeper
extends "res://scripts/entities/mob_base.gd"

# Vanilla Alpha 1.2.6 EntityCreeper (`dq.java`). Hostile mob that chases
# the player like a zombie but doesn't melee — instead, when it gets
# within 3 m it ignites a 30-tick fuse, then detonates a power-3.0
# explosion at its position and dies. The fuse aborts (counts back
# down) if the player moves > 7 m away mid-ignition.
#
# AI inheritance (vanilla): dq extends ef (EntityMob) extends fc
# (EntityCreature) extends hf (EntityLiving). The chase + pathfinding
# all come from `fc.b_()` — `dq` only overrides the attackEntity hook
# to flip fuse state. We mirror via zombie.gd's tested chase code +
# substitute the melee branch with fuse logic.
#
# Visual model (vanilla `fg.java` ModelCreeper):
#   * Head — UV (0, 0), 8×8×8 at pivot (0, 4, 0)
#   * Head overlay — UV (32, 0), 8×8×8 with +0.5 scale offset (a 1-px
#     puffed "hair" layer, standard MC face-overlay pattern)
#   * Body — UV (16, 16), 8×12×4. NO ARMS — creeper is the only Alpha
#     hostile without arms (its silhouette is the iconic "long body").
#   * 4 legs — UV (0, 16), 4×6×4 each, pivots at the body's bottom 4
#     corners (±2, hip_y, ±4 in vanilla model space).
#
# Differences vs vanilla Alpha (deviations called out):
#   * Walk animation swings legs in front-back pairs (vanilla
#     `fg.a()`). Idle creepers stand still.
#   * No charged-creeper (Beta 1.5+ lightning-struck variant) — Alpha
#     doesn't have that branch.
#   * Music-disc drop on skeleton-arrow kill (vanilla `dq.b(lw)` line
#     86-91) is deferred — would need a damage-source-attribution
#     refactor on arrow.gd. Today, creeper-by-arrow drops gunpowder
#     same as creeper-by-sword.

const _CREEPER_TEXTURE_PATH: String = "res://assets/textures/mob/creeper.png"
const _CREEPER_TEXTURE_SIZE: Vector2i = Vector2i(64, 32)

# Model dimensions in pixel units (vanilla `fg.java`). Converted to
# meters via _PIXEL_TO_METER.
const _PIXEL_TO_METER: float = 1.0 / 16.0
const _HEAD_CUBE_PX: Vector3i = Vector3i(8, 8, 8)
const _BODY_CUBE_PX: Vector3i = Vector3i(8, 12, 4)
const _LEG_CUBE_PX: Vector3i = Vector3i(4, 6, 4)

# UV origins on the 64×32 creeper.png. Vanilla `fg.java` also declares a
# head overlay at UV (32, 0), but creeper.png has no pixels in that
# region — the right half of the sheet is entirely alpha=0. We skip
# building the overlay; see comment in `_build_model`.
const _HEAD_TEX_ORIGIN: Vector2i = Vector2i(0, 0)
const _BODY_TEX_ORIGIN: Vector2i = Vector2i(16, 16)
const _LEG_TEX_ORIGIN: Vector2i = Vector2i(0, 16)

# World-space cube centers (feet at Y=0). Derived from stacking the
# three vertical parts: legs (6 px) → body (12 px) → head (8 px) =
# 26 px = 1.625 m total. Each cube's center sits at the midpoint of
# its vertical span.
const _LEG_Y_CENTER: float = 6.0 * 0.5 * _PIXEL_TO_METER  # 0.1875
const _BODY_Y_CENTER: float = (6.0 + 12.0 * 0.5) * _PIXEL_TO_METER  # 0.75
const _HEAD_Y_CENTER: float = (6.0 + 12.0 + 8.0 * 0.5) * _PIXEL_TO_METER  # 1.375
const _HIP_Y: float = 6.0 * _PIXEL_TO_METER  # 0.375 — leg pivot at body bottom

# Leg pivot offsets — vanilla model places legs at the 4 corners of
# the body's footprint. Vanilla offsets are (±2, _, ±4) in pixels;
# X is body half-width (8/2 = 4 px) minus half-leg-width (4/2 = 2 px)
# = 2 px = 0.125 m. Z is body half-depth (4/2 = 2 px) plus half-leg-
# depth (4/2 = 2 px) = 4 px = 0.25 m so legs sit FLUSH at the body's
# front + back faces.
const _LEG_X_OFFSET: float = 2.0 * _PIXEL_TO_METER  # 0.125
const _LEG_Z_OFFSET: float = 4.0 * _PIXEL_TO_METER  # 0.25

# Creeper bounding box. Modern MC `EntityCreeper.<init>.setSize(0.6,
# 1.7)` over Alpha's 0.6 × 1.8 default (inherited from `hf` since
# `dq.<init>` doesn't call setSize). Modern is tighter to the 1.625 m
# visual silhouette (0.075 m headroom vs Alpha's 0.175 m), so sword
# swings and arrows that look like they should hit the creeper's
# head actually register — same hit-accuracy reasoning that drove
# the slime block / arrow fixes earlier in development. Same deviation
# pattern as zombie.gd, which overrides Alpha 1.8 → 1.95 for its
# taller silhouette.
const _BB_HEIGHT: float = 1.7
const _BB_WIDTH: float = 0.6

# AI cadence — 20 Hz tick rate matches vanilla integer-tick math.
const _AI_TICK_DT: float = 1.0 / 20.0

# Vanilla `ef.c_()` targets the nearest player within 16 m (with
# line-of-sight check). Same constant as zombie/skeleton.
const _AI_DETECT_RADIUS: float = 16.0
const _AI_ABANDON_RADIUS: float = 40.0
const _AI_REPATH_TICKS: int = 20

# --- Fuse mechanics (vanilla `dq.a(lw, float)`) ---
# Trigger range: vanilla branches on `d <= 0 && f2 < 3.0 || d > 0 &&
# f2 < 7.0` — so a NEW ignition requires 3 m proximity, but an
# ONGOING fuse keeps charging while target is within 7 m. The wider
# abort radius makes creepers feel committed once they start hissing.
const _FUSE_IGNITE_RANGE: float = 3.0
const _FUSE_ABORT_RANGE: float = 7.0
# Fuse duration in ticks — vanilla `c = 30` constant = 1.5 s @ 20 tps.
const _FUSE_MAX_TICKS: int = 30
# Explosion power. Vanilla `as.a(this, x, y, z, 3.0f)` — `Explosion.
# detonate(power=3.0)`. Matches Explosion.gd's TNT-class API (TNT uses
# power 4.0; creeper is slightly weaker).
const _EXPLOSION_POWER: float = 3.0

# Walk speed + pathfinding params — same as zombie. Creepers chase at
# a steady pace (vanilla `dq` has no special speed override).
const _AI_WALK_SPEED: float = 1.0
const _AI_JUMP_VELOCITY: float = 6.0
const _AI_STEP_BOOST_SPEED: float = 2.5
const _AI_MAX_YAW_STEP: float = PI / 4.0
const _AI_PATHFIND_RADIUS: float = 24.0
const _AI_PATHFIND_MAX_ITERS: int = 300
const _AI_ARRIVE_DIST: float = 0.6

# Walk animation params (vanilla `fg.a()`). Legs swing front-back via
# sin(walk_dist × 0.6662) × 1.4 × walk_amount. Front-left pairs with
# back-right (in-phase), back-left with front-right (anti-phase).
const _WALK_FREQ: float = 0.6662
const _WALK_DIST_SCALE: float = 12.0
const _WALK_ANIM_LERP_PER_SEC: float = 8.0
const _LEG_AMPLITUDE: float = 1.4
const _STEP_STRIDE: float = 1.4

# --- Visual node refs (rotated by walk anim) ---
var _head_mesh: MeshInstance3D
# 4 legs as separate pivots — front pair walks in-phase with each
# other, back pair in-phase with each other, front vs back anti-phase
# (vanilla fg.a() pairs FL+BR and FR+BL via `+π` offset).
var _leg_fl_pivot: Node3D  # front-left
var _leg_fr_pivot: Node3D  # front-right
var _leg_bl_pivot: Node3D  # back-left
var _leg_br_pivot: Node3D  # back-right
# Visual root — parented to self so the fuse pulse/scale can deform
# the whole rig together without touching the CollisionShape3D.
var _visual_root: Node3D
# Every MeshInstance3D's albedo material — cached for the white-flash
# overlay during fuse so we don't walk the scene tree every frame.
# Vanilla `g.a(dq, partial, partialFloat)` returns an ARGB white tint
# applied as a render-pass overlay; we approximate by modulating
# `albedo_color` on each cube's material.
var _all_materials: Array[StandardMaterial3D] = []
# Head-tracking interpolated state — vanilla `fg.a()` writes `f5/57.296`
# to head yaw (`.e`) and `f6/57.296` to head pitch (`.d`) every render
# tick. The values come from EntityLiving's per-tick aE/aF (head yaw /
# pitch toward target). We approximate via per-frame eased lerp toward
# a target pitch/yaw computed from the nearest player; eases out to 0
# when no target so the head settles to the body's forward.
var _head_yaw_current: float = 0.0
var _head_pitch_current: float = 0.0

# --- AI state ---
var _ai_tick_accum: float = 0.0
var _ai_path: Array = []
var _ai_repath_counter: int = 0
var _ai_player_cache: Node3D = null

# --- Fuse state (vanilla dq fields a/b/d) ---
# `_fuse_ticks` — vanilla `this.a`. Counts UP from 0 toward
# _FUSE_MAX_TICKS while the fuse is active. Counts DOWN by 1/tick
# while inactive (so the creeper doesn't explode mid-recovery if it
# re-engages the player before reset completes).
var _fuse_ticks: int = 0
# `_prev_fuse_ticks` — vanilla `this.b`. Captured at the start of each
# tick so the render scale can interpolate from previous-frame to
# current-frame fuse for smooth visual deformation at high frame rates.
var _prev_fuse_ticks: int = 0
# `_fuse_dir` — vanilla `this.d`. +1 = ignited (fuse should be
# incrementing), -1 = inert (fuse should be decrementing). Vanilla
# also uses 2 as a transient transition marker on the server tick;
# our state machine consolidates to ±1 only.
var _fuse_dir: int = -1
# Latches one-shot SFX/state changes between ticks.
var _last_fuse_dir: int = -1
var _exploded: bool = false

# --- Walk anim state ---
var _walk_dist: float = 0.0
var _walk_anim_amount: float = 0.0
var _step_accum: float = 0.0
var _age_seconds: float = 0.0


# MobBase environment overrides.
func _get_body_height() -> float:
	return _BB_HEIGHT


func _get_eye_height() -> float:
	# Vanilla `dq` has no eye-height override — inherits hf default of
	# height * 0.85. Use 1.45 m for the 1.7 m creeper.
	return _BB_HEIGHT * 0.85


func _get_body_width() -> float:
	return _BB_WIDTH


func _ready() -> void:
	max_health = 20  # vanilla `ef.<init>` sets this.J = 20
	# Vanilla `dq.g_()` returns `dx.K.aW` = GUNPOWDER. 0-2 per kill
	# (standard hostile drop range).
	drop_item_id = Items.GUNPOWDER
	drop_count_min = 0
	drop_count_max = 2
	_build_collision_shape()
	_build_model()
	super._ready()


# Vanilla `dq.b(lw)`: standard drops (gunpowder via super), PLUS one
# random music disc if the killer was a skeleton. Skeleton arrows
# (vanilla `dh` = EntitySkeleton; `_last_attacker` set by arrow.gd
# from `take_damage`'s attacker param) attribute as skeleton kills.
# Modern MC kept this drop pattern unchanged through every version.
#
# Alpha shipped 2 discs (gold + green); we have 8, so we roll over
# the whole pool for variety. Drop is unconditional (no probability)
# once the kill credit checks out — vanilla doesn't randomize it.
func _spawn_drops() -> void:
	super._spawn_drops()
	if _chunk_manager == null:
		return
	# `_last_attacker` may be a freed instance — if a skeleton arrow
	# hit this creeper earlier and the skeleton has since died + been
	# queue_free'd, the Node reference points at a dangling object.
	# `is_instance_valid` returns false for those, so the early-return
	# catches both null and freed cases before the `is Skeleton` check
	# (which would crash with "Left operand of 'is' is a previously
	# freed instance" otherwise).
	if not is_instance_valid(_last_attacker):
		return
	if not (_last_attacker is Skeleton):
		return
	var discs: Array = [
		Items.MUSIC_DISC_FIRST_LIGHT,
		Items.MUSIC_DISC_GREEN_DISTANCE,
		Items.MUSIC_DISC_LONG_SHADOW,
		Items.MUSIC_DISC_HOLLOW_EARTH,
		Items.MUSIC_DISC_BEDROCK,
		Items.MUSIC_DISC_OPEN_SKY,
		Items.MUSIC_DISC_HEARTHSTONE,
		Items.MUSIC_DISC_STILL_WATER,
	]
	var disc_id: int = discs[randi() % discs.size()]
	var disc := DroppedItem.new()
	_chunk_manager.add_child(disc)
	var jitter := Vector3(randf_range(-0.2, 0.2), 0.3, randf_range(-0.2, 0.2))
	disc.global_position = global_position + Vector3(0, 0.4, 0) + jitter
	disc.setup(disc_id)


# Box-shaped body collision so the player's melee + arrow raycasts hit
# the full silhouette including the narrow body's edges (a capsule
# inscribed inside the 0.6 × 1.7 × 0.6 BB would miss the body's flat
# sides at certain angles). Head Area3D on layer 3 covers the head
# cube for head-shot detection.
func _build_collision_shape() -> void:
	var body_col := CollisionShape3D.new()
	body_col.shape = _cached_box(Vector3(_BB_WIDTH, _BB_HEIGHT, _BB_WIDTH))
	body_col.position = Vector3(0.0, _BB_HEIGHT * 0.5, 0.0)
	add_child(body_col)
	_build_head_hit_area(Vector3(0.55, 0.55, 0.55), Vector3(0.0, _HEAD_Y_CENTER, 0.0))


# Build the 6-cube ModelCreeper visual. All cubes parented under a
# `_visual_root` Node3D so the fuse-pulse scale can deform the whole
# rig as one unit while keeping the underlying CollisionShape3D fixed.
func _build_model() -> void:
	# Shared cached material — see MobBase.get_shared_material. Drops
	# per-spawn _ready cost ~3x by reusing one StandardMaterial3D +
	# Texture2D across every creeper.
	var mat: StandardMaterial3D = MobBase.get_shared_material(_CREEPER_TEXTURE_PATH, false)
	_all_materials.append(mat)
	_visual_root = Node3D.new()
	add_child(_visual_root)
	# Head — static cube, no walk animation.
	var head_size := Vector3(
		_HEAD_CUBE_PX.x * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.y * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.z * _PIXEL_TO_METER
	)
	_head_mesh = MeshInstance3D.new()
	_head_mesh.mesh = MobCube.build_textured_cube(
		head_size, _CREEPER_TEXTURE_SIZE, _HEAD_TEX_ORIGIN, _HEAD_CUBE_PX, false
	)
	_head_mesh.position = Vector3(0.0, _HEAD_Y_CENTER, 0.0)
	_head_mesh.material_override = mat
	_visual_root.add_child(_head_mesh)
	# Head overlay — vanilla `b` cube at UV (32, 0). The vanilla
	# `fg.java` model declares this cube unconditionally, but creeper.png
	# has NO PIXELS in the (32, 0) region (the right half of the sheet
	# is entirely alpha=0). Other mobs reuse this slot for armor —
	# creeper doesn't. So vanilla renders the overlay cube but every
	# texel is transparent, making it invisible in-game. Our atlas-
	# mode unshaded material doesn't enable per-pixel alpha discard, so
	# rendering the overlay produces a solid-black cube on top of the
	# head. Skip the overlay entirely — same end visual as vanilla, no
	# wasted geometry.
	# Body — static, no arms.
	var body_size := Vector3(
		_BODY_CUBE_PX.x * _PIXEL_TO_METER,
		_BODY_CUBE_PX.y * _PIXEL_TO_METER,
		_BODY_CUBE_PX.z * _PIXEL_TO_METER
	)
	var body := MeshInstance3D.new()
	body.mesh = MobCube.build_textured_cube(
		body_size, _CREEPER_TEXTURE_SIZE, _BODY_TEX_ORIGIN, _BODY_CUBE_PX, false
	)
	body.position = Vector3(0.0, _BODY_Y_CENTER, 0.0)
	body.material_override = mat
	_visual_root.add_child(body)
	# 4 legs — pivot at hip (top of leg = body bottom). Walk anim
	# swings each pivot around its X axis. All 4 legs share the same
	# UV origin (vanilla reuses one leg tile for all 4 cubes).
	_leg_fl_pivot = _add_leg(Vector3(-_LEG_X_OFFSET, _HIP_Y, _LEG_Z_OFFSET), mat, false)
	_leg_fr_pivot = _add_leg(Vector3(_LEG_X_OFFSET, _HIP_Y, _LEG_Z_OFFSET), mat, true)
	_leg_bl_pivot = _add_leg(Vector3(-_LEG_X_OFFSET, _HIP_Y, -_LEG_Z_OFFSET), mat, false)
	_leg_br_pivot = _add_leg(Vector3(_LEG_X_OFFSET, _HIP_Y, -_LEG_Z_OFFSET), mat, true)


# One leg pivot — Node3D at the hip, MeshInstance3D child whose center
# hangs half-leg-height below the pivot. Mirror swaps the U direction
# for the right-side legs (vanilla `ka.g = true` flag).
func _add_leg(pivot_pos: Vector3, mat: StandardMaterial3D, mirror: bool) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = pivot_pos
	_visual_root.add_child(pivot)
	var size := Vector3(
		_LEG_CUBE_PX.x * _PIXEL_TO_METER,
		_LEG_CUBE_PX.y * _PIXEL_TO_METER,
		_LEG_CUBE_PX.z * _PIXEL_TO_METER
	)
	var mi := MeshInstance3D.new()
	mi.mesh = MobCube.build_textured_cube(
		size, _CREEPER_TEXTURE_SIZE, _LEG_TEX_ORIGIN, _LEG_CUBE_PX, mirror
	)
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
	if _dying or _exploded or _physics_gated:
		return
	# LOD-scaled tick rate — same pattern as skeleton.
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
	if _physics_gated:
		return
	if _lod_tier == LOD_FAR:
		return
	_advance_walk_animation(delta)
	_apply_fuse_render_scale(delta)


# --- Hostile AI ---


# Per-tick AI: track + chase the nearest player, tick the fuse based on
# proximity, detonate when fuse hits max. Mirrors vanilla `dq.b_()` +
# `dq.a(lw, float)` (attackEntity hook).
func _ai_tick() -> void:
	# Vanilla `hf.B()` rolls the idle-sound chance per tick. Centralized
	# on MobBase so every species uses the same `nextInt(1000) < a++`
	# pattern (mean ~1 fire per 6 s, matching vanilla `b() = 80`).
	if roll_idle_sfx_tick():
		_play_idle_sfx()
	# Vanilla `e_()` saves `b = a` at the START of every entity tick so
	# the renderer can interpolate from previous-frame to current-frame
	# fuse for smooth visual deformation. Mirror at the top here.
	_prev_fuse_ticks = _fuse_ticks
	_ai_repath_counter += 1
	var player: Node3D = _find_player()
	# No target in detect range — wander + decay any leftover fuse.
	if player == null:
		_tick_fuse_decay()
		_wander_tick()
		return
	var dist_sq: float = global_position.distance_squared_to(player.global_position)
	if dist_sq > _AI_ABANDON_RADIUS * _AI_ABANDON_RADIUS:
		_ai_player_cache = null
		_tick_fuse_decay()
		_wander_tick()
		return
	# Vanilla `dq.a(lw, float)`: ignite at < 3 m (NEW) or sustain at
	# < 7 m (ONGOING). Two-band check so a hissing creeper doesn't
	# abort the moment the player backs off by 0.1 m.
	var dist: float = sqrt(dist_sq)
	var in_ignite_band: bool = dist < _FUSE_IGNITE_RANGE
	var in_sustain_band: bool = dist < _FUSE_ABORT_RANGE and _fuse_dir > 0
	if in_ignite_band or in_sustain_band:
		_tick_fuse_ignite(player)
		return
	# Out of range — count fuse back down toward 0 (vanilla `b_()`
	# else-branch decrement) so the next ignite starts fresh.
	_tick_fuse_decay()
	# Continue chase: re-aim periodically, walk the path.
	if dist_sq < _FUSE_IGNITE_RANGE * _FUSE_IGNITE_RANGE:
		# Already in melee range — face the player and stop. Shouldn't
		# happen since the band check above caught it, but defensive.
		_face_target(player)
		_velocity_brake()
		return
	if _ai_path.is_empty() or _ai_repath_counter >= _AI_REPATH_TICKS:
		_ai_repath_counter = 0
		_repath_toward(player)
	if not _ai_path.is_empty():
		_tick_walk_path()


# Vanilla `dq.a(lw, float)`: ignite fuse, count up, play random.fuse
# SFX on the leading edge (a==0), detonate at a==c.
func _tick_fuse_ignite(player: Node3D) -> void:
	# Slow to a stop and face the player while charging — creepers
	# stop walking the moment they ignite (vanilla `b_()` sets the
	# `h = true` flag that pauses pathfinding).
	_face_target(player)
	_velocity_brake()
	if _fuse_dir != 1:
		# Leading-edge ignite → play the fuse SFX once. Vanilla `dq.java`
		# line 96 uses pitch 0.5 (lower than TNT's 1.0) so the creeper
		# hiss reads as a distinct, ominous "this is about to blow"
		# sound rather than the sharper TNT crackle.
		_fuse_dir = 1
		if _fuse_ticks == 0:
			SFX.play_fuse(true, 0.5)
	_fuse_ticks += 1
	if _fuse_ticks >= _FUSE_MAX_TICKS:
		_detonate()


# Decay path — vanilla `b_()` else-branch decrements `a` by 1 per tick
# when inactive (`d < 0 && a > 0`). Take 30 ticks to reset from full.
func _tick_fuse_decay() -> void:
	_fuse_dir = -1
	if _fuse_ticks > 0:
		_fuse_ticks -= 1


# Vanilla `dq.a(lw, float)` end-branch: explode at power 3.0, then
# self-destruct. The explosion damages the player + nearby mobs +
# blocks; we pass `self` as the source so Explosion.gd skips
# self-damage (the creeper IS the source — vanilla `Explosion.<init>`
# stores the source entity and skips it during the entity-damage pass).
func _detonate() -> void:
	if _exploded:
		return
	_exploded = true
	# Death SFX BEFORE explosion so the creeper-death sound layers
	# audibly with random.explode rather than getting drowned out.
	_play_death_sfx()
	# Spawn drops at the creeper's CURRENT position before the blast
	# blows the cell to AIR — vanilla drops drop here regardless of
	# whether the creeper kills itself or a player kills it.
	_spawn_drops()
	if _chunk_manager != null:
		# Vanilla `as.a(this, this.aw, this.ax, this.ay, 3.0f)` — vanilla
		# `ax` is the entity's CENTER Y (not feet). Detonating at feet
		# eats more terrain below than above, producing a lopsided
		# crater. Lift to body center so the blast wraps the creeper
		# symmetrically.
		var center: Vector3 = global_position + Vector3(0.0, _BB_HEIGHT * 0.5, 0.0)
		Explosion.detonate(_chunk_manager, center, _EXPLOSION_POWER, self)
	# Skip the normal death-tilt animation — a creeper that just
	# detonated should disappear with the blast, not fall sideways.
	queue_free()


# --- Helpers reused from zombie's chase pattern ---


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


# Vanilla `EntityCreature.findRandomTargetBlock` wander — shared
# helper on MobBase. Without it, idle creepers freeze in place.
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


# --- Walk animation + fuse render ---


# Walk anim — 4 legs swing in 2 pairs (FL+BR / FR+BL anti-phase), per
# vanilla `fg.a()`. Movement speed drives `walk_anim_amount` toward
# 1.0; legs swing at the same 0.6662 rad/unit rate as zombies.
func _advance_walk_animation(delta: float) -> void:
	_age_seconds += delta
	var vx: float = velocity.x
	var vz: float = velocity.z
	var sp_sq: float = vx * vx + vz * vz
	var speed: float = sqrt(sp_sq) if sp_sq > 0.0001 else 0.0
	var target_amount: float = clampf(speed / _AI_WALK_SPEED, 0.0, 1.0)
	var lerp_t: float = minf(_WALK_ANIM_LERP_PER_SEC * delta, 1.0)
	_walk_anim_amount = lerpf(_walk_anim_amount, target_amount, lerp_t)
	_walk_dist += _walk_anim_amount * delta * _WALK_DIST_SCALE
	var phase: float = _walk_dist * _WALK_FREQ
	var swing_a: float = cos(phase) * _LEG_AMPLITUDE * _walk_anim_amount
	var swing_b: float = cos(phase + PI) * _LEG_AMPLITUDE * _walk_anim_amount
	# Vanilla fg.a: d=FL gets `sin(f2 * 0.6662) * 1.4 * f3`,
	# e=FR gets `+π`, f=BL gets `+π`, g=BR gets the bare term. So FL
	# matches BR; FR matches BL. Translate to our cos-based phase
	# (90° offset — same waveform, different name):
	if _leg_fl_pivot != null:
		_leg_fl_pivot.rotation.x = swing_a
	if _leg_br_pivot != null:
		_leg_br_pivot.rotation.x = swing_a
	if _leg_fr_pivot != null:
		_leg_fr_pivot.rotation.x = swing_b
	if _leg_bl_pivot != null:
		_leg_bl_pivot.rotation.x = swing_b
	_step_accum += speed * delta
	if _step_accum >= _STEP_STRIDE:
		_step_accum -= _STEP_STRIDE
		_play_step()
	_update_head_tracking(delta)


# Vanilla creeper head tracks the player in yaw AND pitch independent
# of body rotation — see `fg.a()` writing into the head cube's `.d`
# (pitch) and `.e` (yaw). The vanilla yaw values come from
# `EntityLiving`'s per-tick head-yaw clamping (head can rotate up to
# ~60° relative to body before the body catches up).
#
# We compute target yaw/pitch toward the nearest player's head
# height, ease the live values toward the target at ~8 Hz, and write
# both into the head cube + its overlay. Falls back to neutral when
# no target is in detect range — head settles to body forward.
func _update_head_tracking(delta: float) -> void:
	if _head_mesh == null:
		return
	var target_yaw: float = 0.0
	var target_pitch: float = 0.0
	var player: Node3D = _find_player()
	if player != null:
		# Eye-line to player's center, in world space, relative to the
		# head cube's center.
		var head_world: Vector3 = global_position + Vector3(0.0, _HEAD_Y_CENTER, 0.0)
		var player_eye: Vector3 = player.global_position + Vector3(0.0, 1.5, 0.0)
		var to_player: Vector3 = player_eye - head_world
		# Yaw relative to body forward (body's local -Z is "forward"
		# after the entity's rotation.y). atan2 args use the same
		# sign convention as the body-yaw math elsewhere in this file.
		var world_yaw: float = atan2(-to_player.x, -to_player.z)
		target_yaw = wrapf(world_yaw - rotation.y, -PI, PI)
		# Clamp to ±60° — vanilla creeper head won't twist beyond that
		# before the body rotates to compensate.
		target_yaw = clampf(target_yaw, -PI / 3.0, PI / 3.0)
		var horizontal: float = sqrt(to_player.x * to_player.x + to_player.z * to_player.z)
		# Pitch — positive = head tilts down. Local-X rotation in our
		# coord system maps direction-to-player.y < 0 (player below)
		# to a NEGATIVE pitch (head looks down).
		target_pitch = -atan2(to_player.y, maxf(horizontal, 0.01))
		target_pitch = clampf(target_pitch, -PI / 3.0, PI / 3.0)
	# Eased lerp toward target — 8 Hz feels responsive without snapping.
	var t: float = minf(8.0 * delta, 1.0)
	_head_yaw_current = lerpf(_head_yaw_current, target_yaw, t)
	_head_pitch_current = lerpf(_head_pitch_current, target_pitch, t)
	_head_mesh.rotation = Vector3(_head_pitch_current, _head_yaw_current, 0.0)


# Vanilla `g.a(dq, partial)` render-scale formula (annotated):
#
#   f3 = creeper.b(partial) = fuse_interp / (c - 2)     // 0..1+ raw
#   f4 = 1 + sin(f3 * 100) * f3 * 0.01                   // 100 Hz pulse uses RAW f3
#   if (f3 < 0) f3 = 0                                   // clamp AFTER pulse
#   if (f3 > 1) f3 = 1
#   f3 *= f3                                             // square
#   f3 *= f3                                             // ^4 — eased ramp
#   f5 = (1 + f3 * 0.4) * f4                             // X/Z scale up to 1.4× × pulse
#   f6 = (1 + f3 * 0.1) / f4                             // Y scale up to 1.1× / pulse
#
# The f3^4 ramp keeps the model nearly normal-sized for the first ~80%
# of the fuse, then rapidly swells in the final tick or two. Without
# the ramp the creeper looks fat throughout the fuse, which kills the
# "snap" of the impending explosion. We apply to `_visual_root` so
# collision stays at its unscaled size. Runs every frame for smooth
# interp at 60+ Hz despite the 20 Hz AI tick.
func _apply_fuse_render_scale(_delta: float) -> void:
	if _visual_root == null:
		return
	if _fuse_ticks == 0 and _prev_fuse_ticks == 0:
		# Inert — reset scale + flash so a recent decay doesn't leave
		# the creeper bloated or white-tinted.
		_visual_root.scale = Vector3.ONE
		_set_flash_tint(0.0)
		return
	# Vanilla denominator is `c - 2` = 28 (NOT 30) — so f3_raw exceeds
	# 1.0 at the explosion frame (28→30 = 1.07). The CLAMP then pins
	# f3 at 1.0 for the f3^4 scale ramp, while the PULSE term keeps
	# the raw overshoot.
	var fuse_interp: float = (
		float(_prev_fuse_ticks)
		+ float(_fuse_ticks - _prev_fuse_ticks) * minf(_ai_tick_accum / _AI_TICK_DT, 1.0)
	)
	var f3_raw: float = fuse_interp / float(_FUSE_MAX_TICKS - 2)
	var f4: float = 1.0 + sin(f3_raw * 100.0) * f3_raw * 0.01
	var f3: float = clampf(f3_raw, 0.0, 1.0)
	f3 *= f3
	f3 *= f3
	var f5: float = (1.0 + f3 * 0.4) * f4
	var f6: float = (1.0 + f3 * 0.1) / f4
	_visual_root.scale = Vector3(f5, f6, f5)
	_apply_fuse_flash(f3_raw)


# Vanilla `g.a(dq, partial, partialFloat)` returns an ARGB white tint
# that alternates ON/OFF every 0.1 step of f3_raw, getting brighter
# as the fuse approaches detonation:
#
#   if ((int)(f3 * 10) % 2 == 0) return 0    // OFF frame
#   alpha = clamp((int)(f3 * 0.2 * 255), 0, 255)
#   return ARGB(alpha, 255, 255, 255)
#
# Renderer applies it as an additive overlay pass on top of the
# textured model. We approximate by lerping each material's
# albedo_color toward super-bright (2,2,2) so the texture brightens
# without losing its green hue entirely (a pure-white modulation
# would wash out to invisible).
func _apply_fuse_flash(f3_raw: float) -> void:
	var on_frame: bool = int(f3_raw * 10.0) % 2 == 1
	if not on_frame:
		_set_flash_tint(0.0)
		return
	var tint_amount: float = clampf(f3_raw * 0.2, 0.0, 1.0)
	_set_flash_tint(tint_amount)


# Modulates every cached material's albedo_color toward bright white
# by `amount` (0 = pure texture under current world brightness, 1 =
# doubled brightness). Called from `_apply_fuse_flash` per render
# frame. Reads `_last_lit_brightness` from mob_base so the inert path
# preserves the day-night dim instead of overwriting it with pure
# white (which was leaving creepers visibly lit at night).
func _set_flash_tint(amount: float) -> void:
	var b: float = _last_lit_brightness if _last_lit_brightness >= 0.0 else 1.0
	var base: Color = Color(b, b, b, 1.0)
	var bright: Color = Color(2.0, 2.0, 2.0, 1.0)
	var c: Color = base.lerp(bright, amount)
	for mat: StandardMaterial3D in _all_materials:
		if mat != null:
			mat.albedo_color = c


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
	# Vanilla creepers use the standard `step.<material>` pool, NOT a
	# species-specific step (creeper has no `step` audio files). Route
	# through the block-step path.
	SFX.play_block_step_3d(block_id, global_position)


# Species SFX overrides — vanilla `dq.f_()` = "mob.creeper" (hurt +
# idle share the same pool), `dq.f()` = "mob.creeperdeath".
func _play_idle_sfx() -> void:
	SFX.play_creeper_say(global_position)


func _play_hurt_sfx() -> void:
	SFX.play_creeper_say(global_position)


func _play_death_sfx() -> void:
	SFX.play_creeper_death(global_position)


# Persistence — append fuse state so a save-while-ignited round-trips.
# Without this the fuse resets to 0 on load and a creeper mid-charge
# becomes inert when the world reloads.
func to_save_dict() -> Dictionary:
	var d: Dictionary = super.to_save_dict()
	d["fuse"] = _fuse_ticks
	d["fuse_dir"] = _fuse_dir
	return d


func restore_from_dict(d: Dictionary) -> void:
	super.restore_from_dict(d)
	_fuse_ticks = int(d.get("fuse", 0))
	_prev_fuse_ticks = _fuse_ticks
	_fuse_dir = int(d.get("fuse_dir", -1))
