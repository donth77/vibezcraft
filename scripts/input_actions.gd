class_name InputActions
extends RefCounted

# Registers default keybindings via the InputMap API at runtime.
# Phase 7 will swap this for a settings-backed remapping system.


static func register_defaults() -> void:
	_add_key("move_forward", KEY_W)
	_add_key("move_back", KEY_S)
	_add_key("move_left", KEY_A)
	_add_key("move_right", KEY_D)
	_add_key("jump", KEY_SPACE)
	_add_key("sneak", KEY_SHIFT)
	_add_key("pause", KEY_ESCAPE)
	_add_mouse("interact_break", MOUSE_BUTTON_LEFT)
	_add_mouse("interact_place", MOUSE_BUTTON_RIGHT)
	for i in range(9):
		_add_key("hotbar_%d" % (i + 1), KEY_1 + i)
	# Backtick toggles the global debug mode; sub-shortcuts only work when on.
	_add_key("debug_toggle", KEY_QUOTELEFT)
	# Debug toggles — F1/F2 are media keys on Mac by default; bind G/H as alts.
	_add_keys("debug_creative", [KEY_F1, KEY_G])
	_add_keys("debug_fill_hotbar", [KEY_F2, KEY_H])


static func _add_key(action: StringName, keycode: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	InputMap.action_add_event(action, event)


static func _add_keys(action: StringName, keycodes: Array) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for kc: Key in keycodes:
		var event := InputEventKey.new()
		event.physical_keycode = kc
		InputMap.action_add_event(action, event)


static func _add_mouse(action: StringName, button: MouseButton) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var event := InputEventMouseButton.new()
	event.button_index = button
	InputMap.action_add_event(action, event)
