extends Node3D

# Blocky Steve player model textured with a 64x64 MC-format skin.
# Built programmatically so animation logic can grab limb anchors by name.
# Proportions: head 8x8x8, body 8x12x4, limbs 4x12x4 (in MC pixels = ÷16
# blocks). Total height ≈ 1.8 blocks = matches the player capsule.

# Resolved per call from the active texture pack (BlockAtlas.active_pack) so
# switching pack at boot switches the Steve skin too. A pack without a steve
# override falls back to pixel_perfection.
const SKIN_FALLBACK_PACK: String = "pixel_perfection"
const ARMOR_BASE_PATH: String = "res://assets/textures/entities/armor/"

# Small uniform inflation applied to each armor overlay box so it visually
# sits on TOP of the body piece without z-fighting. Vanilla uses 0.5 /
# 16 = 0.03125 blocks per side; we scale by overlay_scale(size) below to
# apply the same net inflation regardless of limb size.
const ARMOR_INFLATION: float = 0.03

const ARM_SIZE: Vector3 = Vector3(0.25, 0.75, 0.25)
const LEG_SIZE: Vector3 = Vector3(0.25, 0.75, 0.25)

# First-person arm — forearm-sized box that samples ONLY the bottom 4
# pixels of the right-arm region (the hand itself). Stretching the hand
# pixels across the whole box guarantees we never pick up sleeve color,
# while still respecting whatever skin tone is in the loaded skin texture.
const FP_ARM_SIZE: Vector3 = Vector3(0.28, 0.6, 0.28)

# UV rects per face in normalized [0,1] space, ordered:
#   [+Y top, -Y bottom, +X right, -X left, +Z back, -Z front]
# These map a standard 64x64 MC skin layout onto each body-part box.
const _HEAD_UVS: Array[Rect2] = [
	Rect2(0.125, 0.0, 0.125, 0.125),
	Rect2(0.25, 0.0, 0.125, 0.125),
	Rect2(0.0, 0.125, 0.125, 0.125),
	Rect2(0.25, 0.125, 0.125, 0.125),
	Rect2(0.375, 0.125, 0.125, 0.125),
	Rect2(0.125, 0.125, 0.125, 0.125),
]
const _BODY_UVS: Array[Rect2] = [
	Rect2(0.3125, 0.25, 0.125, 0.0625),
	Rect2(0.4375, 0.25, 0.125, 0.0625),
	Rect2(0.25, 0.3125, 0.0625, 0.1875),
	Rect2(0.4375, 0.3125, 0.0625, 0.1875),
	Rect2(0.5, 0.3125, 0.125, 0.1875),
	Rect2(0.3125, 0.3125, 0.125, 0.1875),
]
const _ARM_R_UVS: Array[Rect2] = [
	Rect2(0.6875, 0.25, 0.0625, 0.0625),
	Rect2(0.75, 0.25, 0.0625, 0.0625),
	Rect2(0.625, 0.3125, 0.0625, 0.1875),
	Rect2(0.75, 0.3125, 0.0625, 0.1875),
	Rect2(0.8125, 0.3125, 0.0625, 0.1875),
	Rect2(0.6875, 0.3125, 0.0625, 0.1875),
]

# FP arm UVs — the right-arm region, but with the top and bottom cap rects
# swapped. The FP arm box is oriented with its +Y end (face 0 of the UV
# array) pointing forward toward the fingertip. Without this swap, face 0
# samples the arm's top cap — which is sleeve pixels in any skin with a
# colored shirt — producing a visible blue/red/whatever blob at the
# fingertip. Swapping puts the arm's bottom cap (skin-colored hand) there
# instead. `flip_v_sides=true` handles the side faces separately so the
# wrist end shows sleeve and the fingertip end shows bare skin.
const _FP_ARM_R_UVS: Array[Rect2] = [
	_ARM_R_UVS[1],  # +Y (fingertip) → arm's bottom cap (hand)
	_ARM_R_UVS[0],  # -Y (wrist)     → arm's top cap (sleeve)
	_ARM_R_UVS[2],
	_ARM_R_UVS[3],
	_ARM_R_UVS[4],
	_ARM_R_UVS[5],
]
const _ARM_L_UVS: Array[Rect2] = [
	Rect2(0.5625, 0.75, 0.0625, 0.0625),
	Rect2(0.625, 0.75, 0.0625, 0.0625),
	Rect2(0.5, 0.8125, 0.0625, 0.1875),
	Rect2(0.625, 0.8125, 0.0625, 0.1875),
	Rect2(0.6875, 0.8125, 0.0625, 0.1875),
	Rect2(0.5625, 0.8125, 0.0625, 0.1875),
]
const _LEG_R_UVS: Array[Rect2] = [
	Rect2(0.0625, 0.25, 0.0625, 0.0625),
	Rect2(0.125, 0.25, 0.0625, 0.0625),
	Rect2(0.0, 0.3125, 0.0625, 0.1875),
	Rect2(0.125, 0.3125, 0.0625, 0.1875),
	Rect2(0.1875, 0.3125, 0.0625, 0.1875),
	Rect2(0.0625, 0.3125, 0.0625, 0.1875),
]
const _LEG_L_UVS: Array[Rect2] = [
	Rect2(0.3125, 0.75, 0.0625, 0.0625),
	Rect2(0.375, 0.75, 0.0625, 0.0625),
	Rect2(0.25, 0.8125, 0.0625, 0.1875),
	Rect2(0.375, 0.8125, 0.0625, 0.1875),
	Rect2(0.4375, 0.8125, 0.0625, 0.1875),
	Rect2(0.3125, 0.8125, 0.0625, 0.1875),
]

# Armor UVs — all layer textures are 64×32 (legacy Alpha-era layout, same
# as pre-1.8 vanilla). Pixel coords match the body-skin regions since armor
# is drawn as an inflated overlay on the corresponding body part. These
# rects use the RIGHT-side pixel regions; the left-side limbs reuse the
# same rects (left=mirror of right in 64×32 format — there are no
# dedicated left-side pixels).
const _ARMOR_HEAD_UVS: Array[Rect2] = [
	Rect2(0.125, 0.0, 0.125, 0.25),  # +Y top: (8, 0, 8, 8)
	Rect2(0.25, 0.0, 0.125, 0.25),  # -Y bottom: (16, 0, 8, 8)
	Rect2(0.0, 0.25, 0.125, 0.25),  # +X right: (0, 8, 8, 8)
	Rect2(0.25, 0.25, 0.125, 0.25),  # -X left: (16, 8, 8, 8)
	Rect2(0.375, 0.25, 0.125, 0.25),  # +Z back: (24, 8, 8, 8)
	Rect2(0.125, 0.25, 0.125, 0.25),  # -Z front: (8, 8, 8, 8)
]
const _ARMOR_BODY_UVS: Array[Rect2] = [
	Rect2(0.3125, 0.5, 0.125, 0.125),  # top: (20, 16, 8, 4)
	Rect2(0.4375, 0.5, 0.125, 0.125),  # bottom: (28, 16, 8, 4)
	Rect2(0.25, 0.625, 0.0625, 0.375),  # right: (16, 20, 4, 12)
	Rect2(0.4375, 0.625, 0.0625, 0.375),  # left: (28, 20, 4, 12)
	Rect2(0.5, 0.625, 0.125, 0.375),  # back: (32, 20, 8, 12)
	Rect2(0.3125, 0.625, 0.125, 0.375),  # front: (20, 20, 8, 12)
]
const _ARMOR_ARM_UVS: Array[Rect2] = [
	Rect2(0.6875, 0.5, 0.0625, 0.125),  # top: (44, 16, 4, 4)
	Rect2(0.75, 0.5, 0.0625, 0.125),  # bottom: (48, 16, 4, 4)
	Rect2(0.625, 0.625, 0.0625, 0.375),  # right: (40, 20, 4, 12)
	Rect2(0.75, 0.625, 0.0625, 0.375),  # left: (48, 20, 4, 12)
	Rect2(0.8125, 0.625, 0.0625, 0.375),  # back: (52, 20, 4, 12)
	Rect2(0.6875, 0.625, 0.0625, 0.375),  # front: (44, 20, 4, 12)
]
const _ARMOR_LEG_UVS: Array[Rect2] = [
	Rect2(0.0625, 0.5, 0.0625, 0.125),  # top: (4, 16, 4, 4)
	Rect2(0.125, 0.5, 0.0625, 0.125),  # bottom: (8, 16, 4, 4)
	Rect2(0.0, 0.625, 0.0625, 0.375),  # right: (0, 20, 4, 12)
	Rect2(0.125, 0.625, 0.0625, 0.375),  # left: (8, 20, 4, 12)
	Rect2(0.1875, 0.625, 0.0625, 0.375),  # back: (12, 20, 4, 12)
	Rect2(0.0625, 0.625, 0.0625, 0.375),  # front: (4, 20, 4, 12)
]

const WALK_SWING_DEG: float = 38.0
# Tuned so a full stride cycle at WALK_SPEED (4.317 m/s) is ≈1.5 Hz — matches
# vanilla MC's leg-swing rhythm. Higher values = faster jittery limbs.
const WALK_FREQUENCY: float = 0.35  # cycles per second per m/s of speed
const RETURN_TO_REST_RATE: float = 10.0  # ease back to neutral when stopped
const MINING_SWING_DEG: float = 50.0
# Vanilla MC plays a fixed 6-tick (0.3s) swing cycle. Mid-swing release lets
# the current cycle complete (no instant snap-back to rest).
const SWING_DURATION_SEC: float = 0.30

# Third-person fire rendering. Vanilla Render.renderEntityOnFire
# (Render.java) draws animated fire quads around the entity AABB when
# `entity.bg > 0`. We use four billboarded quads (front/back/left/right)
# sharing the canonical Beta fire_layer_0.png strip at 24 FPS. Kept
# hidden until set_on_fire(true).
const _FIRE_STRIP_PATH_0: String = "res://assets/textures/particles/fire_layer_0.png"
const _FIRE_STRIP_PATH_1: String = "res://assets/textures/particles/fire_layer_1.png"
const _FIRE_STRIP_FRAMES: int = 32
const _FIRE_STRIP_CELL_PX: int = 16
const _FIRE_ANIM_FPS: float = 24.0

var head: MeshInstance3D
var body: MeshInstance3D
var arm_l: Node3D
var arm_r: Node3D
var leg_l: Node3D
var leg_r: Node3D

var _skin_mat: StandardMaterial3D
# Armor overlay meshes — parallel to the body parts. Each is a slightly-
# inflated textured box that sits on top of its base part; set visible
# and point material.albedo_texture at the right armor-layer to equip.
var _armor_head: MeshInstance3D
var _armor_body: MeshInstance3D
var _armor_arm_l: MeshInstance3D
var _armor_arm_r: MeshInstance3D
var _armor_leg_l_upper: MeshInstance3D  # leggings
var _armor_leg_r_upper: MeshInstance3D  # leggings
var _armor_leg_l_lower: MeshInstance3D  # boots
var _armor_leg_r_lower: MeshInstance3D  # boots
var _armor_mat_cache: Dictionary = {}  # path -> StandardMaterial3D
var _walk_phase: float = 0.0
var _swing_progress: float = 0.0  # 0..1 within the current swing cycle
# Mounted-pose flag — when true the legs lock into a sitting bend at
# the hip (~90° forward). update_walk_animation skips its leg writes
# while this is true so the pose stays put. Player.set_mount toggles it.
var _mounted_pose: bool = false
var _swing_active_visual: bool = false

var _fire_pivot: Node3D
var _fire_sprites: Array[Sprite3D] = []
var _fire_anim_time: float = 0.0
var _fire_visible: bool = false

# Cached ChunkManager + last-applied brightness so we only push a new
# albedo_color when it actually changes. World-light reads are dict
# lookups + small math; the cost is in the material rebuild + GPU
# uniform write that follows, which we skip on identical values.
var _chunk_manager_ref: Node = null
var _last_brightness: float = -1.0


func _ready() -> void:
	_skin_mat = _build_skin_material()
	_build_parts()
	_build_fire_billboards()
	set_process(true)
	_chunk_manager_ref = get_tree().root.get_node_or_null("Main/ChunkManager")


func update_walk_animation(speed: float, delta: float, skip_right_arm: bool = false) -> void:
	# Mounted-pose lock: legs are pinned forward to the sitting bend,
	# so we don't overwrite their rotation each frame. Arms still relax
	# / swing normally (vanilla rider's arms stay free while seated).
	if _mounted_pose:
		var t_arm: float = clampf(delta * RETURN_TO_REST_RATE, 0.0, 1.0)
		if not skip_right_arm:
			arm_r.rotation.x = lerpf(arm_r.rotation.x, 0.0, t_arm)
		arm_l.rotation.x = lerpf(arm_l.rotation.x, 0.0, t_arm)
		_walk_phase = 0.0
		return
	if speed > 0.4:
		_walk_phase += delta * (speed * WALK_FREQUENCY * TAU)
		var swing: float = sin(_walk_phase) * deg_to_rad(WALK_SWING_DEG)
		# Arms and legs cross-stride: right arm forward when left leg forward
		if not skip_right_arm:
			arm_r.rotation.x = swing
		arm_l.rotation.x = -swing
		leg_r.rotation.x = -swing
		leg_l.rotation.x = swing
	else:
		var t: float = clampf(delta * RETURN_TO_REST_RATE, 0.0, 1.0)
		if not skip_right_arm:
			arm_r.rotation.x = lerpf(arm_r.rotation.x, 0.0, t)
		arm_l.rotation.x = lerpf(arm_l.rotation.x, 0.0, t)
		leg_r.rotation.x = lerpf(leg_r.rotation.x, 0.0, t)
		leg_l.rotation.x = lerpf(leg_l.rotation.x, 0.0, t)
		_walk_phase = 0.0


# Toggle the seated pose — both legs bent forward ~80° at the hip so
# the rider visibly sits in the boat / pig saddle / minecart instead of
# standing on top of it. Vanilla MC's ModelBiped.isRiding flag does the
# same thing (sets rotateAngleX = -PI/2 for legs, -PI/4 for body lean —
# we skip the body lean for now). Player.set_mount calls this.
func set_mounted_pose(enabled: bool) -> void:
	if _mounted_pose == enabled:
		return
	_mounted_pose = enabled
	if not is_inside_tree() or leg_l == null or leg_r == null:
		return
	if enabled:
		# Bend forward at the hip. PI/2 = 90° but vanilla uses slightly
		# less (~80°) to read as "knees up" rather than "legs straight
		# forward." Both legs together so the silhouette is the iconic
		# minecart/boat seated pose.
		var bend: float = deg_to_rad(80.0)
		leg_l.rotation.x = bend
		leg_r.rotation.x = bend
	else:
		leg_l.rotation.x = 0.0
		leg_r.rotation.x = 0.0


# Drives the right-arm chopping motion. Returns swing PROGRESS in [0, 1]
# (0 = rest, 1 = end of swing cycle) so the caller can derive the vanilla
# first-person item transform (translate + Y-axis wrist twist + X tilt).
# Mid-swing release lets the current cycle finish — matches vanilla.
func update_mining_swing(active: bool, delta: float) -> float:
	if active and not _swing_active_visual:
		_swing_progress = 0.0
		_swing_active_visual = true
	if _swing_active_visual:
		_swing_progress += delta / SWING_DURATION_SEC
		if _swing_progress >= 1.0:
			if active:
				_swing_progress = 0.0  # immediately start the next swing — continuous chop
			else:
				_swing_progress = 0.0
				_swing_active_visual = false
	# Third-person arm: simple forward swing peaking mid-cycle.
	arm_r.rotation.x = sin(_swing_progress * PI) * deg_to_rad(MINING_SWING_DEG)
	return _swing_progress


func is_mining_visually() -> bool:
	return _swing_active_visual


# One-shot arm swing for right-click item-use (bucket fill/place, hoe
# till, eat-a-food-item, etc.). Vanilla MC plays the same wind-up-and-
# swing animation the break path uses, but for a single cycle rather
# than looping — the arm arcs once and returns to rest. update_mining_swing
# handles the looping case; this entry point just seeds the cycle if it
# isn't already running.
func trigger_use_swing() -> void:
	if _swing_active_visual:
		return
	_swing_progress = 0.0
	_swing_active_visual = true


# Stacked layered flame sprites — port of Beta-era
# Render.renderEntityOnFire (matches Spoutcraft Render.java:44-89).
# Beta differs from Alpha 1.2.6 in five key ways: 5 dense layers
# instead of 3 (loop steps 0.45 in unscaled units, not 1.0); +Z
# offset toward camera (+0.03) instead of -0.04 away; alternating
# fire_layer_0.png + fire_layer_1.png textures; every other
# layer-pair flips U coords so adjacent layers don't clone. We use
# Beta because Alpha 1.2.6 had no third-person view (gq.java) — Beta
# 1.5+ is the first vanilla version where this render actually had
# to look right from outside the body.
#
# Pivot Node3D parents all layers + rotates around Y in _process to
# face the camera (matching `glRotatef(-playerViewY, 0, 1, 0)` Spout
# line 57). Pivot positioned at entity FEET (capsule center − 0.9),
# uniformly scaled by f7 = entity.width * 1.4 = 0.84 m.
func _build_fire_billboards() -> void:
	var strip0: Texture2D = load(_FIRE_STRIP_PATH_0) as Texture2D
	var strip1: Texture2D = load(_FIRE_STRIP_PATH_1) as Texture2D
	if strip0 == null:
		return
	if strip1 == null:
		strip1 = strip0  # graceful fallback
	_fire_pivot = Node3D.new()
	_fire_pivot.visible = false
	_fire_pivot.position = Vector3(0, -0.9, 0)
	_fire_pivot.scale = Vector3.ONE * 0.84
	add_child(_fire_pivot)
	# Beta loop: while (var15 > 0) { ...; var15 -= 0.45; var16 -= 0.45;
	# var13 *= 0.9; var17 += 0.03; ++var18 }. var15 starts at
	# entity.height/var11 = 1.8/0.84 = 2.143 → loop runs 5 times
	# (2.143, 1.693, 1.243, 0.793, 0.343, then -0.107 stops).
	const _LAYER_COUNT: int = 5
	const _LAYER_HEIGHT: float = 1.4
	const _LAYER_SHRINK: float = 0.9
	const _LAYER_Y_STEP: float = 0.45
	const _LAYER_Z_STEP: float = 0.03  # +Z toward camera in Beta
	const _STACK_Z_INIT: float = -0.26  # -0.3 + (int)2.143 * 0.02
	var x_scale: float = 1.0
	# var16 in Beta starts at 0 (posY - boundingBox.minY = 0 for
	# standard entities) and decreases by 0.45 per layer. Quad
	# vertices are at (±0.5*x_scale, [-var16, 1.4-var16], var17), so
	# the y-center of layer N is at (1.4 - var16)/2 - var16/2 + var16
	# = 0.7 - var16. With var16 = -0.45*N, y_center = 0.7 + 0.45*N.
	for i: int in range(_LAYER_COUNT):
		var s := Sprite3D.new()
		# Alternate fire_layer_0 / fire_layer_1 like Spoutcraft line 64.
		s.texture = strip0 if (i % 2 == 0) else strip1
		s.hframes = 1
		s.vframes = _FIRE_STRIP_FRAMES
		s.frame = 0
		s.pixel_size = 1.0 / 16.0
		# Spoutcraft line 70-74: every other layer-PAIR flips U coords.
		# We approximate by negating scale.x on those layers, which
		# horizontally mirrors the sprite (keeps width magnitude correct).
		var x_sign: float = -1.0 if (i / 2) % 2 == 0 else 1.0
		s.scale = Vector3(x_scale * x_sign, _LAYER_HEIGHT, 1.0)
		s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		s.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		s.shaded = false
		s.transparent = true
		s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
		s.double_sided = true
		s.render_priority = 5 + i
		var y_center: float = 0.7 + _LAYER_Y_STEP * float(i)
		var z_pos: float = _STACK_Z_INIT + _LAYER_Z_STEP * float(i)
		s.position = Vector3(0, y_center, z_pos)
		_fire_pivot.add_child(s)
		_fire_sprites.append(s)
		x_scale *= _LAYER_SHRINK


func set_on_fire(on: bool) -> void:
	if on == _fire_visible:
		return
	_fire_visible = on
	if _fire_pivot != null:
		_fire_pivot.visible = on


func _process(delta: float) -> void:
	_update_world_brightness()
	if not _fire_visible or _fire_pivot == null or _fire_sprites.is_empty():
		return
	# Rotate the pivot around Y so the stack always faces the active
	# camera — matches vanilla aq.java:47's `glRotatef(-b.i, 0, 1, 0)`
	# where b.i is EntityRenderer.prevYaw. Computed in world space to
	# handle the character_model's own yaw correctly.
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam != null:
		var cam_pos: Vector3 = cam.global_position
		var pivot_pos: Vector3 = _fire_pivot.global_position
		var to_cam: Vector3 = cam_pos - pivot_pos
		# Only the horizontal component matters — we rotate around Y.
		to_cam.y = 0.0
		if to_cam.length_squared() > 0.0001:
			var yaw: float = atan2(to_cam.x, to_cam.z)
			# Undo any inherited yaw from character_model so the fire
			# faces world-space camera direction.
			var parent_yaw: float = (self as Node3D).global_rotation.y
			_fire_pivot.rotation.y = yaw - parent_yaw
	_fire_anim_time += delta * _FIRE_ANIM_FPS
	var base_frame: int = int(_fire_anim_time) % _FIRE_STRIP_FRAMES
	for s: Sprite3D in _fire_sprites:
		s.frame = base_frame


# Builds a standalone right-arm MeshInstance3D using the same skin and UV
# mapping. Used by the player to render the first-person hand attached to
# the camera. Overrides the material with a no-depth-test variant so the
# hand always draws on top of world geometry — vanilla MC behavior;
# without this the hand visibly clips into nearby blocks.
func build_fp_arm() -> MeshInstance3D:
	if _skin_mat == null:
		_skin_mat = _build_skin_material()
	var arm: MeshInstance3D = _build_textured_box(FP_ARM_SIZE, _FP_ARM_R_UVS, true)
	# Use the body skin texture so the hand picks up whatever skin tone +
	# pixel detail the loaded skin defines. UNSHADED + no_depth_test so the
	# arm draws on top of world geometry like vanilla MC's FP arm.
	var fp_mat: StandardMaterial3D = _skin_mat.duplicate() as StandardMaterial3D
	fp_mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	fp_mat.no_depth_test = true
	fp_mat.render_priority = 100
	arm.material_override = fp_mat
	return arm


func _build_skin_material() -> StandardMaterial3D:
	var pack: String = BlockAtlas.active_pack
	var path: String = "res://assets/textures/entities/packs/%s/steve.png" % pack
	var tex: Texture2D = load(path) as Texture2D
	if tex == null:
		# Pack has no steve override — use pixel_perfection's skin.
		path = "res://assets/textures/entities/packs/%s/steve.png" % SKIN_FALLBACK_PACK
		tex = load(path) as Texture2D
	if tex == null:
		push_error("[CharacterModel] failed to load skin: " + path)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = StandardMaterial3D.TEXTURE_FILTER_NEAREST
	# UNSHADED so the model renders at the same brightness as surrounding
	# terrain (chunk.gdshader is also unshaded — both bake their lighting
	# directly). Vanilla EntityRenderer.setBrightness sampled the world's
	# cell light at the entity position and multiplied it into the vertex
	# color; PER_VERTEX shading made the TP body dim to ambient (0.45) on
	# all shadow-side faces and to near-black at night, while the world
	# kept its full LUT brightness — read as "player is in a different
	# light environment than the world". `_process` below now samples
	# the chunk light at the model's position each frame and applies the
	# vanilla brightness LUT to albedo_color, so the model matches.
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = StandardMaterial3D.CULL_BACK
	mat.transparency = StandardMaterial3D.TRANSPARENCY_DISABLED
	return mat


func _build_parts() -> void:
	# Capsule center is at this Node3D's origin (y=0). Capsule extends -0.9..+0.9.
	# Vertical layout: feet @ -0.9, leg/body junction @ -0.15, body top @ 0.6, head top @ 1.1.
	head = _build_textured_box(Vector3(0.5, 0.5, 0.5), _HEAD_UVS)
	head.position = Vector3(0, 0.85, 0)
	add_child(head)

	body = _build_textured_box(Vector3(0.5, 0.75, 0.25), _BODY_UVS)
	body.position = Vector3(0, 0.225, 0)
	add_child(body)

	arm_l = _make_skinned_limb(Vector3(-0.375, 0.6, 0), ARM_SIZE, _ARM_L_UVS)
	arm_l.name = "ArmL"
	add_child(arm_l)
	arm_r = _make_skinned_limb(Vector3(0.375, 0.6, 0), ARM_SIZE, _ARM_R_UVS)
	arm_r.name = "ArmR"
	add_child(arm_r)

	leg_l = _make_skinned_limb(Vector3(-0.125, -0.15, 0), LEG_SIZE, _LEG_L_UVS)
	leg_l.name = "LegL"
	add_child(leg_l)
	leg_r = _make_skinned_limb(Vector3(0.125, -0.15, 0), LEG_SIZE, _LEG_R_UVS)
	leg_r.name = "LegR"
	add_child(leg_r)

	_build_armor_overlays()


# Build hidden armor overlay boxes as children of each body part so they
# inherit walk / swing rotations automatically. Kept hidden until
# update_armor() is called with a non-empty stack in the relevant slot.
func _build_armor_overlays() -> void:
	_armor_head = _build_armor_box(head, Vector3(0.5, 0.5, 0.5), Vector3.ZERO, _ARMOR_HEAD_UVS)
	_armor_body = _build_armor_box(body, Vector3(0.5, 0.75, 0.25), Vector3.ZERO, _ARMOR_BODY_UVS)
	# Arm overlays parent to the same anchor node the skinned arm hangs
	# from, positioned at the arm's center (same -size.y/2 offset).
	var arm_offset: Vector3 = Vector3(0, -ARM_SIZE.y * 0.5, 0)
	_armor_arm_l = _build_armor_box(arm_l, ARM_SIZE, arm_offset, _ARMOR_ARM_UVS)
	_armor_arm_r = _build_armor_box(arm_r, ARM_SIZE, arm_offset, _ARMOR_ARM_UVS)
	# Leggings cover the UPPER half of each leg; boots the LOWER half.
	var leg_upper_size: Vector3 = Vector3(LEG_SIZE.x, LEG_SIZE.y * 0.5, LEG_SIZE.z)
	var leg_lower_size: Vector3 = Vector3(LEG_SIZE.x, LEG_SIZE.y * 0.5, LEG_SIZE.z)
	var leg_upper_offset: Vector3 = Vector3(0, -LEG_SIZE.y * 0.25, 0)
	var leg_lower_offset: Vector3 = Vector3(0, -LEG_SIZE.y * 0.75, 0)
	_armor_leg_l_upper = _build_armor_box(leg_l, leg_upper_size, leg_upper_offset, _ARMOR_LEG_UVS)
	_armor_leg_r_upper = _build_armor_box(leg_r, leg_upper_size, leg_upper_offset, _ARMOR_LEG_UVS)
	_armor_leg_l_lower = _build_armor_box(leg_l, leg_lower_size, leg_lower_offset, _ARMOR_LEG_UVS)
	_armor_leg_r_lower = _build_armor_box(leg_r, leg_lower_size, leg_lower_offset, _ARMOR_LEG_UVS)


# Creates one armor-overlay MeshInstance3D: box sized `size` + ARMOR_INFLATION
# on each axis, positioned `offset` relative to its parent, UV-mapped with
# `uvs`, and starts hidden. Visibility and material are swapped by
# update_armor() as the player equips / unequips each slot.
func _build_armor_box(
	parent: Node3D, size: Vector3, offset: Vector3, uvs: Array[Rect2]
) -> MeshInstance3D:
	var inflated: Vector3 = Vector3(
		size.x + ARMOR_INFLATION, size.y + ARMOR_INFLATION, size.z + ARMOR_INFLATION
	)
	var mi := _build_textured_box(inflated, uvs)
	mi.position = offset
	mi.visible = false
	parent.add_child(mi)
	return mi


# Tier → layer texture path. Keys are the armor-item IDs we registered in
# Items; values are the loaded/cached materials that render them.
func _armor_material_for(item_id: int) -> StandardMaterial3D:
	var path: String = _armor_texture_path_for(item_id)
	if path == "":
		return null
	if _armor_mat_cache.has(path):
		return _armor_mat_cache[path]
	var tex: Texture2D = load(path) as Texture2D
	if tex == null:
		return null
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = StandardMaterial3D.TEXTURE_FILTER_NEAREST
	# Match the skin material — UNSHADED + world-light modulation in
	# _process below, otherwise the armor stays at scene-ambient
	# brightness while the body underneath gets brightened to match the
	# terrain, producing a "lit body in dark armor" mismatch.
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = StandardMaterial3D.CULL_BACK
	# Alpha-cutoff so transparent pixels in the armor texture show the
	# body skin behind them (forearms, face, etc. aren't armored).
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	_armor_mat_cache[path] = mat
	return mat


func _armor_texture_path_for(item_id: int) -> String:
	# Helmet / chestplate / boots use layer_1; leggings use layer_2.
	# Tier determined by item-id range.
	var layer: int = 2 if _is_leggings(item_id) else 1
	var tier: String = _armor_tier_name(item_id)
	if tier == "":
		return ""
	return "%s%s_layer_%d.png" % [ARMOR_BASE_PATH, tier, layer]


func _armor_tier_name(item_id: int) -> String:
	if item_id >= Items.IRON_HELMET and item_id <= Items.IRON_BOOTS:
		return "iron"
	if item_id >= Items.GOLD_HELMET and item_id <= Items.GOLD_BOOTS:
		return "gold"
	if item_id >= Items.DIAMOND_HELMET and item_id <= Items.DIAMOND_BOOTS:
		return "diamond"
	if item_id >= Items.LEATHER_HELMET and item_id <= Items.LEATHER_BOOTS:
		# Vanilla Alpha named the texture "cloth" (the armor was originally
		# "Studded Leather"); we keep our existing "leather_" naming for
		# consistency with the item IDs / sprites. cloth_1.png / cloth_2.png
		# from the Alpha 1.2.6 jar are renamed to leather_layer_{1,2}.png
		# in assets/textures/entities/armor/ at extraction time.
		return "leather"
	return ""


func _is_leggings(item_id: int) -> bool:
	return (
		item_id == Items.IRON_LEGGINGS
		or item_id == Items.GOLD_LEGGINGS
		or item_id == Items.DIAMOND_LEGGINGS
		or item_id == Items.LEATHER_LEGGINGS
	)


# Public entry point — called from player.gd whenever the armor slots
# change. Each argument is the item_id in that slot (or Blocks.AIR if
# unequipped). Hides the overlay for empty slots; swaps material for
# equipped pieces.
func update_armor(helmet_id: int, chest_id: int, legs_id: int, feet_id: int) -> void:
	_apply_armor_piece(_armor_head, helmet_id)
	_apply_armor_piece(_armor_body, chest_id)
	_apply_armor_piece(_armor_arm_l, chest_id)
	_apply_armor_piece(_armor_arm_r, chest_id)
	_apply_armor_piece(_armor_leg_l_upper, legs_id)
	_apply_armor_piece(_armor_leg_r_upper, legs_id)
	_apply_armor_piece(_armor_leg_l_lower, feet_id)
	_apply_armor_piece(_armor_leg_r_lower, feet_id)


func _apply_armor_piece(overlay: MeshInstance3D, item_id: int) -> void:
	if overlay == null:
		return
	if item_id == Blocks.AIR:
		overlay.visible = false
		return
	var mat: StandardMaterial3D = _armor_material_for(item_id)
	if mat == null:
		overlay.visible = false
		return
	overlay.material_override = mat
	overlay.visible = true


func _make_skinned_limb(joint_pos: Vector3, size: Vector3, uvs: Array[Rect2]) -> Node3D:
	var anchor := Node3D.new()
	anchor.position = joint_pos
	var limb := _build_textured_box(size, uvs)
	limb.position = Vector3(0, -size.y * 0.5, 0)  # hangs down from joint
	anchor.add_child(limb)
	return anchor


# 6-face textured box with per-face UV rects sampling from the skin atlas.
# Same winding convention as our chunk mesher (CW front for Godot cull_back).
func _build_textured_box(
	size: Vector3, uv_rects: Array[Rect2], flip_v_sides: bool = false
) -> MeshInstance3D:
	var hx: float = size.x * 0.5
	var hy: float = size.y * 0.5
	var hz: float = size.z * 0.5
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var faces: Array = [
		# +Y top
		[
			Vector3(-hx, hy, -hz),
			Vector3(-hx, hy, hz),
			Vector3(hx, hy, hz),
			Vector3(hx, hy, -hz),
			Vector3(0, 1, 0)
		],
		# -Y bottom
		[
			Vector3(-hx, -hy, hz),
			Vector3(-hx, -hy, -hz),
			Vector3(hx, -hy, -hz),
			Vector3(hx, -hy, hz),
			Vector3(0, -1, 0)
		],
		# +X right
		[
			Vector3(hx, -hy, -hz),
			Vector3(hx, hy, -hz),
			Vector3(hx, hy, hz),
			Vector3(hx, -hy, hz),
			Vector3(1, 0, 0)
		],
		# -X left
		[
			Vector3(-hx, -hy, hz),
			Vector3(-hx, hy, hz),
			Vector3(-hx, hy, -hz),
			Vector3(-hx, -hy, -hz),
			Vector3(-1, 0, 0)
		],
		# +Z back
		[
			Vector3(hx, -hy, hz),
			Vector3(hx, hy, hz),
			Vector3(-hx, hy, hz),
			Vector3(-hx, -hy, hz),
			Vector3(0, 0, 1)
		],
		# -Z front
		[
			Vector3(-hx, -hy, -hz),
			Vector3(-hx, hy, -hz),
			Vector3(hx, hy, -hz),
			Vector3(hx, -hy, -hz),
			Vector3(0, 0, -1)
		],
	]
	for face_idx: int in range(6):
		var face: Array = faces[face_idx]
		var rect: Rect2 = uv_rects[face_idx]
		var base: int = verts.size()
		for i: int in range(4):
			verts.append(face[i])
			norms.append(face[4])
		# Side faces (idx 2-5) get an optional V-flip so box-top lands on
		# the BOTTOM of the UV rect and vice versa. Top/bottom caps (0/1)
		# don't have a meaningful "vertical" axis on the box, so they're
		# never flipped.
		var flip: bool = flip_v_sides and face_idx >= 2
		var v_lo: float = rect.position.y + (0.0 if flip else rect.size.y)
		var v_hi: float = rect.position.y + (rect.size.y if flip else 0.0)
		uvs.append(Vector2(rect.position.x, v_lo))
		uvs.append(Vector2(rect.position.x, v_hi))
		uvs.append(Vector2(rect.position.x + rect.size.x, v_hi))
		uvs.append(Vector2(rect.position.x + rect.size.x, v_lo))
		indices.append_array(
			[base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array
		)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _skin_mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


# Vanilla EntityRenderer.setBrightness — entity colors are texture ×
# world.getBrightnessForRender(cell). We mirror that by sampling the
# chunk light at the model's center cell each frame and pushing it into
# the (UNSHADED) skin + armor materials as albedo_color. Same brightness
# LUT chunk.gdshader uses, so the model matches the surrounding terrain
# brightness (bright in daylight, dim in caves, dark at night).
func _update_world_brightness() -> void:
	if _chunk_manager_ref == null:
		return
	var cell := Vector3i(
		int(floor(global_position.x)),
		int(floor(global_position.y + 1.0)),  # sample at body-center, not feet
		int(floor(global_position.z))
	)
	# get_world_sky_light returns 15 for OOB / unloaded chunks; same for
	# block_light returning 0. Treat both as the daylight default.
	var sky: int = 15
	var block: int = 0
	if _chunk_manager_ref.has_method("get_world_sky_light"):
		sky = _chunk_manager_ref.get_world_sky_light(cell)
	if _chunk_manager_ref.has_method("get_world_block_light"):
		block = _chunk_manager_ref.get_world_block_light(cell)
	var sky_factor: float = WorldTime.sky_factor() if WorldTime != null else 1.0
	var light: float = maxf(float(sky) / 15.0 * sky_factor, float(block) / 15.0)
	# Vanilla brightness LUT (oz.java:22-28) — same constants the chunk
	# shader uses so terrain + entity brightness curves match.
	var f3: float = 1.0 - light
	var lit: float = (1.0 - f3) / (f3 * 3.0 + 1.0) * 0.95 + 0.05
	if absf(lit - _last_brightness) < 0.005:
		return  # imperceptible drift, skip the material write
	_last_brightness = lit
	var tint := Color(lit, lit, lit, 1.0)
	if _skin_mat != null:
		_skin_mat.albedo_color = tint
	for mat: StandardMaterial3D in _armor_mat_cache.values():
		mat.albedo_color = tint
