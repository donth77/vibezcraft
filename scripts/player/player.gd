extends CharacterBody3D

const WALK_SPEED: float = 4.317
const SNEAK_SPEED: float = 1.295
const JUMP_VELOCITY: float = 8.0
const GRAVITY: float = -32.0
const MOUSE_SENSITIVITY: float = 0.002
const PITCH_LIMIT_DEG: float = 89.0

const _DEBUG_FILL_BLOCKS: Array = [
	Blocks.STONE,
	Blocks.COBBLESTONE,
	Blocks.DIRT,
	Blocks.GRASS,
	Blocks.SAND,
	Blocks.LOG,
	Blocks.PLANKS,
	Blocks.LEAVES,
	Blocks.BEDROCK,
]
const _CAM_FIRST_PERSON: Vector3 = Vector3(0, 0.7, 0)
const _CAM_THIRD_BACK: Vector3 = Vector3(0, 1.0, 3.5)
const _CAM_THIRD_FRONT: Vector3 = Vector3(0, 1.0, -3.5)

# Vanilla MC F5 cycles: first → third-back → third-front → first.
const PERSPECTIVE_FIRST: int = 0
const PERSPECTIVE_THIRD_BACK: int = 1
const PERSPECTIVE_THIRD_FRONT: int = 2
const PERSPECTIVE_COUNT: int = 3

# Vanilla MC first-person swing transform. The dominant motion is a Y-axis
# wrist twist (signed for our right-handed hand-on-the-right-of-screen pose),
# combined with three translation curves that peak at different times in the
# 0..1 swing cycle: X (toward screen center) peaks early, Z (forward) at mid,
# Y (slight up) peaks late. Reproduces the recognizable punch arc.
const _FP_SWING_TRANSLATE_SCALE: float = 0.5  # screen-space units
const _FP_SWING_Y_TWIST_DEG: float = -15.0  # subtle wrist hint; vanilla 70° over-rotates our pose
const _FP_SWING_X_TILT_DEG: float = -25.0  # tilt-down at peak — main rotation contribution

# Held-block rest pose in camera-local space — vanilla MC puts the cube in the
# lower-right of the view, tilted to show three faces.
const _HELD_BLOCK_POSITION: Vector3 = Vector3(0.5, -0.45, -0.65)
const _HELD_BLOCK_ROTATION: Vector3 = Vector3(-0.1745, -0.7854, 0.0)  # (-10°, -45°, 0°)
const _HELD_BLOCK_SIZE: float = 0.42

# Third-person held block — parented to the right arm so it swings with the
# mining animation. Position is at the wrist (arm hangs to y≈-0.75).
const _TP_HELD_BLOCK_POSITION: Vector3 = Vector3(0, -0.78, -0.18)
const _TP_HELD_BLOCK_ROTATION: Vector3 = Vector3(0, -0.4363, 0)  # (0°, -25°, 0°)
const _TP_HELD_BLOCK_SIZE: float = 0.30

@export var sneak_toggle: bool = false  # false = hold to sneak, true = press to toggle

var inventory: Inventory
var creative_mode: bool = false
var perspective: int = PERSPECTIVE_FIRST
var is_mining: bool = false  # set by Interaction; drives mining-swing animation

var _is_sneaking: bool = false
var _character_model: Node3D
var _fp_hand: Node3D  # first-person right hand attached to camera
var _fp_hand_base_position: Vector3 = Vector3.ZERO
var _fp_hand_base_rotation: Vector3 = Vector3.ZERO
var _held_block: MeshInstance3D  # FP cube shown in lieu of the hand when holding an item
var _held_block_tp: MeshInstance3D  # third-person cube parented to arm_r
var _held_block_id: int = 0  # 0 = AIR = nothing held; show the hand instead

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	inventory = Inventory.new()
	inventory.changed.connect(_update_held_item)
	var hotbar: Control = get_node_or_null("Crosshair/Hotbar")
	if hotbar != null:
		hotbar.bind(inventory)
	# Build the player character model (hidden in first person)
	var model_script: GDScript = load("res://scripts/player/character_model.gd")
	_character_model = model_script.new()
	add_child(_character_model)
	# First-person hand (visible only in 1st person; attached to camera so
	# it stays anchored in the lower-right corner of the view).
	_build_fp_hand()
	_update_held_item()  # set initial hand-vs-block visibility
	_apply_perspective()
	_update_debug_label()


func _build_fp_hand() -> void:
	if _character_model == null or not _character_model.has_method("build_fp_arm"):
		return
	_fp_hand = _character_model.build_fp_arm()
	_camera.add_child(_fp_hand)
	# Lower-right of view, angled inward and slightly forward — vanilla MC
	# first-person arm position.
	_fp_hand_base_position = Vector3(0.42, -0.55, -0.70)
	_fp_hand_base_rotation = Vector3(deg_to_rad(-25), deg_to_rad(20), deg_to_rad(8))
	_fp_hand.position = _fp_hand_base_position
	_fp_hand.rotation = _fp_hand_base_rotation


# Vanilla MC: when the selected hotbar slot has a block, show that block in
# the lower-right of the view instead of the bare hand. Rebuilt on demand
# whenever the held id changes; same swing/punch animation drives it.
func _update_held_item() -> void:
	if inventory == null:
		return
	var id: int = inventory.selected().item_id
	if id == _held_block_id:
		return
	_held_block_id = id
	if _held_block != null:
		_held_block.queue_free()
		_held_block = null
	if _held_block_tp != null:
		_held_block_tp.queue_free()
		_held_block_tp = null
	if id != Blocks.AIR:
		_held_block = MeshInstance3D.new()
		_held_block.mesh = BlockMesh.get_cube_mesh(id, _HELD_BLOCK_SIZE)
		_held_block.position = _HELD_BLOCK_POSITION
		_held_block.rotation = _HELD_BLOCK_ROTATION
		_camera.add_child(_held_block)
		# TP block lives under the right arm so it inherits walking + mining swings.
		var arm_r: Node3D = null
		if _character_model != null:
			arm_r = _character_model.get("arm_r") as Node3D
		if arm_r != null:
			_held_block_tp = MeshInstance3D.new()
			_held_block_tp.mesh = BlockMesh.get_cube_mesh(id, _TP_HELD_BLOCK_SIZE)
			_held_block_tp.position = _TP_HELD_BLOCK_POSITION
			_held_block_tp.rotation = _TP_HELD_BLOCK_ROTATION
			arm_r.add_child(_held_block_tp)
	_apply_held_visibility()


# Vanilla MC EntityRenderer.renderItemInFirstPerson swing curves, expressed
# in our screen-space units. progress in [0,1]; at 0 the prop sits at rest.
func _apply_fp_swing(node: Node3D, base_pos: Vector3, base_rot: Vector3, progress: float) -> void:
	if progress <= 0.0:
		node.position = base_pos
		node.rotation = base_rot
		return
	var s: float = progress
	var sq: float = sqrt(s)
	var sin_pi_sq: float = sin(PI * sq)  # peak at s=0.25 — early
	var sin_pi_s2: float = sin(PI * s * s)  # peak at s≈0.71 — late
	var sin_pi_s: float = sin(PI * s)  # peak at s=0.5 — mid
	# Previous (matched vanilla MC ratios more closely): (-0.40, 0.20, -0.20).
	# Current: trimmed forward extension so the punch reads as a small jab
	# rather than a big lunge. Restore the old triple if this feels too short.
	var offset := Vector3(
		-0.40 * sin_pi_sq,  # X: sweep toward screen center
		0.20 * sin_pi_s2,  # Y: slight upward arc near end of swing
		-0.12 * sin_pi_s,  # Z: forward extension at mid-swing
	)
	node.position = base_pos + offset * _FP_SWING_TRANSLATE_SCALE
	node.rotation = Vector3(
		base_rot.x + sin_pi_s2 * deg_to_rad(_FP_SWING_X_TILT_DEG),
		base_rot.y + sin_pi_sq * deg_to_rad(_FP_SWING_Y_TWIST_DEG),
		base_rot.z,
	)


func _apply_held_visibility() -> void:
	# First-person: show either the hand or the FP held block (never both).
	# Third-person: the TP held block on the body model is what others see.
	var first_person: bool = perspective == PERSPECTIVE_FIRST
	var holding: bool = _held_block_id != Blocks.AIR
	if _fp_hand != null:
		_fp_hand.visible = first_person and not holding
	if _held_block != null:
		_held_block.visible = first_person
	if _held_block_tp != null:
		_held_block_tp.visible = not first_person


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_apply_mouse_motion(event)
		return
	if event.is_action_pressed("pause"):
		_toggle_mouse_capture()
	elif event.is_action_pressed("debug_toggle"):
		Game.debug_enabled = not Game.debug_enabled
		if not Game.debug_enabled:
			creative_mode = false  # leaving debug also clears creative
		_update_debug_label()
	elif event.is_action_pressed("toggle_perspective"):
		perspective = (perspective + 1) % PERSPECTIVE_COUNT
		_apply_perspective()
	elif Game.debug_enabled and event.is_action_pressed("debug_creative"):
		creative_mode = not creative_mode
		_update_debug_label()
	elif Game.debug_enabled and event.is_action_pressed("debug_fill_hotbar"):
		_debug_fill_hotbar()
	elif event.is_action_pressed("drop_selected"):
		_drop_selected_item(_drop_modifier_held())
	else:
		_select_hotbar_from_event(event)


func _select_hotbar_from_event(event: InputEvent) -> void:
	for i in range(9):
		if event.is_action_pressed("hotbar_%d" % (i + 1)):
			inventory.select(i)
			return


func _drop_modifier_held() -> bool:
	# Vanilla MC: Ctrl+Q (Cmd+Q on Mac) drops the entire stack.
	return Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)


func _drop_selected_item(drop_stack: bool) -> void:
	var stack: ItemStack = inventory.selected()
	if stack.is_empty():
		return
	var dropped_id: int = stack.item_id
	var count: int = stack.count if drop_stack else 1
	if drop_stack:
		inventory.consume_selected_stack()
	else:
		inventory.consume_one_selected()
	var chunk_manager: Node = get_tree().root.get_node_or_null("Main/ChunkManager")
	if chunk_manager == null:
		return
	# Always spawn at the PLAYER's eye position — not the camera's. In third-
	# person the camera sits behind/in front of the player, so using its
	# position would launch items from empty space far from the avatar.
	var look_dir: Vector3 = _player_look_direction()
	var eye_pos: Vector3 = global_position + Vector3(0, _CAM_FIRST_PERSON.y, 0)
	var spawn_pos: Vector3 = eye_pos + look_dir * 0.4
	var velocity: Vector3 = look_dir * 3.5 + Vector3(0, 0.6, 0)
	for i in range(count):
		var item := DroppedItem.new()
		chunk_manager.add_child(item)
		item.global_position = spawn_pos
		item.setup(dropped_id, velocity, DroppedItem.PLAYER_DROP_DELAY_SEC)


# Player-facing direction with camera pitch folded in. Independent of which
# perspective is active (camera position varies by mode but the player's
# yaw + the camera's pitch always describe where they're looking).
func _player_look_direction() -> Vector3:
	var horiz: Vector3 = -transform.basis.z  # player body forward (yaw only)
	var pitch: float = _camera.rotation.x
	# Front mode inverts pitch in the input handler — undo that here so the
	# throw direction follows the player's view, not the camera's.
	if perspective == PERSPECTIVE_THIRD_FRONT:
		pitch = -pitch
	return horiz * cos(pitch) + Vector3(0, sin(pitch), 0)


func _debug_fill_hotbar() -> void:
	for i in range(min(_DEBUG_FILL_BLOCKS.size(), Inventory.HOTBAR_SIZE)):
		var stack: ItemStack = inventory.slots[i]
		stack.item_id = _DEBUG_FILL_BLOCKS[i]
		stack.count = ItemStack.MAX_SIZE
	inventory.changed.emit()


func _update_debug_label() -> void:
	var label: Label = get_node_or_null("Crosshair/DebugLabel") as Label
	if label == null:
		return
	if not Game.debug_enabled:
		label.text = ""
		return
	if creative_mode:
		label.text = "DEBUG | CREATIVE"
	else:
		label.text = "DEBUG"


func _apply_perspective() -> void:
	# Camera anchor + facing per perspective. In FRONT mode the camera sits
	# in front of the player and is rotated 180° around Y to look back at
	# them; mouse pitch is inverted in _apply_mouse_motion to compensate.
	match perspective:
		PERSPECTIVE_FIRST:
			_camera.position = _CAM_FIRST_PERSON
			_camera.rotation.y = 0.0
		PERSPECTIVE_THIRD_BACK:
			_camera.position = _CAM_THIRD_BACK
			_camera.rotation.y = 0.0
		PERSPECTIVE_THIRD_FRONT:
			_camera.position = _CAM_THIRD_FRONT
			_camera.rotation.y = PI
	var third: bool = perspective != PERSPECTIVE_FIRST
	if _character_model != null:
		# Hide the body model in first person (we'd be inside our own head)
		_character_model.visible = third
	# Hand vs held-block visibility is centralized — also gates on first-person.
	_apply_held_visibility()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y += GRAVITY * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
	_update_sneak()

	var input_dir: Vector2 = Input.get_vector(
		"move_left", "move_right", "move_forward", "move_back"
	)
	var direction: Vector3 = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	var speed: float = SNEAK_SPEED if _is_sneaking else WALK_SPEED

	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	move_and_slide()

	# Drive arm/leg animations: mining swing first (it owns the right arm while
	# active), then walking (which skips the right arm during the swing).
	if _character_model != null and _character_model.has_method("update_walk_animation"):
		var horiz_speed: float = Vector2(velocity.x, velocity.z).length()
		var progress: float = _character_model.update_mining_swing(is_mining, delta)
		var arm_locked: bool = _character_model.is_mining_visually()
		_character_model.update_walk_animation(horiz_speed, delta, arm_locked)
		# Drive the swing on whichever first-person prop is currently visible.
		if _fp_hand != null and _fp_hand.visible:
			_apply_fp_swing(_fp_hand, _fp_hand_base_position, _fp_hand_base_rotation, progress)
		if _held_block != null and _held_block.visible:
			_apply_fp_swing(_held_block, _HELD_BLOCK_POSITION, _HELD_BLOCK_ROTATION, progress)

	# Recover if we fall through the world
	if global_position.y < -20.0:
		global_position = Vector3(8, 100.0, 8)
		velocity = Vector3.ZERO


func _apply_mouse_motion(event: InputEventMouseMotion) -> void:
	rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
	# Front-mode camera sits at Y=PI; without inverting pitch, mouse-down would
	# tilt the view up. Flip the sign so up/down feels consistent across modes.
	var pitch_sign: float = -1.0 if perspective == PERSPECTIVE_THIRD_FRONT else 1.0
	_camera.rotate_x(pitch_sign * -event.relative.y * MOUSE_SENSITIVITY)
	var pitch_limit: float = deg_to_rad(PITCH_LIMIT_DEG)
	_camera.rotation.x = clamp(_camera.rotation.x, -pitch_limit, pitch_limit)


func _toggle_mouse_capture() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _update_sneak() -> void:
	if sneak_toggle:
		if Input.is_action_just_pressed("sneak"):
			_is_sneaking = not _is_sneaking
	else:
		_is_sneaking = Input.is_action_pressed("sneak")
