class_name Sheep
extends "res://scripts/entities/mob_base.gd"

# Sheep — Beta-era shearing semantics (DEVIATION from Alpha 1.2.6,
# whose `bx.java::a(lw, int)` would also drop 1-3 wool on first damage
# from an entity). We deliberately strip the punch-to-shear path so
# wool harvest goes through the proper SHEARS item only. Two ways for
# the player to get wool from a sheep:
#   * Right-click with SHEARS in hand → drop 1-3 wool, flag sheared,
#     cost 1 shears durability, NO damage. (Beta
#     `EntitySheep.a(EntityHuman)` port.)
#   * Kill an un-sheared sheep → drop 1 wool as death loot. (Beta
#     `EntitySheep.dropDeathLoot` port.)
# An already-sheared sheep drops nothing on death and can't be
# re-sheared. No regrow yet (Beta added grass-eating regrow — deferred).
#
# Model dims still come from vanilla Alpha 1.2.6 — `ia.java` extends
# `ij.java` (same base as pig/cow) but OVERRIDES head + body with
# sheep-specific dims. Wool overlay model `cg.java` is a SECOND set
# of slightly inflated parts (head 0.6, body 1.75, top-half legs 0.5)
# rendered on top with `sheep_fur.png`. When `_sheared` is true the
# wool meshes are hidden, leaving just the `sheep.png` body — the
# shaved, pink-skinned sheep look. Textures are sourced from 1.10
# (visually equivalent to Alpha but slightly cleaner palette).
#
# AI is duplicated from cow.gd — wander + flee on hit + A* pathfinding
# + vanilla ij-faithful walk animation. Future refactor will extract
# the shared passive-animal AI into a base class once the duplication
# cost outweighs the audit-against-vanilla cost.

const _SHEEP_TEXTURE_PATH: String = "res://assets/textures/mob/sheep.png"
const _WOOL_TEXTURE_PATH: String = "res://assets/textures/mob/sheep_fur.png"
const _SHEEP_TEXTURE_SIZE: Vector2i = Vector2i(64, 32)

# Vanilla model dims per `ia.java`:
#   head  d: cube 6×6×8  @ tex (0,  0)  — pivot (0, 6, -8)
#   body  e: cube 8×16×6 @ tex (28, 8)  — pivot (0, 5, 2), rotated PI/2 X
#   legs  f/g/h/i (inherited from ij with n=12): cube 4×12×4 @ tex (0, 16)
# Sheep body is narrower than cow's (8 vs 12 wide) and shorter (16 vs
# 18 long), with the same 12-px legs as cow.
const _PIXEL_TO_METER: float = 1.0 / 16.0
const _HEAD_CUBE_PX: Vector3i = Vector3i(6, 6, 8)
const _BODY_CUBE_PX: Vector3i = Vector3i(8, 16, 6)
const _LEG_CUBE_PX: Vector3i = Vector3i(4, 12, 4)
const _HEAD_TEX_ORIGIN: Vector2i = Vector2i(0, 0)
const _BODY_TEX_ORIGIN: Vector2i = Vector2i(28, 8)
const _LEG_TEX_ORIGIN: Vector2i = Vector2i(0, 16)

# Wool overlay (cg.java) — slightly inflated copies of the base parts.
# Sized in PIXEL units; inflate amount in pixels added in each direction.
#   head wool : 6×6×6  inflate 0.6  @ tex (0, 0)
#   body wool : 8×16×6 inflate 1.75 @ tex (28, 8)
#   leg  wool : 4×6×4  inflate 0.5  @ tex (0, 16)  ← only TOP half of leg
# Notice the head wool depth is 6 (NOT 8) — wool's flat at the back of
# the head rather than wrapping around to the body. And the leg wool
# only covers 6 of the 12 px = upper half (the visible "wool socks").
const _HEAD_WOOL_CUBE_PX: Vector3i = Vector3i(6, 6, 6)
const _BODY_WOOL_CUBE_PX: Vector3i = Vector3i(8, 16, 6)
const _LEG_WOOL_CUBE_PX: Vector3i = Vector3i(4, 6, 4)
const _HEAD_WOOL_INFLATE: float = 0.6
const _BODY_WOOL_INFLATE: float = 1.75
const _LEG_WOOL_INFLATE: float = 0.5

# Post-rotation world-space extents — used for collision AABB.
# Body cube 8×16×6 after -PI/2 X rotation becomes 0.5 × 0.375 × 1.0 m
# (the 6-deep axis becomes the new vertical, the 16-long becomes Z).
# Legs 4×12×4 → 0.25 × 0.75 × 0.25.
const _BODY_SIZE := Vector3(0.5, 0.375, 1.0)
const _LEG_SIZE := Vector3(0.25, 0.75, 0.25)
# Body cube vanilla MODEL center (0, 3, -2) — post +PI/2 X rotation
# around pivot (0, 5, 2), the cube ends up at MODEL Y (6, 12), Z (-8, 8).
# World (24-Y, Z): Y (0.75, 1.125), Z (-0.5, 0.5). Cube CENTER world
# (0, 0.9375, 0).
const _BODY_Y_OFFSET: float = 0.9375
const _BODY_Z_OFFSET: float = 0.0
# Head cube vanilla MODEL center (0, 5, -10) → world (0, 1.1875, -0.625).
# Sheep head sits just above body top (1.125 m), extending forward to
# Z -0.875 (head cube 0.5 m deep, range -0.875 to -0.375).
const _HEAD_OFFSET: Vector3 = Vector3(0.0, 1.1875, -0.625)
# Wool body cube center matches body (same pivot + same rotation).
const _BODY_WOOL_OFFSET: Vector3 = Vector3(0.0, 0.9375, 0.0)
# Wool head cube — pivot same (0, 6, -8), cube_offset (-3, -4, -4),
# size 6×6×6. MODEL center (0, 5, -9) → world (0, 1.1875, -0.5625).
# Slightly less forward than the base head (-0.625) since wool depth
# is 6 vs base 8.
const _HEAD_WOOL_OFFSET: Vector3 = Vector3(0.0, 1.1875, -0.5625)
# Head pivot world position — vanilla MODEL (0, 6, -8). After Y-flip
# (24-Y) we get world Y = 1.125, Z = -0.5. The head + head-wool meshes
# are children of a Node3D at this point so the eat-grass animation
# rotates them around the neck attach instead of the head's own center.
const _HEAD_PIVOT_POS: Vector3 = Vector3(0.0, 1.125, -0.5)

# Leg pivot Y at the leg's CENTER. With leg height 0.75 m, center =
# 0.375 puts the base leg cube at world Y range 0..0.75 (feet to hip).
const _LEG_Y_OFFSET: float = 0.375
# Wool leg covers the TOP HALF of the leg. cg.java cube (-2, 0, -2,
# 4, 6, 4) at pivot (±3, 12, ±5/7). MODEL Y range 12..18 → world Y
# 0.375..0.75. Cube CENTER world Y = 0.5625 — that's
# `pivot.y + leg_size.y * 0.5` (top-half center, offset upward from
# the base leg's center by 0.1875).
const _LEG_WOOL_Y_OFFSET_FROM_HIP: float = 0.1875

# Walk-animation constants — identical to cow (vanilla `ij.java::a()`
# applies the same formula to all `ij`-derived mobs).
const _WALK_FREQ: float = 0.6662
const _WALK_DIST_SCALE: float = 12.0
const _WALK_ANIM_LERP_PER_SEC: float = 8.0
const _LEG_AMPLITUDE: float = 1.4
const _STEP_STRIDE: float = 1.8  # between pig's 1.0 and cow's 2.0

# AI — direct copy of cow.gd. See pig.gd for vanilla-source citations.
const _AI_TICK_DT: float = 1.0 / 20.0
const _AI_WANDER_X_RANGE: int = 6
const _AI_WANDER_Y_RANGE: int = 3
const _AI_NEW_TARGET_DENOM: int = 80
const _AI_ABANDON_DENOM: int = 100
const _AI_YAW_TWITCH_CHANCE: float = 0.05
const _AI_YAW_TWITCH_RANGE: float = PI / 18.0
const _AI_SCORE_GRASS: float = 10.0
const _AI_SCORE_LIGHT_OFFSET: float = -0.5
const _AI_ARRIVE_DIST: float = 0.7
const _AI_WALK_SPEED: float = 0.7
const _AI_MAX_YAW_STEP: float = PI / 6.0
const _AI_PATHFIND_RADIUS: float = 16.0
const _AI_PATHFIND_MAX_ITERS: int = 200
const _AI_FLEE_TICKS: int = 60
const _AI_FLEE_SPEED: float = 1.4
const _AI_JUMP_VELOCITY: float = 6.0
const _AI_STEP_BOOST_SPEED: float = 2.0

# Wool drop count — vanilla bx.java line 17: `1 + rand.nextInt(3)` = 1-3.
const _WOOL_DROP_MIN: int = 1
const _WOOL_DROP_MAX: int = 3

# Eat-grass wool regrow — Beta `PathfinderGoalEatTile` (Bukkit/mc-dev).
# `a()` rolls 1/1000 per tick to start the goal when there's grass at
# feet (we don't have tall_grass yet, so only the grass-block path is
# wired). `c()` sets the timer to 40 ticks (= 2 s). `e()` ticks down;
# when the counter hits 4, the grass cell flips to dirt and `p()` is
# called on the sheep → `setSheared(false)` regrows the wool. The
# trailing 4 ticks are post-eat anim before the goal fully releases.
const _EAT_DURATION_TICKS: int = 40
const _EAT_REGROW_AT_TICK: int = 4
const _EAT_START_CHANCE_DENOM: int = 1000  # 1/1000 per AI tick on grass
# Head pitches forward + down while eating. Vanilla uses a sin-curve via
# `partialTick` interpolation against `EntitySheep.f()` (counter / 40 →
# 0..1 phase). We approximate with a linear lerp toward _EAT_HEAD_PITCH.
# NEGATIVE sign — sheep faces -Z, so positive X rotation tips the head
# UP/BACK (chin lifts toward the sky). To tip DOWN/FORWARD (chin to
# ground for eating) we need negative pitch.
const _EAT_HEAD_PITCH: float = -0.7  # radians; head tips toward ground
const _EAT_HEAD_LERP_PER_SEC: float = 8.0

# Leg-mesh refs for walk animation (base body legs).
var _leg_front_l: MeshInstance3D
var _leg_front_r: MeshInstance3D
var _leg_rear_l: MeshInstance3D
var _leg_rear_r: MeshInstance3D
# Wool overlay refs — toggled visible when not sheared, hidden when
# sheared. Includes head wool, body wool, and 4 leg-wool meshes.
var _wool_meshes: Array[MeshInstance3D] = []
# Sheared state — persisted via NBT in vanilla bx.java (key "Sheared"),
# we round-trip via to_save_dict/restore_from_dict. Once true, drops
# no more wool and the wool overlay stays hidden.
var _sheared: bool = false

var _walk_dist: float = 0.0
var _walk_anim_amount: float = 0.0
var _step_accum: float = 0.0

# AI state.
var _ai_tick_accum: float = 0.0
var _ai_path: Array = []
var _ai_flee_ticks_remaining: int = 0
var _ai_flee_from: Vector3 = Vector3.ZERO

# Eat-grass state — non-zero `_eat_ticks_remaining` means the sheep is
# mid-eat (head pitched, velocity zeroed, walk anim paused). The head
# pivot Node3D parents the head + wool meshes so the eat-animation
# rotates them around the neck (vanilla `EntitySheep.f()` interpolant).
var _eat_ticks_remaining: int = 0
var _head_pivot: Node3D
var _head_pitch_current: float = 0.0


# MobBase environment overrides — sheep BB total height = body + legs =
# 0.375 + 0.75 = 1.125 m. Eye height ~0.95 m (head sits above body).
# Width = body X axis (0.5 m, slimmer than cow's 0.75).
func _get_body_height() -> float:
	return _BODY_SIZE.y + _LEG_SIZE.y


func _get_eye_height() -> float:
	return 0.95


func _get_body_width() -> float:
	return _BODY_SIZE.x


func _ready() -> void:
	max_health = 10  # vanilla hf.J default
	# drop_item_id stays 0 — sheep death-loot is special-cased in
	# `die()` because it depends on the `_sheared` flag (1 wool if
	# un-sheared, nothing if sheared). The int-id pipeline can't
	# express that conditional, so we bypass it.
	_build_collision_shape()
	_build_model()
	super._ready()


func _physics_process(delta: float) -> void:
	super._physics_process(delta)  # super handles dying short-circuit
	if _dying:
		return
	_ai_tick_accum += delta
	while _ai_tick_accum >= _AI_TICK_DT:
		_ai_tick_accum -= _AI_TICK_DT
		_ai_tick()


func _process(delta: float) -> void:
	super._process(delta)
	_advance_walk_animation(delta)
	_advance_head_pitch(delta)


# Lerp the head pivot toward _EAT_HEAD_PITCH while eating, back to 0
# otherwise. Vanilla `EntitySheep.f()` returns the counter for the
# renderer to drive a sin-curve interpolant; a linear lerp reads close
# enough and keeps the state-transition code in one place.
func _advance_head_pitch(delta: float) -> void:
	if _head_pivot == null:
		return
	var target: float = _EAT_HEAD_PITCH if _eat_ticks_remaining > 0 else 0.0
	var lerp_t: float = minf(_EAT_HEAD_LERP_PER_SEC * delta, 1.0)
	_head_pitch_current = lerpf(_head_pitch_current, target, lerp_t)
	_head_pivot.rotation.x = _head_pitch_current


# Two-shape collision (MobBase helpers). Body capsule = physics-only
# (centered on origin, symmetric around Y → no rotation-induced
# stuck-clipping). Head Area3D = hit-only, sized to cover the head so
# arrow + sword hits land on the protruding silhouette.
#
# Body capsule: radius = _BODY_SIZE.x / 2 = 0.25, height = body + legs
# = 0.375 + 0.75 = 1.125. Use 1.375 to keep the wool tuft at the top
# inside the body's hit volume too.
#
# Head box covers HEAD_OFFSET (0, 1.1875, -0.625) for a 6×6×8 px head
# (0.375 × 0.375 × 0.5). Slightly larger size for edge-hit margin.
func _build_collision_shape() -> void:
	_build_body_capsule(_BODY_SIZE.x * 0.5, 1.375)
	_build_head_hit_area(Vector3(0.4, 0.4, 0.55), _HEAD_OFFSET)


# Builds the base sheep body (always visible) + the wool overlay
# (visible when not sheared). The wool meshes are kept in `_wool_meshes`
# so `_set_sheared(true)` can hide them in one pass.
func _build_model() -> void:
	var body_tex: Texture2D = load(_SHEEP_TEXTURE_PATH) as Texture2D
	var wool_tex: Texture2D = load(_WOOL_TEXTURE_PATH) as Texture2D
	var body_mat: StandardMaterial3D = _make_textured_material(body_tex)
	var wool_mat: StandardMaterial3D = _make_textured_material(wool_tex)
	# Body (overrides ij.java's base body): cube 8×16×6 at tex (28, 8),
	# rotated -PI/2 X to lay horizontal.
	var body_mesh_size := Vector3(
		_BODY_CUBE_PX.x * _PIXEL_TO_METER,
		_BODY_CUBE_PX.y * _PIXEL_TO_METER,
		_BODY_CUBE_PX.z * _PIXEL_TO_METER
	)
	var body_mesh := MeshInstance3D.new()
	body_mesh.mesh = MobCube.build_textured_cube(
		body_mesh_size, _SHEEP_TEXTURE_SIZE, _BODY_TEX_ORIGIN, _BODY_CUBE_PX, false
	)
	body_mesh.position = Vector3(0, _BODY_Y_OFFSET, _BODY_Z_OFFSET)
	body_mesh.rotation = Vector3(-PI * 0.5, 0, 0)
	body_mesh.material_override = body_mat
	add_child(body_mesh)
	# Body wool — same shape, slightly inflated, sheep_fur.png. Inflate
	# expands the mesh by INFLATE_PX in each direction without
	# scaling the UV (matches vanilla `ka.a(_, _, _, _, _, _, scale)`).
	var body_wool_size := (
		body_mesh_size
		+ Vector3(
			2.0 * _BODY_WOOL_INFLATE * _PIXEL_TO_METER,
			2.0 * _BODY_WOOL_INFLATE * _PIXEL_TO_METER,
			2.0 * _BODY_WOOL_INFLATE * _PIXEL_TO_METER,
		)
	)
	var body_wool := MeshInstance3D.new()
	body_wool.mesh = MobCube.build_textured_cube(
		body_wool_size, _SHEEP_TEXTURE_SIZE, _BODY_TEX_ORIGIN, _BODY_WOOL_CUBE_PX, false
	)
	body_wool.position = _BODY_WOOL_OFFSET
	body_wool.rotation = Vector3(-PI * 0.5, 0, 0)
	body_wool.material_override = wool_mat
	add_child(body_wool)
	_wool_meshes.append(body_wool)
	# Head pivot Node3D at the neck attach. Head + head-wool meshes are
	# children so `_head_pivot.rotation.x` rotates them around the neck
	# (vanilla animation pivot), used by the eat-grass head-pitch anim.
	_head_pivot = Node3D.new()
	_head_pivot.position = _HEAD_PIVOT_POS
	add_child(_head_pivot)
	# Head: 6×6×8 at tex (0, 0). No rotation; eyes on -Z face. Position
	# is the head-cube center relative to the pivot.
	var head_size := Vector3(
		_HEAD_CUBE_PX.x * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.y * _PIXEL_TO_METER,
		_HEAD_CUBE_PX.z * _PIXEL_TO_METER
	)
	var head_mesh := MeshInstance3D.new()
	head_mesh.mesh = MobCube.build_textured_cube(
		head_size, _SHEEP_TEXTURE_SIZE, _HEAD_TEX_ORIGIN, _HEAD_CUBE_PX, false
	)
	head_mesh.position = _HEAD_OFFSET - _HEAD_PIVOT_POS
	head_mesh.material_override = body_mat
	_head_pivot.add_child(head_mesh)
	# Head wool — 6×6×6 (shallower than the 6×6×8 base head) + 0.6 inflate.
	var head_wool_size := Vector3(
		_HEAD_WOOL_CUBE_PX.x * _PIXEL_TO_METER + 2.0 * _HEAD_WOOL_INFLATE * _PIXEL_TO_METER,
		_HEAD_WOOL_CUBE_PX.y * _PIXEL_TO_METER + 2.0 * _HEAD_WOOL_INFLATE * _PIXEL_TO_METER,
		_HEAD_WOOL_CUBE_PX.z * _PIXEL_TO_METER + 2.0 * _HEAD_WOOL_INFLATE * _PIXEL_TO_METER,
	)
	var head_wool := MeshInstance3D.new()
	head_wool.mesh = MobCube.build_textured_cube(
		head_wool_size, _SHEEP_TEXTURE_SIZE, _HEAD_TEX_ORIGIN, _HEAD_WOOL_CUBE_PX, false
	)
	head_wool.position = _HEAD_WOOL_OFFSET - _HEAD_PIVOT_POS
	head_wool.material_override = wool_mat
	_head_pivot.add_child(head_wool)
	_wool_meshes.append(head_wool)
	# 4 legs per ij.java defaults — sheep doesn't override leg pivots.
	#   h front-right: MODEL (-3, 12, -5) → Godot (+0.1875, hip, -0.3125)
	#   i front-left:  MODEL ( 3, 12, -5) → Godot (-0.1875, hip, -0.3125)
	#   f rear-right:  MODEL (-3, 12,  7) → Godot (+0.1875, hip, +0.4375)
	#   g rear-left:   MODEL ( 3, 12,  7) → Godot (-0.1875, hip, +0.4375)
	var leg_x: float = 3.0 / 16.0
	var leg_z_front: float = -5.0 / 16.0
	var leg_z_rear: float = 7.0 / 16.0
	_leg_front_r = _add_leg(Vector3(leg_x, _LEG_Y_OFFSET, leg_z_front), body_mat, wool_mat, false)
	_leg_front_l = _add_leg(Vector3(-leg_x, _LEG_Y_OFFSET, leg_z_front), body_mat, wool_mat, true)
	_leg_rear_r = _add_leg(Vector3(leg_x, _LEG_Y_OFFSET, leg_z_rear), body_mat, wool_mat, false)
	_leg_rear_l = _add_leg(Vector3(-leg_x, _LEG_Y_OFFSET, leg_z_rear), body_mat, wool_mat, true)


# Build one leg as a hip-pivot Node3D holding TWO meshes: the base 4×12×4
# leg cube + the wool overlay (4×6×4 inflated 0.5) covering the upper
# half. Both meshes rotate together when the pivot's X rotation is set
# by the walk animation, so the wool socks swing with the leg.
func _add_leg(
	hip_pos: Vector3, body_mat: StandardMaterial3D, wool_mat: StandardMaterial3D, mirror: bool
) -> MeshInstance3D:
	var pivot := Node3D.new()
	var leg_size := Vector3(
		_LEG_CUBE_PX.x * _PIXEL_TO_METER,
		_LEG_CUBE_PX.y * _PIXEL_TO_METER,
		_LEG_CUBE_PX.z * _PIXEL_TO_METER
	)
	# Pivot at HIP (top of leg) so the walk anim rotation pivots at the
	# leg's attach point to the body, not at the leg's center.
	pivot.position = Vector3(hip_pos.x, hip_pos.y + leg_size.y * 0.5, hip_pos.z)
	add_child(pivot)
	var leg_mesh := MeshInstance3D.new()
	leg_mesh.mesh = MobCube.build_textured_cube(
		leg_size, _SHEEP_TEXTURE_SIZE, _LEG_TEX_ORIGIN, _LEG_CUBE_PX, mirror
	)
	leg_mesh.position = Vector3(0, -leg_size.y * 0.5, 0)
	leg_mesh.material_override = body_mat
	pivot.add_child(leg_mesh)
	# Wool overlay on the leg's TOP HALF. Cube 4×6×4 + 0.5 inflate =
	# 5×7×5 px. Center (in pivot-local) at Y = -leg_size.y * 0.5 +
	# _LEG_WOOL_Y_OFFSET_FROM_HIP = -0.375 + 0.1875 = -0.1875.
	var wool_leg_size := Vector3(
		_LEG_WOOL_CUBE_PX.x * _PIXEL_TO_METER + 2.0 * _LEG_WOOL_INFLATE * _PIXEL_TO_METER,
		_LEG_WOOL_CUBE_PX.y * _PIXEL_TO_METER + 2.0 * _LEG_WOOL_INFLATE * _PIXEL_TO_METER,
		_LEG_WOOL_CUBE_PX.z * _PIXEL_TO_METER + 2.0 * _LEG_WOOL_INFLATE * _PIXEL_TO_METER,
	)
	var wool_leg_mesh := MeshInstance3D.new()
	wool_leg_mesh.mesh = MobCube.build_textured_cube(
		wool_leg_size, _SHEEP_TEXTURE_SIZE, _LEG_TEX_ORIGIN, _LEG_WOOL_CUBE_PX, mirror
	)
	wool_leg_mesh.position = Vector3(0, -leg_size.y * 0.5 + _LEG_WOOL_Y_OFFSET_FROM_HIP, 0)
	wool_leg_mesh.material_override = wool_mat
	pivot.add_child(wool_leg_mesh)
	_wool_meshes.append(wool_leg_mesh)
	return leg_mesh


func _make_textured_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	return mat


# --- Shearing (vanilla bx.java + Beta ItemShears + Beta EntitySheep) ---


# Apply the sheared state: hide all wool meshes, set the persisted flag.
# Idempotent — safe to call when already sheared.
func _set_sheared(value: bool) -> void:
	_sheared = value
	for mi: MeshInstance3D in _wool_meshes:
		mi.visible = not value


# Drop 1-3 wool items at the sheep's position with a small upward + random
# horizontal kick (matches vanilla bx.java lines 17-23 / Beta
# EntitySheep.a(EntityHuman) lines around the wool drop loop). Idempotent
# in the sense that if already sheared it's a no-op — the caller is
# expected to gate on `not _sheared`, but we double-check to be safe.
func _drop_wool() -> void:
	if _sheared or _chunk_manager == null:
		return
	var count: int = randi_range(_WOOL_DROP_MIN, _WOOL_DROP_MAX)
	for _i in range(count):
		var item := DroppedItem.new()
		_chunk_manager.add_child(item)
		var jitter := Vector3(randf_range(-0.1, 0.1), 0.3, randf_range(-0.1, 0.1))
		item.global_position = global_position + Vector3(0, 0.7, 0) + jitter
		item.setup(Blocks.WOOL_WHITE)


# Standard damage handler — no wool drop here. Beta-style: damage just
# damages, and shearing only happens via SHEARS right-click. The
# un-sheared death-loot drop is in `die()`.
func take_damage(
	amount: int,
	knockback_dir: Vector3 = Vector3.ZERO,
	knockback_strength: float = 1.0,
	attacker: Node = null
) -> bool:
	var landed: bool = super.take_damage(amount, knockback_dir, knockback_strength, attacker)
	if landed and knockback_dir.length_squared() > 0.0001:
		_ai_flee_ticks_remaining = _AI_FLEE_TICKS
		_ai_flee_from = global_position - knockback_dir.normalized()
		_ai_path.clear()
	return landed


# Beta `EntitySheep.dropDeathLoot` port — drop 1 wool on death only if
# the sheep was never sheared. Already-sheared sheep drops nothing.
# Runs BEFORE super.die() so the wool spawn uses the live position
# (super marks _dying = true and freezes physics for the tilt anim).
func die() -> void:
	if _dying:
		return
	if not _sheared and _chunk_manager != null:
		var item := DroppedItem.new()
		_chunk_manager.add_child(item)
		var jitter := Vector3(randf_range(-0.1, 0.1), 0.3, randf_range(-0.1, 0.1))
		item.global_position = global_position + Vector3(0, 0.7, 0) + jitter
		item.setup(Blocks.WOOL_WHITE)
	super.die()


# Beta `EntitySheep.a(EntityHuman)` shear-with-shears branch — drop wool
# WITHOUT damaging the sheep, set sheared, cost the shears 1 durability.
# Called by interaction.gd when the player right-clicks with shears in
# hand. Returns true if the shears were consumed (= sheep was un-sheared
# and got sheared just now); false if no-op (already sheared, or wrong
# item — but the latter is gated by the caller).
func right_click_with(item_id: int, player: Node) -> bool:
	if item_id != Items.SHEARS or _sheared:
		return false
	_drop_wool()
	_set_sheared(true)
	# Decrement shears durability via the player's inventory — same path
	# block-break uses (`damage_selected_tool` applies 1 use per call and
	# emits `changed` so the durability bar updates).
	var inv: Object = player.get("inventory") if player != null else null
	if inv != null and inv.has_method("damage_selected_tool"):
		inv.damage_selected_tool()
	return true


# --- AI tick (mirrors cow.gd; see pig.gd for vanilla-source citations) ---


func _ai_tick() -> void:
	# Vanilla `hf.B()` rolls the idle-sound chance per tick. Centralized
	# on MobBase so every species uses the same `nextInt(1000) < a++`
	# pattern (mean ~1 fire per 6 s, matching vanilla `b() = 80`).
	if roll_idle_sfx_tick():
		_play_idle_sfx()
	# Eat-grass takes priority — pinned in place, no AI moves while
	# mid-eat. Beta `PathfinderGoalEatTile.e()` decrements once per tick
	# and fires the grass→dirt + wool-regrow at counter == 4.
	if _eat_ticks_remaining > 0:
		_tick_eating()
		return
	if _ai_flee_ticks_remaining > 0:
		_ai_flee_ticks_remaining -= 1
		_tick_flee()
		return
	if not _ai_path.is_empty():
		_tick_walk_path()
	else:
		_tick_idle()
	# Roll for eat-start AFTER the regular tick so the sheep has a chance
	# to wander/idle this frame. Vanilla `PathfinderGoalEatTile.a()`
	# checks at goal-evaluation rate (every tick) with 1/1000 probability
	# while sheared and on grass.
	if _sheared and _eat_ticks_remaining == 0:
		_try_start_eating()


# 1/1000 per tick, vanilla `PathfinderGoalEatTile.a()`. Triggers only
# when the block one cell below the sheep's feet is GRASS — tall-grass
# isn't shipped yet, so its branch is omitted.
func _try_start_eating() -> void:
	if _chunk_manager == null:
		return
	if randi() % _EAT_START_CHANCE_DENOM != 0:
		return
	var below: Vector3i = Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y - 0.05)),
		int(floor(global_position.z)),
	)
	if _chunk_manager.get_world_block(below) != Blocks.GRASS:
		return
	# Start the goal: timer set, navigation cleared, velocity zeroed so
	# the sheep stays anchored over the grass cell during the animation.
	_eat_ticks_remaining = _EAT_DURATION_TICKS
	_ai_path.clear()
	velocity.x = 0.0
	velocity.z = 0.0


# Per-tick update while eating. Mirrors Beta `PathfinderGoalEatTile.e()`:
# decrement counter; at counter == 4 mutate the grass cell + call the
# regrow hook; remaining 4 ticks are post-eat anim before the goal ends.
func _tick_eating() -> void:
	_eat_ticks_remaining -= 1
	velocity.x = 0.0
	velocity.z = 0.0
	if _eat_ticks_remaining == _EAT_REGROW_AT_TICK:
		_consume_grass_and_regrow()


# Convert the grass cell under the sheep to dirt + clear `_sheared` so
# the wool overlay re-shows. Idempotent — if the cell isn't grass
# anymore (player broke it mid-eat), just regrow wool without mutating.
func _consume_grass_and_regrow() -> void:
	if _chunk_manager == null:
		return
	var below: Vector3i = Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y - 0.05)),
		int(floor(global_position.z)),
	)
	if _chunk_manager.get_world_block(below) == Blocks.GRASS:
		_chunk_manager.set_world_block(below, Blocks.DIRT)
	_set_sheared(false)


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
	if next_node.y > current_cell_y and mob_is_on_floor():
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


# --- Walk animation (mirrors cow.gd; vanilla ij.java::a) ---


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
	if _leg_rear_l != null:
		_leg_rear_l.get_parent().rotation.x = swing_a
	if _leg_rear_r != null:
		_leg_rear_r.get_parent().rotation.x = swing_b
	if _leg_front_l != null:
		_leg_front_l.get_parent().rotation.x = swing_b
	if _leg_front_r != null:
		_leg_front_r.get_parent().rotation.x = swing_a
	_step_accum += speed * delta
	if _step_accum >= _STEP_STRIDE:
		_step_accum -= _STEP_STRIDE
		_play_block_step()


# Step sound from the BLOCK below — vanilla `lw.java::a_` uses
# Block.stepSound, NOT a mob-specific clip.
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


# Species SFX overrides — vanilla bx.java d/f_/f all return "mob.sheep"
# (sheep uses ONE clip pool for idle, hurt, AND death).
func _play_idle_sfx() -> void:
	SFX.play_sheep_say(global_position)


func _play_hurt_sfx() -> void:
	SFX.play_sheep_say(global_position)


func _play_death_sfx() -> void:
	SFX.play_sheep_say(global_position)


# --- Persistence (sheared state) ---


func to_save_dict() -> Dictionary:
	var d: Dictionary = super.to_save_dict()
	d["sheared"] = _sheared
	return d


func restore_from_dict(d: Dictionary) -> void:
	super.restore_from_dict(d)
	if d.has("sheared"):
		_set_sheared(d["sheared"])
