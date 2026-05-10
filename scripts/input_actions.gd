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
	# Creative-flight descend. Sneak also works (vanilla Java binding) but
	# Ctrl / Cmd feel more natural for a lot of players and don't collide
	# with the sneak toggle. Both bind to the same action.
	_add_keys("fly_down", [KEY_CTRL, KEY_META])
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
	# Debug toggles — F1 is a media key on Mac by default; bind G as alt.
	_add_keys("debug_creative", [KEY_F1, KEY_G])
	# F4 opens the debug item spawner UI (quantity + grid of every
	# implemented block & item). Replaces the old per-set hotkeys
	# (debug_fill_hotbar / _tools / _smelt) that were getting crowded.
	_add_key("debug_item_spawner", KEY_F4)
	# F3 toggles the debug stats panel; F12 copies its contents to clipboard.
	# These work independently of debug_toggle — the panel can show even when
	# full debug mode is off. Avoid F9/F10/F11 — those are Mission Control /
	# Show Desktop on macOS by default and get eaten before reaching Godot.
	_add_key("debug_stats_toggle", KEY_F3)
	_add_key("debug_stats_copy", KEY_F12)
	# F6 = manual trigger for the 3×3 cave/lava scout scan. Manual-only
	# (not auto-refreshed) so the 225K-get_block pass doesn't stack onto
	# dig-frame hitches.
	_add_key("debug_stats_scout", KEY_F6)
	# F7 = wipe the PerfProbe ring buffer so the next window of samples
	# isolates whatever the user is doing right now ("walk for 5 s, see
	# what spiked"). Without it, p95/max stay polluted by boot-time chunk
	# rush forever.
	_add_key("debug_stats_reset_perf", KEY_F7)
	# T = open the FP held-tool tuner panel (debug only). Lets you drag
	# sliders for each rest-pose / swing axis at runtime.
	_add_key("debug_tool_tuner", KEY_T)
	# F8 = cycle the chunk-shader light heatmap (off / sky_light / block_light /
	# combined). Used to diagnose lighting fill vs mesher packing — see
	# `chunk.gdshader` debug_view uniform.
	_add_key("debug_lighting_view", KEY_F8)
	# Hold R while flying in creative to boost speed — useful for surveying
	# distant biomes. Vanilla doesn't have this but our render distance
	# means biomes can sit hundreds of blocks apart.
	_add_key("creative_boost", KEY_R)


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
