extends Node3D

# Blocky Steve player model textured with a 64x64 MC-format skin.
# Built programmatically so animation logic can grab limb anchors by name.
# Proportions: head 8x8x8, body 8x12x4, limbs 4x12x4 (in MC pixels = ÷16
# blocks). Total height ≈ 1.8 blocks = matches the player capsule.

const SKIN_PATH: String = "res://assets/textures/entities/packs/pixel_perfection/steve.png"

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

# FP arm UVs — the full right-arm region (same as _ARM_R_UVS). Passed to
# _build_textured_box with flip_v_sides=true so the clothing end of the
# texture lands on the BOTTOM of the box (hand-tip end of the FP arm) and
# the skin end lands on the TOP (wrist end). This is the mirror image of
# the natural mapping — we do it because the FP camera frames the arm
# such that the hand-tip end is toward the viewer and the shoulder is
# off-screen at the "top" of the mesh.
const _FP_ARM_R_UVS: Array[Rect2] = _ARM_R_UVS
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
	var tex: Texture2D = load(SKIN_PATH) as Texture2D
	if tex == null:
		push_error("[CharacterModel] failed to load skin: " + SKIN_PATH)
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
