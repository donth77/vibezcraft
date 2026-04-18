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

@export var sneak_toggle: bool = false  # false = hold to sneak, true = press to toggle

var inventory: Inventory
var creative_mode: bool = false

var _is_sneaking: bool = false

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	inventory = Inventory.new()
	var hotbar: Control = get_node_or_null("Crosshair/Hotbar")
	if hotbar != null:
		hotbar.bind(inventory)
	# Reflect any env-set debug mode in the HUD on first paint
	_update_debug_label()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_apply_mouse_motion(event)
		return
	if event.is_action_pressed("pause"):
		_toggle_mouse_capture()
		return
	if event.is_action_pressed("debug_toggle"):
		Game.debug_enabled = not Game.debug_enabled
		if not Game.debug_enabled:
			creative_mode = false  # leaving debug also clears creative
		_update_debug_label()
		return
	# Debug-only shortcuts: gated behind Game.debug_enabled
	if Game.debug_enabled:
		if event.is_action_pressed("debug_creative"):
			creative_mode = not creative_mode
			_update_debug_label()
			return
		if event.is_action_pressed("debug_fill_hotbar"):
			_debug_fill_hotbar()
			return
	for i in range(9):
		if event.is_action_pressed("hotbar_%d" % (i + 1)):
			inventory.select(i)
			return


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

	# Recover if we fall through the world
	if global_position.y < -20.0:
		global_position = Vector3(8, 100.0, 8)
		velocity = Vector3.ZERO


func _apply_mouse_motion(event: InputEventMouseMotion) -> void:
	rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
	_camera.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
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
