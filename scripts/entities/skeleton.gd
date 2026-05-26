class_name Skeleton
extends "res://scripts/entities/mob_base.gd"

# Vanilla Alpha 1.2.6 EntitySkeleton (`nq.java`). Second hostile mob,
# ranged. Targets the nearest player within 16 m, kites at bow range
# (~4-10 m), charges a shot ~1.5 s, fires an arrow via the existing
# Arrow entity, then re-aims. Burns in direct sunlight (same as
# zombie).
#
# Vanilla AI summary (`nq.java::e(Entity)` + `EntityCreature`):
#   * Target acquisition: nearest player ≤16 m.
#   * If distance > 10 m: pathfind toward player (close in).
#   * If 4 m ≤ distance ≤ 10 m: stop and charge bow. Fire when
#     `attackTimer >= 30` (1.5 s @ 20 tps); reset timer post-shot.
#   * If distance < 4 m: pathfind AWAY from player (kite).
#   * Line-of-sight gate: vanilla skips the shot if the player isn't
#     visible (raycast); we use the same Pathfinder.is_walkable
#     reachability proxy.
#
# Visual model: vanilla 64×32 ModelBiped (Alpha `dc.java`), same UV
# layout as zombie / player. UNLIKE ModelZombie, ModelSkeleton does
# NOT override the parent arm-swing, so arms swing naturally during
# walk (mirrored anti-phase to legs). When aiming the bow, the right
# arm raises horizontal and the left arm half-raises to grip the
# string — Beta-era ModelSkeleton `aimedBow` flag.
#
# Drops (vanilla `nq.java::g_()`): bone × 0-2, arrow × 0-2. Both
# rolls are independent so a kill can drop both, just one, or
# neither — matches Alpha.

const _SKELETON_TEXTURE_PATH: String = "res://assets/textures/mob/skeleton.png"
const _SKELETON_TEXTURE_SIZE: Vector2i = Vector2i(64, 32)

const _ARROW_SCRIPT: GDScript = preload("res://scripts/entities/arrow.gd")

# Model dimensions — vanilla `gu.java` (ModelSkeleton) overrides
# ModelZombie's 4×12×4 arm/leg cubes with THIN 2×12×2 cubes. Same UV
# region on the 64×32 sheet (40,16 for arms, 0,16 for legs) but the
# narrower cube samples only the inner 2 px of those 4-px regions —
# the outer 2 px of the UV slice happen to be drawn as TRANSPARENT
# in vanilla skeleton.png, which gives the visible "skeletal stick"
# silhouette. Head + body stay full ModelBiped size.
const _PIXEL_TO_METER: float = 1.0 / 16.0
const _HEAD_CUBE_PX: Vector3i = Vector3i(8, 8, 8)
const _BODY_CUBE_PX: Vector3i = Vector3i(8, 12, 4)
const _ARM_CUBE_PX: Vector3i = Vector3i(2, 12, 2)
const _LEG_CUBE_PX: Vector3i = Vector3i(2, 12, 2)
const _HEAD_TEX_ORIGIN: Vector2i = Vector2i(0, 0)
const _BODY_TEX_ORIGIN: Vector2i = Vector2i(16, 16)
const _ARM_RIGHT_TEX_ORIGIN: Vector2i = Vector2i(40, 16)
const _ARM_LEFT_TEX_ORIGIN: Vector2i = Vector2i(40, 16)
const _LEG_RIGHT_TEX_ORIGIN: Vector2i = Vector2i(0, 16)
const _LEG_LEFT_TEX_ORIGIN: Vector2i = Vector2i(0, 16)

const _BODY_Y_OFFSET: float = 1.125
const _HEAD_Y_OFFSET: float = 1.75
# Vanilla `gu.java:10` places the arm rotation point at x=±5 (5 px
# from body center). With a 2-px arm cube (half-width 1 px) that's
# 5/16 m from center, matching the body's 4-px half-width plus a
# 1-px shoulder cap.
const _ARM_X_OFFSET: float = 5.0 / 16.0
# Vanilla `gu.java:17` puts the leg rotation point at x=±2 (2 px).
# With 2-px leg cube (half 1 px), legs land flush against the body
# bottom corners.
const _LEG_X_OFFSET: float = 2.0 / 16.0

# Vanilla skeleton size matches zombie (setSize 0.6 × 1.8) — same
# 1.95 m visual silhouette in our units.
const _BB_HEIGHT: float = 1.95
const _BB_WIDTH: float = 0.6

# AI cadence — 20 Hz tick, matches integer-tick vanilla math.
const _AI_TICK_DT: float = 1.0 / 20.0

# Vanilla 16 m detection radius (EntityMob.getClosestPlayerToEntity).
const _AI_DETECT_RADIUS: float = 16.0
const _AI_ABANDON_RADIUS: float = 40.0
const _AI_REPATH_TICKS: int = 20

# Kite range. Vanilla skeleton's `getAttackStrength` fires the bow
# when distance² ≤ 100 (=10 m); below that and the AI flees. We
# match — too-far → pursue, in-band → stand still and shoot,
# too-close → retreat.
const _AI_SHOOT_RANGE: float = 10.0
const _AI_KITE_RANGE: float = 4.0  # < this → retreat away from player

# Bow charge time. Vanilla skeleton fires when `attackTimer == 30`
# (1.5 s @ 20 tps). Charge resets to 0 on shot AND on losing target.
const _AI_BOW_CHARGE_SEC: float = 1.5
# Vanilla bow shot speed at full charge: ~1.6 m/s/tick = 32 m/s.
# Arrow.gd's bow_release path uses ~3 m/tick × MAX_SPEED scaling for
# the player; the skeleton always shoots full-charge for simplicity.
const _AI_ARROW_SPEED: float = 30.0
# Vanilla arrow damage from skeleton: `random.nextInt(2) + 2` = 2-3
# HP, scaled by `Arrow.b(2.0)`. Our Arrow computes damage from
# velocity × BASE_DAMAGE — feeding it 30 m/s gives ~6 HP, which is
# on the high end. We pass `is_critical=false` so the random bonus
# doesn't fire on top.

# Walk speed. Vanilla `nq.java::A = 0.25F` per tick = 5 blocks/sec;
# we use 1.0 m/s to match zombie's pace (vanilla skeletons feel
# similar to zombies on the chase frontier).
const _AI_WALK_SPEED: float = 1.0
const _AI_JUMP_VELOCITY: float = 6.0
const _AI_STEP_BOOST_SPEED: float = 2.5
const _AI_MAX_YAW_STEP: float = PI / 4.0
const _AI_PATHFIND_RADIUS: float = 24.0
const _AI_PATHFIND_MAX_ITERS: int = 300
const _AI_ARRIVE_DIST: float = 0.6

# Daylight burn — same as zombie. Vanilla nq.java::B() checks
# skylight ≥ 15 + day + dry + not in water → setFire(8).
const _AI_BURN_CHECK_INTERVAL: float = 1.0
const _AI_BURN_DURATION_SEC: float = 8.0

# Walk-animation params — same ModelBiped pace as zombie/player.
const _WALK_FREQ: float = 0.6662
const _WALK_DIST_SCALE: float = 12.0
const _WALK_ANIM_LERP_PER_SEC: float = 8.0
const _LEG_AMPLITUDE: float = 1.4
# ModelSkeleton, unlike ModelZombie, does NOT lock arms horizontal —
# arms swing naturally during walk like player/biped. Vanilla
# `dc.java:66-67` swing amplitude is `cos(phase) * 2.0 * walkAmount *
# 0.5` = ±1.0 rad. We mirror that.
const _ARM_AMPLITUDE: float = 1.0

# Bow-aim arm pose. Vanilla `mh.java::aimedBow` flag raises the
# right arm to horizontal forward (rotateAngleX = -π/2 + tiny pitch
# tracking the target's vertical). We pin both arms to horizontal
# during charge; the right arm is the one holding the bow.
const _AIM_ARM_PITCH: float = PI * 0.5

const _STEP_STRIDE: float = 1.4

# Bow visual offsets. The bow grip is in the lower-left of the 16×16
# sprite (image (2, 13) → mesh-local (-6, -7) after extrusion's Y
# flip). After the Z-rotation in `_build_bow`, the grip ends up at
# ~(-0.47, -9.19) px relative to the bow center, so we push the bow
# upward by that much to put the grip AT the hand instead of the
# mesh center.
const _BOW_GRIP_OFFSET_PIXELS: float = 9.19
const _BOW_PIXEL_SCALE: float = 1.0 / 32.0

# --- Visual node refs ---
var _head_mesh: MeshInstance3D
var _arm_l_pivot: Node3D
var _arm_r_pivot: Node3D
var _leg_l_pivot: Node3D
var _leg_r_pivot: Node3D
# Bow held in the right hand. Always visible (vanilla skeleton renders
# the bow continuously, not just while aiming). Built once in _ready
# from Items.BOW via SpriteExtruder — same path the player's held
# tool uses.
var _bow_mesh: MeshInstance3D

# --- AI state ---
var _ai_tick_accum: float = 0.0
var _ai_path: Array = []
var _ai_repath_counter: int = 0
var _ai_burn_check_accum: float = 0.0
var _ai_player_cache: Node3D = null
# Bow charge. Counts UP to _AI_BOW_CHARGE_SEC while a target is in
# the shoot band; resets on shot or target lost. `_ai_aiming` is the
# render-side flag so the arm pose code can show the aim stance.
var _ai_bow_charge_sec: float = 0.0
var _ai_aiming: bool = false

# --- Walk-anim state ---
var _walk_dist: float = 0.0
var _walk_anim_amount: float = 0.0
var _step_accum: float = 0.0
var _age_seconds: float = 0.0


# MobBase env overrides.
func _get_body_height() -> float:
	return _BB_HEIGHT


func _get_eye_height() -> float:
	return 1.62


func _get_body_width() -> float:
	return _BB_WIDTH


func _ready() -> void:
	max_health = 20  # vanilla EntityLiving default
	# Primary drop = bone (0-2). Secondary arrow drop handled in
	# _spawn_drops below since MobBase only does one item type.
	drop_item_id = Items.BONE
	drop_count_min = 0
	drop_count_max = 2
	_build_collision_shape()
	_build_model()
	super._ready()


# Vanilla `nq.java::g_()` drops are 2 independent rolls: bone (0-2)
# AND arrow (0-2). MobBase only handles a single drop type so we
# inherit the bone roll via super._spawn_drops, then add arrows here.
func _spawn_drops() -> void:
	super._spawn_drops()
	if _chunk_manager == null:
		return
	var arrow_count: int = randi_range(0, 2)
	for _i in range(arrow_count):
		var item := DroppedItem.new()
		_chunk_manager.add_child(item)
		var jitter := Vector3(randf_range(-0.2, 0.2), 0.3, randf_range(-0.2, 0.2))
		item.global_position = global_position + Vector3(0, 0.4, 0) + jitter
		item.setup(Items.ARROW)


func _build_collision_shape() -> void:
	_build_body_capsule(_BB_WIDTH * 0.5, _BB_HEIGHT)
	_build_head_hit_area(Vector3(0.55, 0.55, 0.55), Vector3(0.0, _HEAD_Y_OFFSET, 0.0))


func _build_model() -> void:
	# Shared cached material — see MobBase.get_shared_material. Drops
	# per-spawn _ready cost from ~5-10 ms to ~1-2 ms by reusing one
	# StandardMaterial3D + Texture2D across every skeleton instance.
	var mat: StandardMaterial3D = MobBase.get_shared_material(_SKELETON_TEXTURE_PATH, true)
	# Head.
	var head_size := Vector3(
		_HEAD_CUBE_PX.x * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.y * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.z * _PIXEL_TO_METER
	)
	_head_mesh = MeshInstance3D.new()
	_head_mesh.mesh = MobCube.build_textured_cube(
		head_size, _SKELETON_TEXTURE_SIZE, _HEAD_TEX_ORIGIN, _HEAD_CUBE_PX, false
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
		body_size, _SKELETON_TEXTURE_SIZE, _BODY_TEX_ORIGIN, _BODY_CUBE_PX, false
	)
	body.position = Vector3(0.0, _BODY_Y_OFFSET, 0.0)
	body.material_override = mat
	add_child(body)
	# Arms — shoulder pivots at body-top.
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
	# Legs — hip pivots at body-bottom.
	_leg_r_pivot = _add_limb(
		Vector3(-_LEG_X_OFFSET, 0.75, 0.0), _LEG_CUBE_PX, _LEG_RIGHT_TEX_ORIGIN, mat, false
	)
	_leg_l_pivot = _add_limb(
		Vector3(_LEG_X_OFFSET, 0.75, 0.0), _LEG_CUBE_PX, _LEG_LEFT_TEX_ORIGIN, mat, true
	)
	_build_bow()


# Build the bow visual and parent it to the right-arm pivot so the
# bow follows the aim pose. Extruded from Items.BOW's icon via
# SpriteExtruder, scaled + positioned to sit in the skeleton's right
# hand (~3/4 down the arm). Vanilla `m.java::b(EntityLiving, float)`
# is the renderer hook that draws the held item.
func _build_bow() -> void:
	var bow_tex: Texture2D = ItemIcons.icon_for(Items.BOW)
	if bow_tex == null or _arm_r_pivot == null:
		return
	_bow_mesh = MeshInstance3D.new()
	_bow_mesh.mesh = SpriteExtruder.build(bow_tex)
	if _bow_mesh.mesh == null:
		return
	var pixel_scale: float = _BOW_PIXEL_SCALE
	# Parent to the right-arm pivot so the bow rotates WITH the arm
	# (vanilla `m.java::b(EntityLiving)` does the same — held item
	# follows the arm's pose).
	_arm_r_pivot.add_child(_bow_mesh)
	# Sprite geometry from bow.png:
	#   * Grip at image (2, 13) → mesh-local (-6, -7) after the
	#     SpriteExtruder Y-flip.
	#   * Tip at image (12, 2) → mesh-local (+4, +6).
	# Grip→tip vector = (10, 13, 0), magnitude √269.
	#
	# Three simultaneous constraints for "archer firing pose":
	#   1. Grip→tip VERTICAL in the firing pose. With arm at +π/2 X
	#      rotation (horizontal forward), arm-local -Z maps to world
	#      +Y. So grip→tip mesh diagonal → arm-local -Z. Tip points UP.
	#   2. Sprite PLANE perpendicular to camera (edge-on view). Vanilla
	#      archers don't show a "flat bow drawing" to the viewer — the
	#      bow's curve runs vertically in front of the body, viewed
	#      from the side. Mesh +Z (plane normal) must map to arm-local
	#      ±X. After arm rotation, arm-local X stays X = world ±X =
	#      perpendicular to camera view direction.
	#   3. STRING side faces the SKELETON (not the target). In bow.png
	#      the curve runs along the diagonal with the string along the
	#      OPPOSITE diagonal. Mesh "perpendicular toward string" =
	#      (+13s, -10s, 0); we want this to map to arm-local +Y so
	#      after the arm rotation (arm-local +Y → skeleton-local +Z =
	#      behind the skeleton), the string side ends up BEHIND the
	#      bow's curve relative to the archer — matching a real archer
	#      holding the bow with the string toward their body.
	#
	# Solving for orthonormal basis with these constraints:
	#   col0 = (0, +13s, -10s)
	#   col1 = (0, -10s, -13s)
	#   col2 = (-1, 0, 0)
	# All three unit-length (s² × (13² + 10²) = 1) and mutually
	# orthogonal. Verify grip→tip: 10s × col0 + 13s × col1 = (0, 0,
	# -1) ✓. Verify string side: 13s × col0 + (-10s) × col1 = (0,
	# +1, 0) → after arm rotation → skeleton-local +Z (behind) ✓.
	# Pre-multiply each col by pixel_scale (1/32) to bake the bow's
	# scale into the basis (Godot 4 `basis = Basis(...)` wipes any
	# separate `node.scale` line).
	var s: float = 1.0 / sqrt(269.0)
	_bow_mesh.basis = Basis(
		Vector3(0.0, 13.0 * s, -10.0 * s) * pixel_scale,
		Vector3(0.0, -10.0 * s, -13.0 * s) * pixel_scale,
		Vector3(-1.0, 0.0, 0.0) * pixel_scale
	)
	# Position: place the bow's CENTER at the hand. Vanilla MC holds
	# the bow at its MIDDLE — the grip is conceptually in the center
	# of the sprite with both ends (limbs) of the bow extending
	# equally above and below the hand. Earlier code offset by the
	# (-6, -7) corner so one bow end ended up at the hand and the
	# other 0.5 m above — that looked like the skeleton was holding
	# the bow by its tip. Centering the mesh on the hand puts the
	# geometric middle of the bow (≈ the grip) at the hand and both
	# bow ends symmetric around it. Matches vanilla's `m.java::b`
	# held-item render: the held item's MESH ORIGIN goes to the hand,
	# not any specific anchor pixel of the icon.
	_bow_mesh.position = Vector3(0.0, -0.75, 0.0)
	_bow_mesh.material_override = _make_bow_material(bow_tex)


# No longer needed — bow is a child of the arm pivot, so its
# transform follows the arm automatically. Kept as a no-op so the
# `_process` callsite stays valid; the comment also acts as a marker
# in case future code re-introduces world-space hand tracking.
func _update_bow_position() -> void:
	pass


# Bow needs its own material because the bow texture is opaque
# pixel-art — we want alpha-scissor for the corner transparency in
# bow.png but NOT the same shared instance as the skeleton mesh
# (different albedo).
func _make_bow_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	return mat


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
	mi.mesh = MobCube.build_textured_cube(size, _SKELETON_TEXTURE_SIZE, tex_origin, cube_px, mirror)
	mi.position = Vector3(0.0, -size.y * 0.5, 0.0)
	mi.material_override = mat
	pivot.add_child(mi)
	return pivot


func _make_textured_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	# Skeleton texture has transparent pixels around the skeletal
	# limbs (the inner 2×12 region of the 4×12 arm UV slice is opaque
	# pixels of the bone, the outer ring is fully transparent so the
	# 2×12×2 cube reads as a thin bone shape rather than a square
	# block). Without alpha-test the transparent pixels render as
	# solid white-with-zero-alpha → black under unshaded mode.
	# ALPHA_SCISSOR is sharp-edge (no fade) which matches vanilla
	# MC's alpha-discard for mob textures.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	return mat


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if _dying or _physics_gated:
		return
	# Scale AI tick rate by LOD tier — NEAR 20Hz, MID 5Hz, FAR 1Hz.
	# Far mobs still tick + can move toward player, just much less
	# often. _ai_tick itself checks `_lod_tier` to skip pathfinding
	# (A* is expensive; far mobs use straight-line wander instead).
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
	# Bow charge ticks every frame so the shot timing is smooth.
	if _ai_aiming:
		_ai_bow_charge_sec = minf(_ai_bow_charge_sec + delta, _AI_BOW_CHARGE_SEC)
	# Daylight burn check.
	_ai_burn_check_accum += delta
	if _ai_burn_check_accum >= _AI_BURN_CHECK_INTERVAL:
		_ai_burn_check_accum = 0.0
		_check_daylight_burn()


func _process(delta: float) -> void:
	super._process(delta)
	if _physics_gated:
		return
	# Skip walk animation for FAR tier — at 64+ m the leg-swing detail
	# isn't visible and the per-frame cos/sin/sqrt is wasted.
	if _lod_tier == LOD_FAR:
		return
	_advance_walk_animation(delta)
	_update_bow_position()


# --- Ranged hostile AI ---


func _ai_tick() -> void:
	# Vanilla `hf.B()` rolls the idle-sound chance per tick. Centralized
	# on MobBase so every species uses the same `nextInt(1000) < a++`
	# pattern (mean ~1 fire per 6 s, matching vanilla `b() = 80`).
	if roll_idle_sfx_tick():
		_play_idle_sfx()
	_ai_repath_counter += 1
	var player: Node3D = _find_player()
	if player == null:
		_ai_aiming = false
		_ai_bow_charge_sec = 0.0
		_wander_tick()
		return
	var dist_sq: float = global_position.distance_squared_to(player.global_position)
	if dist_sq > _AI_ABANDON_RADIUS * _AI_ABANDON_RADIUS:
		_ai_aiming = false
		_ai_bow_charge_sec = 0.0
		_ai_player_cache = null
		_wander_tick()
		return
	var dist: float = sqrt(dist_sq)
	if dist > _AI_SHOOT_RANGE:
		_ai_aiming = false
		_ai_bow_charge_sec = 0.0
		_pursue_player(player)
	elif dist < _AI_KITE_RANGE:
		_ai_aiming = false
		_ai_bow_charge_sec = 0.0
		_kite_away_from_player(player)
	else:
		_ai_path.clear()
		_face_target(player)
		_velocity_brake()
		_ai_aiming = true
		if _ai_bow_charge_sec >= _AI_BOW_CHARGE_SEC:
			_fire_arrow_at(player)
			_ai_bow_charge_sec = 0.0


func _find_player() -> Node3D:
	if _ai_player_cache != null and is_instance_valid(_ai_player_cache):
		return _ai_player_cache
	var main: Node = get_tree().root.get_node_or_null("Main")
	if main == null:
		return null
	_ai_player_cache = main.find_child("Player", true, false) as Node3D
	return _ai_player_cache


func _pursue_player(player: Node3D) -> void:
	if _ai_path.is_empty() or _ai_repath_counter >= _AI_REPATH_TICKS:
		_ai_repath_counter = 0
		_repath_to(player.global_position)
	if not _ai_path.is_empty():
		_tick_walk_path()


# Vanilla `EntityCreature` wander when no target. Uses the shared
# `MobBase.pick_wander_target` cooldown + target picker (see
# mob_base.gd). Half-speed stroll matches Alpha's wander pace
# (vanilla `EntityCreature` runs the path at `moveStrafing` ≈ 0.5).
func _wander_tick() -> void:
	if not _ai_path.is_empty():
		_tick_walk_path()
		velocity.x *= 0.5
		velocity.z *= 0.5
		return
	var target: Vector3 = pick_wander_target(_AI_TICK_DT)
	if target != Vector3.ZERO:
		_repath_to(target)
	else:
		_velocity_brake()


# Vanilla `EntityCreature.findRandomTargetBlock` retreats by picking
# a random AIR cell in the opposite hemisphere from the player; we
# project the player→self vector outward and pathfind there.
func _kite_away_from_player(player: Node3D) -> void:
	if _ai_path.is_empty() or _ai_repath_counter >= _AI_REPATH_TICKS:
		_ai_repath_counter = 0
		var away: Vector3 = global_position - player.global_position
		away.y = 0.0
		if away.length_squared() < 0.0001:
			away = Vector3(1, 0, 0)
		away = away.normalized() * 8.0  # try ~8 m away
		_repath_to(global_position + away)
	if not _ai_path.is_empty():
		_tick_walk_path()


func _repath_to(target: Vector3) -> void:
	if _chunk_manager == null:
		return
	# LOD: only NEAR-tier mobs run A* pathfinding. MID / FAR mobs just
	# steer toward the target along a straight line — Pathfinder is
	# the most expensive AI call (~1 ms per find), running it for 30+
	# distant mobs every second was a hidden cost. Distant mobs walk
	# into walls until the player approaches; acceptable trade.
	if _lod_tier != LOD_NEAR:
		_ai_path = [Vector3i(int(floor(target.x)), int(floor(target.y)), int(floor(target.z)))]
		return
	var origin: Vector3i = Vector3i(
		int(floor(global_position.x)), int(floor(global_position.y)), int(floor(global_position.z))
	)
	var goal: Vector3i = Vector3i(int(floor(target.x)), int(floor(target.y)), int(floor(target.z)))
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


# Spawn an Arrow projectile at the skeleton's bow hand, aimed at the
# player's torso (eye height - 0.4 m). Velocity = unit vector toward
# target × _AI_ARROW_SPEED. Mirrors vanilla `nq.java::e(Entity)`
# which spawns an `EntityArrow(this, target, speed)`.
func _fire_arrow_at(player: Node3D) -> void:
	if _chunk_manager == null:
		return
	# Aim at the player's body center. CharacterBody3D's
	# `global_position` is the capsule CENTER (Godot convention) —
	# NOT the feet like vanilla MC's `entity.posY`. Adding a +1.22
	# eye-offset like vanilla does to feet-pos would land us above
	# the head. Just use global_position direct.
	var target_pos: Vector3 = player.global_position
	# Spawn at body height AND in front of the skeleton so the
	# arrow's first-frame raycast doesn't hit the skeleton's own
	# collision (body capsule + head Area3D on a separate RID — Godot
	# only excludes the direct shooter, not its child collision
	# objects). Pushing 0.6 m forward in the AIM direction clears the
	# capsule (radius 0.3) + the head box (radius 0.275) comfortably.
	var aim_horiz: Vector3 = (
		Vector3(target_pos.x, 0, target_pos.z) - Vector3(global_position.x, 0, global_position.z)
	)
	if aim_horiz.length_squared() < 0.01:
		return
	var spawn_forward: Vector3 = aim_horiz.normalized() * 0.6
	var spawn_pos: Vector3 = global_position + Vector3(0, _BODY_Y_OFFSET + 0.2, 0) + spawn_forward
	var to_target: Vector3 = target_pos - spawn_pos
	if to_target.length_squared() < 0.01:
		return
	# Compensate for arrow gravity. Arrow.gd uses
	# GRAVITY_PER_TICK = 0.05 → 1.0 m/s² effective. At our 30 m/s
	# launch speed and ~8 m typical flight, drop is ~0.05 m — small
	# but adds up at the upper kite range. Add an aim offset based on
	# horizontal distance² (parabolic compensation).
	var horiz := Vector3(to_target.x, 0, to_target.z)
	var horiz_dist: float = horiz.length()
	var time_to_target: float = horiz_dist / _AI_ARROW_SPEED
	var drop_compensation: float = 0.5 * 1.0 * time_to_target * time_to_target
	to_target.y += drop_compensation
	var dir: Vector3 = to_target.normalized()
	var vel: Vector3 = dir * _AI_ARROW_SPEED
	# Vanilla scatter: small jitter so volleys don't all land on the
	# same pixel. 0.02 = ±0.6 m/s lateral drift at our launch speed —
	# noticeable but not so wild the skeleton can't hit a standing
	# target at point-blank.
	var jitter: float = 0.02
	vel.x += randf_range(-jitter, jitter) * _AI_ARROW_SPEED
	vel.y += randf_range(-jitter, jitter) * _AI_ARROW_SPEED
	vel.z += randf_range(-jitter, jitter) * _AI_ARROW_SPEED
	# Match interaction.gd::_release_bow order — call setup BEFORE
	# add_child so Arrow._ready sees the correct velocity for the
	# initial orientation pass. Then parent under Main (NOT
	# ChunkManager — vanilla skeleton arrows fly above terrain;
	# parenting under ChunkManager would tie their transform to the
	# loading/unloading lifecycle of chunks they may not be in).
	var arrow: Node3D = _ARROW_SCRIPT.new()
	if arrow.has_method("setup"):
		arrow.call("setup", self, vel, false)
	var main: Node = get_tree().root.get_node_or_null("Main")
	if main == null:
		return
	main.add_child(arrow)
	arrow.global_position = spawn_pos
	SFX.play_bow_shoot(1.0)


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


# --- Daylight burn (same as zombie) ---


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


func _is_world_daytime() -> bool:
	return WorldTime.sky_factor() > 0.5


# --- Walk animation ---


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
	# Legs: vanilla dc.java:70-71 — cos(phase) * 1.4 * walkAmount,
	# hips anti-phase.
	var leg_swing: float = cos(phase) * _LEG_AMPLITUDE * _walk_anim_amount
	if _leg_l_pivot != null:
		_leg_l_pivot.rotation.x = leg_swing
	if _leg_r_pivot != null:
		_leg_r_pivot.rotation.x = -leg_swing
	_apply_skeleton_arm_pose(phase)
	_step_accum += speed * delta
	if _step_accum >= _STEP_STRIDE:
		_step_accum -= _STEP_STRIDE
		_play_step()


# Skeleton arm pose. Walk: ModelBiped swing (anti-phase to legs)
# inherited from `dc.java::a()`. Aim: ONLY the right arm (bow arm)
# raises to horizontal forward; the left arm keeps its walk-swing
# pose.
#
# Deviation from Alpha: vanilla `gu.java` doesn't override `ck.java`'s
# arm-pose method, so Alpha skeletons render with BOTH arms locked
# horizontal (same shamble pose as ModelZombie). Modern MC (Beta+)
# uses the single-arm pose this matches. We pick modern over Alpha
# here because "both arms up" reads as zombie posture and obscures
# the bow visual.
func _apply_skeleton_arm_pose(phase: float) -> void:
	var arm_swing: float = cos(phase + PI) * _ARM_AMPLITUDE * _walk_anim_amount
	# Right arm: ALWAYS horizontal forward — same pose in rest AND aim
	# so the bow stays vertical/edge-on consistently. Vanilla skeletons
	# walk with their bow arm raised in front (the iconic "ready"
	# silhouette); swinging the bow arm with the walk cycle would
	# rotate the bow through every angle and make it look erratic.
	# Only the LEFT arm swings normally — that's the hand without a bow.
	if _arm_r_pivot != null:
		_arm_r_pivot.rotation = Vector3(_AIM_ARM_PITCH, 0.0, 0.0)
	if _arm_l_pivot != null:
		_arm_l_pivot.rotation = Vector3(-arm_swing, 0.0, 0.0)


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
	SFX.play_skeleton_step(global_position)


# Species SFX overrides — vanilla nq.java::{d, f_, f} return
# mob.skeleton / mob.skeletonhurt / mob.skeletondeath.
func _play_idle_sfx() -> void:
	SFX.play_skeleton_say(global_position)


func _play_hurt_sfx() -> void:
	SFX.play_skeleton_hurt(global_position)


func _play_death_sfx() -> void:
	SFX.play_skeleton_death(global_position)
