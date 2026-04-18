class_name InputActions
extends RefCounted

# Registers the default keybindings via the InputMap API at runtime.
# Phase 7 will swap this for a settings-backed remapping system.


static func register_defaults() -> void:
	_add("move_forward", KEY_W)
	_add("move_back", KEY_S)
	_add("move_left", KEY_A)
	_add("move_right", KEY_D)
	_add("jump", KEY_SPACE)
	_add("sneak", KEY_SHIFT)
	_add("pause", KEY_ESCAPE)


static func _add(action: StringName, keycode: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	InputMap.action_add_event(action, event)
