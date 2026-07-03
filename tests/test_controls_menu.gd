extends GutTest

# Drives the real ControlsMenu scene through the rebind capture path —
# arm a row, feed key/pad events into _input, assert the InputMap and
# the cancel/restore contract. Guards the capture refactor (key/mouse/
# pad routing) that screenshots can't verify without physical hardware.

var _menu: Control = null


func before_each() -> void:
	# Full per-test reset of the actions we touch: register_defaults skips
	# EXISTING actions on the key channel (restore-missing, not reset), so
	# leftover rebinds from earlier tests would leak through it.
	for a: String in ["jump", "move_left", "toggle_perspective", "toggle_inventory"]:
		if InputMap.has_action(a):
			InputMap.erase_action(a)
	InputActions.register_defaults()
	var packed: PackedScene = load("res://scenes/ui/controls_menu.tscn")
	_menu = packed.instantiate()
	add_child_autofree(_menu)


func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.pressed = true
	return ev


func _pad(button: JoyButton) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	ev.pressed = true
	return ev


func _action_has_key(action: StringName, code: Key) -> bool:
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventKey and (ev as InputEventKey).physical_keycode == code:
			return true
	return false


func _action_has_pad(action: StringName, button: JoyButton) -> bool:
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton and (ev as InputEventJoypadButton).button_index == button:
			return true
	return false


func test_keyboard_capture_rebinds_and_displaces() -> void:
	var btn: Button = _menu._rows.get(&"jump")
	assert_not_null(btn)
	_menu._on_rebind_pressed(&"jump", btn, false)
	_menu._input(_key(KEY_M))
	assert_true(_action_has_key("jump", KEY_M), "jump should now be M")
	assert_false(_action_has_key("jump", KEY_SPACE), "old key replaced")
	assert_true(_action_has_pad("jump", JOY_BUTTON_A), "pad binding untouched by key rebind")
	# Rebind jump to A — strafe-left's key should displace to NONE.
	_menu._on_rebind_pressed(&"jump", btn, false)
	_menu._input(_key(KEY_A))
	assert_true(_action_has_key("jump", KEY_A))
	assert_false(_action_has_key("move_left", KEY_A), "conflicting key displaced")


func test_pad_capture_rebinds_and_keeps_keyboard() -> void:
	var btn: Button = _menu._rows.get(&"jump")
	_menu._on_rebind_pressed(&"jump", btn, true)
	# Keyboard presses (other than Esc) must NOT commit while a pad row listens.
	_menu._input(_key(KEY_M))
	assert_false(_action_has_key("jump", KEY_M), "keys ignored during pad listen")
	_menu._input(_pad(JOY_BUTTON_DPAD_LEFT))
	assert_true(_action_has_pad("jump", JOY_BUTTON_DPAD_LEFT), "pad button captured")
	assert_false(_action_has_pad("jump", JOY_BUTTON_A), "old pad binding replaced")
	assert_true(_action_has_key("jump", KEY_SPACE), "keyboard binding untouched")


func test_trigger_capture_and_stick_immunity() -> void:
	var btn: Button = _menu._rows.get(&"jump")
	_menu._on_rebind_pressed(&"jump", btn, true)
	# Stick motion must never capture.
	var stick := InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_LEFT_X
	stick.axis_value = 1.0
	_menu._input(stick)
	var still_listening: bool = _menu._listening_action == &"jump"
	assert_true(still_listening, "stick motion must not commit")
	var trigger := InputEventJoypadMotion.new()
	trigger.axis = JOY_AXIS_TRIGGER_RIGHT
	trigger.axis_value = 1.0
	_menu._input(trigger)
	var has_rt: bool = false
	for ev: InputEvent in InputMap.action_get_events("jump"):
		if ev is InputEventJoypadMotion:
			has_rt = (ev as InputEventJoypadMotion).axis == JOY_AXIS_TRIGGER_RIGHT
	assert_true(has_rt, "trigger captured for pad row")


func test_cancel_restores_multibind_channels() -> void:
	var btn: Button = _menu._rows.get(&"toggle_perspective")
	assert_not_null(btn)
	_menu._on_rebind_pressed(&"toggle_perspective", btn, false)
	_menu._input(_key(KEY_P))
	assert_false(_action_has_key("toggle_perspective", KEY_V))
	_menu._on_cancel_pressed()
	assert_true(_action_has_key("toggle_perspective", KEY_V), "V restored on cancel")
	assert_true(_action_has_key("toggle_perspective", KEY_F5), "F5 secondary restored on cancel")
	assert_true(
		_action_has_pad("toggle_inventory", JOY_BUTTON_X), "X+Y pad multibind survives cancel"
	)
