class_name InputActions
extends RefCounted

# Registers default keybindings via the InputMap API at runtime.
# Saved overrides under [controls] in user://settings.cfg are applied
# on top of the defaults in `apply_saved_overrides`.
#
# Rebinding (controls_menu.gd):
#   • `GAMEPLAY_ACTIONS` is the ordered list of (action_id, display_name)
#     rows the UI renders. Debug shortcuts are intentionally excluded —
#     they're not user-facing.
#   • `rebind_action(action, event)` clears any other action holding the
#     same key/button (vanilla-style "displaced action shows NONE"), then
#     swaps in the new event.

# Order matters — drives the row order in controls_menu.gd. Debug-only
# actions live in DEBUG_ACTIONS below and only render in the menu while
# Game.debug_enabled is true.
# Settings key suffix for the gamepad channel: [controls] stores the
# key/mouse override under "<action>" and the pad override under
# "<action>__pad" — two independent channels so rebinding one never
# clobbers the other on disk.
const PAD_SUFFIX: String = "__pad"

const GAMEPLAY_ACTIONS: Array = [
	["move_forward", "Walk Forward"],
	["move_back", "Walk Backward"],
	["move_left", "Strafe Left"],
	["move_right", "Strafe Right"],
	["jump", "Jump"],
	["sneak", "Sneak"],
	["dismount", "Dismount"],
	["fly_down", "Descend (Fly)"],
	["interact_break", "Break / Attack"],
	["interact_place", "Place / Use"],
	["drop_selected", "Drop Item"],
	["toggle_inventory", "Open Inventory"],
	["hotbar_prev", "Hotbar Previous"],
	["hotbar_next", "Hotbar Next"],
	["hotbar_1", "Hotbar Slot 1"],
	["hotbar_2", "Hotbar Slot 2"],
	["hotbar_3", "Hotbar Slot 3"],
	["hotbar_4", "Hotbar Slot 4"],
	["hotbar_5", "Hotbar Slot 5"],
	["hotbar_6", "Hotbar Slot 6"],
	["hotbar_7", "Hotbar Slot 7"],
	["hotbar_8", "Hotbar Slot 8"],
	["hotbar_9", "Hotbar Slot 9"],
	["toggle_perspective", "Toggle Perspective"],
	["toggle_creative", "Toggle Creative Mode"],
	["open_item_spawner", "Open Item Spawner"],
	["open_mob_spawner", "Open Mob Spawner"],
	["debug_toggle", "Toggle Debug Mode"],
	["pause", "Pause / Menu"],
]

# Debug-tool actions. Rebindable from the controls menu, but only
# rendered when Game.debug_enabled is on — most players never see them.
# Still considered for conflict detection on every rebind (so binding,
# say, "B" to "Drop Item" displaces debug_biome_scan and you don't get
# both actions firing on B).
const DEBUG_ACTIONS: Array = [
	["debug_stats_toggle", "Toggle Stats Panel"],
	["debug_stats_copy", "Copy Stats to Clipboard"],
	["debug_stats_scout", "Scout Caves / Lava"],
	["debug_stats_reset_perf", "Reset Perf Counters"],
	["debug_tool_tuner", "Open Tool Tuner"],
	["debug_lighting_view", "Cycle Light Heatmap"],
	["debug_biome_scan", "Dump Biome Map"],
	["debug_fast_day", "Toggle Fast Day Cycle"],
	["debug_find_dungeon", "Teleport to Nearest Dungeon"],
]


# Concatenated list — used by the rebind conflict scanner and by
# apply_saved_overrides so both sets get the same treatment.
# Gamepad layer — console-MC conventions layered on top of the keyboard
# defaults; pad and keyboard feed the same actions so they're always
# interchangeable. Left stick = analog movement through the exact
# actions Input.get_vector already consumes; triggers follow the
# console convention (RT mine/attack, LT place/use). Right-stick LOOK
# is polled in player.gd — continuous rotation isn't an InputMap shape.
# B doubles as sneak AND dismount (contextual, like Shift on keyboard).
static func _register_gamepad_defaults() -> void:
	_add_joy_axis("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_add_joy_axis("move_back", JOY_AXIS_LEFT_Y, 1.0)
	_add_joy_axis("move_left", JOY_AXIS_LEFT_X, -1.0)
	_add_joy_axis("move_right", JOY_AXIS_LEFT_X, 1.0)
	_add_joy_button("jump", JOY_BUTTON_A)
	_add_joy_button("sneak", JOY_BUTTON_B)
	_add_joy_button("dismount", JOY_BUTTON_B)
	_add_joy_button("fly_down", JOY_BUTTON_B)
	# Bedrock: X opens the crafting screen, Y the inventory — for us both
	# land on the same inventory-with-craft-grid screen, so X mirrors Y
	# rather than surprising Bedrock muscle memory with a different verb.
	_add_joy_button("toggle_inventory", JOY_BUTTON_Y)
	_add_joy_button("toggle_inventory", JOY_BUTTON_X)
	_add_joy_axis("interact_break", JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_add_joy_axis("interact_place", JOY_AXIS_TRIGGER_LEFT, 1.0)
	_add_joy_button("hotbar_prev", JOY_BUTTON_LEFT_SHOULDER)
	_add_joy_button("hotbar_next", JOY_BUTTON_RIGHT_SHOULDER)
	_add_joy_button("pause", JOY_BUTTON_START)
	# D-pad up/down = perspective/drop, matching Bedrock exactly. L3
	# (sprint) and R3 (fly-down-slow) stay unbound — Alpha has neither
	# mechanic, so their Bedrock functions don't exist here.
	_add_joy_button("toggle_perspective", JOY_BUTTON_DPAD_UP)
	_add_joy_button("drop_selected", JOY_BUTTON_DPAD_DOWN)


static func all_actions() -> Array:
	var combined: Array = []
	combined.append_array(GAMEPLAY_ACTIONS)
	combined.append_array(DEBUG_ACTIONS)
	return combined


static func register_defaults() -> void:
	_add_key("move_forward", KEY_W)
	_add_key("move_back", KEY_S)
	_add_key("move_left", KEY_A)
	_add_key("move_right", KEY_D)
	_add_key("jump", KEY_SPACE)
	_add_key("sneak", KEY_SHIFT)
	# Dismount — independent rebind from sneak so a player who wants
	# different keys for "crouch" and "leave my pig/boat/minecart" can
	# bind them separately. Defaults to Shift so the legacy single-
	# button experience is preserved for everyone who never visits the
	# controls menu. Boats and minecarts ALSO accept right-click as a
	# convenience dismount (see interaction.gd::_try_place).
	_add_key("dismount", KEY_SHIFT)
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
	# V is our primary perspective toggle (controls menu shows the first
	# event as the canonical binding, and V matches the README + macOS
	# users where F5 collides with Mission Control); F5 stays as an alt
	# to match vanilla MC's keybinding.
	_add_keys("toggle_perspective", [KEY_V, KEY_F5])
	# Creative-mode toggle. User-facing now (no longer debug-gated) — a
	# player can flip into creative without flipping on debug first. G is
	# primary because F1 is a media key on Mac by default.
	_add_keys("toggle_creative", [KEY_G, KEY_F1])
	# Item spawner UI — quantity selector + grid of every block & item.
	# Available when creative OR debug is on (see _unhandled_input gating
	# in debug_item_spawner.gd).
	_add_key("open_item_spawner", KEY_F4)
	# Mob spawner UI — grid of registered mobs + click-to-place a
	# MOB_SPAWNER cage block in front of the player. Same creative-or-
	# debug gating as the item spawner.
	_add_key("open_mob_spawner", KEY_F6)
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
	# B = biome / surface scan. Dumps a 32×32 ASCII biome map + per-chunk
	# top-block composition for the chunks around the player to the console
	# stdout. Useful for diagnosing biome boundaries and scatter density
	# (e.g. 'why is there snow in this forest?'). Console-output rather
	# than panel UI to keep the F3 readout uncluttered.
	_add_key("debug_biome_scan", KEY_B)
	# N = toggle fast day-night cycle (30 s vs vanilla 1200 s). Lets the
	# dev watch lighting through a full cycle without sitting around for
	# 20 minutes. Handled in day_night_driver.gd.
	_add_key("debug_fast_day", KEY_N)
	# F2 = teleport to the nearest dungeon spawner in any loaded chunk.
	# Debug-only — used to QA the dungeon worldgen pass without
	# spelunking through caves. F2 is unused on macOS by default
	# (unlike F9/F10/F11 which Mission Control eats).
	_add_key("debug_find_dungeon", KEY_F2)
	_register_gamepad_defaults()


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


static func _add_joy_button(action: StringName, button: JoyButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	# Idempotent like _add_key — register_defaults re-runs on Reset, and
	# unguarded appends would stack duplicate pad events each time.
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)


static func _add_joy_axis(action: StringName, axis: JoyAxis, value: float) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	if not InputMap.action_has_event(action, ev):
		InputMap.action_add_event(action, ev)


# --- Rebinding API (controls_menu.gd) ---


# Apply user-saved overrides on top of the defaults registered above.
# Called once from Game._ready after register_defaults(). The cfg's
# [controls] section maps action_id → encoded event (see _encode_event).
# Empty string = "user cleared this binding to NONE."
static func apply_saved_overrides(cfg: ConfigFile) -> void:
	for entry: Array in all_actions():
		var action: StringName = entry[0]
		if not InputMap.has_action(action):
			continue
		var encoded: String = cfg.get_value("controls", action, "__unset__")
		# Sentinel keeps un-touched actions on their default bindings —
		# get_value's own default isn't enough because we need to
		# distinguish "user cleared to NONE" from "never customized."
		if encoded != "__unset__":
			erase_key_mouse_events(action)
			var ev: InputEvent = _decode_event(encoded)
			if ev != null:
				InputMap.action_add_event(action, ev)
		# Pad channel — stored under "<action>__pad", applied with the
		# same unset-vs-cleared semantics as the key/mouse channel.
		var pad_encoded: String = cfg.get_value("controls", action + PAD_SUFFIX, "__unset__")
		if pad_encoded != "__unset__":
			erase_joypad_events(action)
			var pad_ev: InputEvent = _decode_event(pad_encoded)
			if pad_ev != null:
				InputMap.action_add_event(action, pad_ev)


# Vanilla-style rebind: any other action currently holding this key/button
# gets the event silently removed (so its label becomes "NONE" in the UI)
# before we add the new event to `action`. Returns the list of actions
# whose bindings were cleared as collateral, so the UI can refresh just
# those rows.
static func rebind_action(action: StringName, event: InputEvent) -> Array[StringName]:
	var displaced: Array[StringName] = []
	# Scan BOTH gameplay + debug lists so a new bind silently clears any
	# conflicting debug binding too (otherwise pressing B while debug is on
	# would fire both debug_biome_scan and the user's new B-binding).
	for entry: Array in all_actions():
		var other: StringName = entry[0]
		if other == action:
			continue
		if not InputMap.has_action(other):
			continue
		for existing: InputEvent in InputMap.action_get_events(other):
			if _events_match(existing, event):
				InputMap.action_erase_event(other, existing)
				if not displaced.has(other):
					displaced.append(other)
	# Replace the target action's events with just this one (we don't expose
	# secondary bindings in the UI; single-binding-per-action keeps the row
	# count manageable and matches vanilla MC).
	if is_pad_event(event):
		erase_joypad_events(action)
	else:
		erase_key_mouse_events(action)
	InputMap.action_add_event(action, event)
	return displaced


# ALL events on one channel of an action — baseline/cancel in the
# controls menu must restore multi-bound actions (V+F5 perspective,
# Ctrl/Cmd fly-down, X+Y inventory pad) faithfully, not just the first.
static func channel_events(action: StringName, pad: bool) -> Array[InputEvent]:
	var out: Array[InputEvent] = []
	if not InputMap.has_action(action):
		return out
	for ev: InputEvent in InputMap.action_get_events(action):
		if is_pad_event(ev) == pad:
			out.append(ev)
	return out


# First PAD event bound to `action` (the gamepad rows' label source),
# or null when the pad channel is unbound.
static func primary_pad_event(action: StringName) -> InputEvent:
	if not InputMap.has_action(action):
		return null
	for ev: InputEvent in InputMap.action_get_events(action):
		if is_pad_event(ev):
			return ev
	return null


# Return the first event bound to `action`, or null if none. The UI shows
# this in each row's button label.
static func primary_event(action: StringName) -> InputEvent:
	if not InputMap.has_action(action):
		return null
	var events: Array[InputEvent] = InputMap.action_get_events(action)
	if events.is_empty():
		return null
	return events[0]


# Human-readable label for any supported event. "NONE" for null/cleared.
static func event_display_name(event: InputEvent) -> String:
	if event == null:
		return "NONE"
	if event is InputEventKey:
		var kc: Key = (event as InputEventKey).physical_keycode
		var s: String = OS.get_keycode_string(kc)
		return s if s != "" else "Key %d" % kc
	if event is InputEventMouseButton:
		match (event as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT:
				return "Mouse Left"
			MOUSE_BUTTON_RIGHT:
				return "Mouse Right"
			MOUSE_BUTTON_MIDDLE:
				return "Mouse Middle"
			MOUSE_BUTTON_WHEEL_UP:
				return "Wheel Up"
			MOUSE_BUTTON_WHEEL_DOWN:
				return "Wheel Down"
			_:
				return "Mouse %d" % (event as InputEventMouseButton).button_index
	if event is InputEventJoypadButton:
		match (event as InputEventJoypadButton).button_index:
			JOY_BUTTON_A:
				return "A"
			JOY_BUTTON_B:
				return "B"
			JOY_BUTTON_X:
				return "X"
			JOY_BUTTON_Y:
				return "Y"
			JOY_BUTTON_LEFT_SHOULDER:
				return "LB"
			JOY_BUTTON_RIGHT_SHOULDER:
				return "RB"
			JOY_BUTTON_LEFT_STICK:
				return "L3"
			JOY_BUTTON_RIGHT_STICK:
				return "R3"
			JOY_BUTTON_START:
				return "Start"
			JOY_BUTTON_BACK:
				return "Select"
			JOY_BUTTON_DPAD_UP:
				return "D-Pad Up"
			JOY_BUTTON_DPAD_DOWN:
				return "D-Pad Down"
			JOY_BUTTON_DPAD_LEFT:
				return "D-Pad Left"
			JOY_BUTTON_DPAD_RIGHT:
				return "D-Pad Right"
			_:
				return "Pad %d" % (event as InputEventJoypadButton).button_index
	if event is InputEventJoypadMotion:
		match (event as InputEventJoypadMotion).axis:
			JOY_AXIS_TRIGGER_LEFT:
				return "LT"
			JOY_AXIS_TRIGGER_RIGHT:
				return "RT"
			_:
				return "Axis %d" % (event as InputEventJoypadMotion).axis
	return "?"


# Serialize an event for settings.cfg storage. Empty string = NONE.
# Format:
#   "K:<physical_keycode>"   — keyboard
#   "M:<button_index>"       — mouse
#   "J:<button_index>"       — gamepad button
#   "JA:<axis>"              — gamepad trigger axis (LT/RT)
#   ""                       — cleared / NONE
static func encode_event(event: InputEvent) -> String:
	if event == null:
		return ""
	if event is InputEventKey:
		return "K:%d" % int((event as InputEventKey).physical_keycode)
	if event is InputEventMouseButton:
		return "M:%d" % int((event as InputEventMouseButton).button_index)
	if event is InputEventJoypadButton:
		return "J:%d" % int((event as InputEventJoypadButton).button_index)
	if event is InputEventJoypadMotion:
		return "JA:%d" % int((event as InputEventJoypadMotion).axis)
	return ""


# Inverse of encode_event. Returns null for the empty / cleared form so
# callers can tell "user cleared this" apart from "malformed entry."
# Erase only keyboard/mouse events, preserving the gamepad layer. The
# rebind UI and saved overrides manage key/mouse bindings exclusively —
# without this, applying a saved rebind (or rebinding in the menu)
# stripped the pad defaults from that action.
# Mirror of erase_key_mouse_events for the pad channel: pad rebinds
# and pad overrides must never disturb keyboard/mouse bindings.
static func erase_joypad_events(action: StringName) -> void:
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
			InputMap.action_erase_event(action, ev)


static func is_pad_event(event: InputEvent) -> bool:
	return event is InputEventJoypadButton or event is InputEventJoypadMotion


static func erase_key_mouse_events(action: StringName) -> void:
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventKey or ev is InputEventMouseButton:
			InputMap.action_erase_event(action, ev)


static func _decode_event(encoded: String) -> InputEvent:
	if encoded == "":
		return null
	if encoded.begins_with("K:"):
		var ev := InputEventKey.new()
		ev.physical_keycode = int(encoded.substr(2))
		return ev
	if encoded.begins_with("M:"):
		var ev := InputEventMouseButton.new()
		ev.button_index = int(encoded.substr(2))
		return ev
	if encoded.begins_with("JA:"):
		var ev := InputEventJoypadMotion.new()
		ev.axis = int(encoded.substr(3)) as JoyAxis
		ev.axis_value = 1.0
		return ev
	if encoded.begins_with("J:"):
		var ev := InputEventJoypadButton.new()
		ev.button_index = int(encoded.substr(2)) as JoyButton
		return ev
	return null


# Compare two InputEvents on the dimensions the rebind UI cares about
# (key code or mouse button). Ignores modifier state, position, pressure,
# etc. — those aren't surfaced in the UI so we don't want them disrupting
# conflict detection.
static func _events_match(a: InputEvent, b: InputEvent) -> bool:
	if a == null or b == null:
		return false
	if a is InputEventKey and b is InputEventKey:
		return (a as InputEventKey).physical_keycode == (b as InputEventKey).physical_keycode
	if a is InputEventMouseButton and b is InputEventMouseButton:
		return (
			(a as InputEventMouseButton).button_index == (b as InputEventMouseButton).button_index
		)
	if a is InputEventJoypadButton and b is InputEventJoypadButton:
		return (
			(a as InputEventJoypadButton).button_index == (b as InputEventJoypadButton).button_index
		)
	if a is InputEventJoypadMotion and b is InputEventJoypadMotion:
		var ma := a as InputEventJoypadMotion
		var mb := b as InputEventJoypadMotion
		return ma.axis == mb.axis and signf(ma.axis_value) == signf(mb.axis_value)
	return false
