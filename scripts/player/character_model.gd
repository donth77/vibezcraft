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
var _swing_active_visual: bool = false


func _ready() -> void:
	_skin_mat = _build_skin_material()
	_build_parts()


func update_walk_animation(speed: float, delta: float, skip_right_arm: bool = false) -> void:
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
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_PER_VERTEX
	mat.cull_mode = StandardMaterial3D.CULL_BACK
	mat.transparency = StandardMaterial3D.TRANSPARENCY_DISABLED
	mat.roughness = 0.95
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
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_PER_VERTEX
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
	return ""


func _is_leggings(item_id: int) -> bool:
	return (
		item_id == Items.IRON_LEGGINGS
		or item_id == Items.GOLD_LEGGINGS
		or item_id == Items.DIAMOND_LEGGINGS
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
