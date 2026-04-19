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
	# Mouse wheel cycles through the hotbar — vanilla MC binding.
	_add_mouse("hotbar_prev", MOUSE_BUTTON_WHEEL_UP)
	_add_mouse("hotbar_next", MOUSE_BUTTON_WHEEL_DOWN)
	# Q drops one item; Ctrl/Cmd+Q drops the whole stack (modifier checked in code).
	_add_key("drop_selected", KEY_Q)
	# E toggles the inventory screen (vanilla MC binding).
	_add_key("toggle_inventory", KEY_E)
	for i in range(9):
		_add_key("hotbar_%d" % (i + 1), KEY_1 + i)
	# Backtick toggles the global debug mode; sub-shortcuts only work when on.
	_add_key("debug_toggle", KEY_QUOTELEFT)
	# F5 cycles 1st/3rd-person perspective (vanilla MC binding). V as alt
	# (in case the user remapped F5 elsewhere on macOS).
	_add_keys("toggle_perspective", [KEY_F5, KEY_V])
	# Debug toggles — F1/F2 are media keys on Mac by default; bind G/H as alts.
	_add_keys("debug_creative", [KEY_F1, KEY_G])
	_add_keys("debug_fill_hotbar", [KEY_F2, KEY_H])
	# J = drop one of every craftable tool into the inventory (debug only).
	_add_keys("debug_fill_tools", [KEY_F3, KEY_J])
	# T = open the FP held-tool tuner panel (debug only). Lets you drag
	# sliders for each rest-pose / swing axis at runtime.
	_add_key("debug_tool_tuner", KEY_T)


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
