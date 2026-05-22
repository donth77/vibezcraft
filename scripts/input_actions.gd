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
const GAMEPLAY_ACTIONS: Array = [
	["move_forward", "Walk Forward"],
	["move_back", "Walk Backward"],
	["move_left", "Strafe Left"],
	["move_right", "Strafe Right"],
	["jump", "Jump"],
	["sneak", "Sneak"],
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
]


# Concatenated list — used by the rebind conflict scanner and by
# apply_saved_overrides so both sets get the same treatment.
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
		if encoded == "__unset__":
			continue
		InputMap.action_erase_events(action)
		var ev: InputEvent = _decode_event(encoded)
		if ev != null:
			InputMap.action_add_event(action, ev)


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
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, event)
	return displaced


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
	return "?"


# Serialize an event for settings.cfg storage. Empty string = NONE.
# Format:
#   "K:<physical_keycode>"   — keyboard
#   "M:<button_index>"       — mouse
#   ""                       — cleared / NONE
static func encode_event(event: InputEvent) -> String:
	if event == null:
		return ""
	if event is InputEventKey:
		return "K:%d" % int((event as InputEventKey).physical_keycode)
	if event is InputEventMouseButton:
		return "M:%d" % int((event as InputEventMouseButton).button_index)
	return ""


# Inverse of encode_event. Returns null for the empty / cleared form so
# callers can tell "user cleared this" apart from "malformed entry."
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
	return false
