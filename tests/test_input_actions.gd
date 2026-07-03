extends GutTest

# Guards the gamepad binding layer: pad events must exist on the core
# actions AND survive saved keyboard overrides + menu rebinds — both of
# those paths historically erased ALL events for an action, which would
# silently strip controller support for anyone with a saved rebind.


func before_each() -> void:
	# Idempotent enough for these assertions: duplicate events from
	# repeated registration don't matter, presence does.
	InputActions.register_defaults()


func _has_joy_event(action: StringName) -> bool:
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
			return true
	return false


func test_core_actions_have_gamepad_bindings() -> void:
	var actions: Array = [
		"move_forward",
		"move_back",
		"move_left",
		"move_right",
		"jump",
		"sneak",
		"interact_break",
		"interact_place",
		"hotbar_prev",
		"hotbar_next",
		"toggle_inventory",
		"drop_selected",
		"pause",
		"toggle_perspective",
	]
	for action: String in actions:
		assert_true(_has_joy_event(action), "%s should have a gamepad binding" % action)


func test_movement_axes_are_analog() -> void:
	# Left stick must reach the same actions Input.get_vector consumes.
	var found_axis: bool = false
	for ev: InputEvent in InputMap.action_get_events("move_forward"):
		if ev is InputEventJoypadMotion:
			found_axis = (ev as InputEventJoypadMotion).axis == JOY_AXIS_LEFT_Y
			if found_axis:
				break
	assert_true(found_axis, "move_forward should bind the left-stick Y axis")


func test_saved_override_preserves_gamepad_events() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("controls", "jump", "K:%d" % KEY_X)
	InputActions.apply_saved_overrides(cfg)
	assert_true(_has_joy_event("jump"), "keyboard override must not strip pad bindings")


func test_rebind_preserves_gamepad_events() -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_J
	InputActions.rebind_action("sneak", ev)
	assert_true(_has_joy_event("sneak"), "menu rebind must not strip pad bindings")


func test_pad_rebind_keeps_keyboard_binding() -> void:
	var jb := InputEventJoypadButton.new()
	jb.button_index = JOY_BUTTON_DPAD_LEFT
	InputActions.rebind_action("jump", jb)
	var has_key: bool = false
	for ev: InputEvent in InputMap.action_get_events("jump"):
		if ev is InputEventKey:
			has_key = true
	assert_true(has_key, "pad rebind must not strip the keyboard binding")
	assert_true(_has_joy_event("jump"))


func test_pad_rebind_displaces_only_pad_channel() -> void:
	# Bind jump's pad to B (sneak's default). Sneak must lose its PAD
	# binding but keep its keyboard binding.
	var jb := InputEventJoypadButton.new()
	jb.button_index = JOY_BUTTON_B
	InputActions.rebind_action("jump", jb)
	var sneak_has_b: bool = false
	var sneak_has_key: bool = false
	for ev: InputEvent in InputMap.action_get_events("sneak"):
		if (
			ev is InputEventJoypadButton
			and (ev as InputEventJoypadButton).button_index == JOY_BUTTON_B
		):
			sneak_has_b = true
		if ev is InputEventKey:
			sneak_has_key = true
	assert_false(sneak_has_b, "displaced pad binding should be removed")
	assert_true(sneak_has_key, "keyboard binding must survive a pad displacement")


func test_pad_encode_decode_roundtrip() -> void:
	var jb := InputEventJoypadButton.new()
	jb.button_index = JOY_BUTTON_DPAD_DOWN
	var decoded_btn: InputEvent = InputActions._decode_event(InputActions.encode_event(jb))
	assert_true(decoded_btn is InputEventJoypadButton)
	assert_eq((decoded_btn as InputEventJoypadButton).button_index, JOY_BUTTON_DPAD_DOWN)
	var jm := InputEventJoypadMotion.new()
	jm.axis = JOY_AXIS_TRIGGER_RIGHT
	jm.axis_value = 1.0
	var decoded_axis: InputEvent = InputActions._decode_event(InputActions.encode_event(jm))
	assert_true(decoded_axis is InputEventJoypadMotion)
	assert_eq((decoded_axis as InputEventJoypadMotion).axis, JOY_AXIS_TRIGGER_RIGHT)


func test_saved_pad_override_applies_and_keeps_keyboard() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("controls", "jump" + InputActions.PAD_SUFFIX, "J:%d" % JOY_BUTTON_DPAD_RIGHT)
	InputActions.apply_saved_overrides(cfg)
	var pad_ev: InputEvent = InputActions.primary_pad_event("jump")
	assert_true(pad_ev is InputEventJoypadButton)
	assert_eq((pad_ev as InputEventJoypadButton).button_index, JOY_BUTTON_DPAD_RIGHT)
	var has_key: bool = false
	for ev: InputEvent in InputMap.action_get_events("jump"):
		if ev is InputEventKey:
			has_key = true
	assert_true(has_key, "pad override must not strip the keyboard binding")


func test_reregistering_defaults_does_not_duplicate_pad_events() -> void:
	# Start from a clean pad channel — other tests rebind jump's pad and
	# register_defaults is additive by design (restores missing defaults,
	# never removes customs), so leftovers would inflate the count.
	InputActions.erase_joypad_events("jump")
	InputActions.register_defaults()
	InputActions.register_defaults()
	var jump_pad_count: int = 0
	for ev: InputEvent in InputMap.action_get_events("jump"):
		if ev is InputEventJoypadButton:
			jump_pad_count += 1
	assert_eq(jump_pad_count, 1, "re-running register_defaults must not stack pad events")


func test_channel_events_returns_full_multibind() -> void:
	# toggle_perspective keyboard channel: V + F5. Inventory pad channel:
	# Y + X. Cancel in the controls menu restores from these lists — a
	# primary-only snapshot silently dropped the secondaries.
	assert_eq(InputActions.channel_events("toggle_perspective", false).size(), 2)
	assert_eq(InputActions.channel_events("toggle_inventory", true).size(), 2)


func test_inventory_pad_primary_is_y() -> void:
	var ev: InputEvent = InputActions.primary_pad_event("toggle_inventory")
	assert_true(ev is InputEventJoypadButton)
	assert_eq((ev as InputEventJoypadButton).button_index, JOY_BUTTON_Y)
