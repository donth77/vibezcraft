class_name ControlsMenu
extends Control

# Key-rebinding overlay. Mirrors vanilla Alpha's controls screen (one row
# per action, click-to-rebind, NONE label for cleared bindings) but with
# a scrollable column so all gameplay actions fit on one page.
#
# Opens as an overlay child — paused world or the main-menu dirt bg sits
# behind. Save persists overrides to user://settings.cfg [controls]; the
# next boot's InputActions.apply_saved_overrides replays them on top of
# the defaults registered by InputActions.register_defaults().
#
# Conflict rule (vanilla): rebinding a key that's already in use silently
# clears it from the other action. The displaced row gets a NONE label
# until the user picks a new key for it. No popup, no confirmation.

const _SETTINGS_PATH: String = "user://settings.cfg"
const _ROW_HEIGHT: int = 56
const _ROW_SEPARATION: int = 8

var _rows: Dictionary = {}  # action_id -> Button (the rebind button)
var _pending_events: Dictionary = {}  # action_id -> InputEvent | null (null = NONE)
var _listening_action: StringName = &""
var _listening_button: Button = null
# True until Save/Cancel decides what to do. Cancel reverts InputMap to
# whatever was loaded; Save persists the _pending_events map to disk.
var _baseline: Dictionary = {}  # action_id -> InputEvent | null (snapshot on open)


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_background()
	_build_panel()
	_snapshot_baseline()
	_refresh_all_rows()


func _build_background() -> void:
	# Same dim treatment as in_game_options so opening Controls from either
	# the main-menu Settings or the in-game pause Options reads as the same
	# layered modal style.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.65)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)


func _build_panel() -> void:
	var title := Label.new()
	title.text = "Controls"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.anchor_top = 0.04
	title.anchor_bottom = 0.04
	title.offset_bottom = 64
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_shadow_color", Color.BLACK)
	title.add_theme_constant_override("shadow_offset_x", 6)
	title.add_theme_constant_override("shadow_offset_y", 6)
	add_child(title)

	# Hint line — small, sits under the title so the user knows what to do.
	var hint := Label.new()
	hint.text = "Click a binding, then press a key or mouse button. Esc to cancel."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.anchor_left = 0.0
	hint.anchor_right = 1.0
	hint.anchor_top = 0.04
	hint.anchor_bottom = 0.04
	hint.offset_top = 84
	hint.offset_bottom = 84 + 28
	hint.add_theme_font_size_override("font_size", 22)
	hint.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	add_child(hint)

	# Scroll container holding the action rows. Tall enough to fit ~10 rows
	# without scrolling at 1080p; spills into scroll for the rest.
	var scroll := ScrollContainer.new()
	scroll.anchor_left = 0.5
	scroll.anchor_right = 0.5
	scroll.anchor_top = 0.18
	scroll.anchor_bottom = 0.84
	scroll.offset_left = -480
	scroll.offset_right = 480
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", _ROW_SEPARATION)
	scroll.add_child(vbox)

	for entry: Array in InputActions.GAMEPLAY_ACTIONS:
		var action: StringName = entry[0]
		var display: String = entry[1]
		_add_action_row(vbox, action, display)
	# Surface debug actions inline only when debug mode is currently on —
	# we don't want to confuse survival-mode players with rows for F3 / T /
	# F8 / etc. Once revealed, they're rebindable like any other row, and
	# the rebind scanner already considers them for conflict detection.
	if Game.debug_enabled:
		_add_section_header(vbox, "Debug")
		for entry: Array in InputActions.DEBUG_ACTIONS:
			var action: StringName = entry[0]
			var display: String = entry[1]
			_add_action_row(vbox, action, display)

	# Bottom button bar: Reset / Save / Cancel side-by-side.
	var button_row := HBoxContainer.new()
	button_row.anchor_left = 0.5
	button_row.anchor_right = 0.5
	button_row.anchor_top = 0.88
	button_row.anchor_bottom = 0.88
	button_row.offset_left = -480
	button_row.offset_right = 480
	button_row.offset_top = 0
	button_row.offset_bottom = 80
	button_row.add_theme_constant_override("separation", 16)
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(button_row)

	var reset_btn := VanillaButton.new()
	reset_btn.text = "Reset to Defaults"
	# Wider footprint (460) + smaller font (36 vs default 40) so the longer
	# label has visible padding around it. VanillaButton's stylebox has no
	# content_margin, so without these tweaks the text touches the border.
	reset_btn.custom_minimum_size = Vector2(460, 80)
	reset_btn.add_theme_font_size_override("font_size", 36)
	reset_btn.pressed.connect(_on_reset_pressed)
	button_row.add_child(reset_btn)

	var save_btn := VanillaButton.new()
	save_btn.text = "Save"
	save_btn.custom_minimum_size = Vector2(220, 80)
	save_btn.pressed.connect(_on_save_pressed)
	button_row.add_child(save_btn)

	var cancel_btn := VanillaButton.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(220, 80)
	cancel_btn.pressed.connect(_on_cancel_pressed)
	button_row.add_child(cancel_btn)


func _add_action_row(parent: VBoxContainer, action: StringName, display_name: String) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, _ROW_HEIGHT)
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = display_name
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_shadow_color", Color.BLACK)
	lbl.add_theme_constant_override("shadow_offset_x", 3)
	lbl.add_theme_constant_override("shadow_offset_y", 3)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(0, _ROW_HEIGHT)
	row.add_child(lbl)

	var btn := Button.new()
	btn.text = InputActions.event_display_name(InputActions.primary_event(action))
	btn.custom_minimum_size = Vector2(280, _ROW_HEIGHT)
	btn.add_theme_font_size_override("font_size", 26)
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 0.63))
	btn.add_theme_color_override("font_shadow_color", Color.BLACK)
	btn.add_theme_constant_override("shadow_offset_x", 3)
	btn.add_theme_constant_override("shadow_offset_y", 3)
	btn.add_theme_stylebox_override(
		"normal", _make_button_panel(Color(0x28 / 255.0, 0x28 / 255.0, 0x2C / 255.0))
	)
	btn.add_theme_stylebox_override(
		"hover", _make_button_panel(Color(0x4A / 255.0, 0x4C / 255.0, 0x58 / 255.0))
	)
	btn.add_theme_stylebox_override(
		"pressed", _make_button_panel(Color(0x4A / 255.0, 0x4C / 255.0, 0x58 / 255.0))
	)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.pressed.connect(_on_rebind_pressed.bind(action, btn))
	row.add_child(btn)
	_rows[action] = btn


# Lightweight divider label so the Debug rows read as a separate group
# from the gameplay rows above them. No interactivity — purely visual.
func _add_section_header(parent: VBoxContainer, text: String) -> void:
	var header := Label.new()
	header.text = text
	header.custom_minimum_size = Vector2(0, 40)
	header.add_theme_font_size_override("font_size", 24)
	header.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	header.add_theme_color_override("font_shadow_color", Color.BLACK)
	header.add_theme_constant_override("shadow_offset_x", 2)
	header.add_theme_constant_override("shadow_offset_y", 2)
	parent.add_child(header)


static func _make_button_panel(fill: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(0, 0, 0, 1.0)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


# --- Rebind capture ---


func _on_rebind_pressed(action: StringName, btn: Button) -> void:
	# Already listening for a different action? Cancel that one first so
	# we don't end up with two armed buttons + ambiguous _input routing.
	if _listening_action != &"":
		_cancel_listen()
	_listening_action = action
	_listening_button = btn
	btn.text = "> press a key <"
	SFX.play_click()


# _input runs BEFORE Godot's GUI processing, which is what we need to
# bind mouse buttons: clicks on Control nodes (the rebind buttons, the
# dim background) get consumed by the GUI and never reach _unhandled_input.
# With _input we see the press event first and accept_event() stops it
# from arming a different button. Outside listening mode we no-op so the
# rest of the UI behaves normally.
func _input(event: InputEvent) -> void:
	if _listening_action == &"":
		return
	# Only react to "press" frames — releases (key-up / button-up) would
	# fire twice per binding attempt otherwise.
	if event is InputEventKey:
		var key_event: InputEventKey = event
		if not key_event.pressed or key_event.echo:
			return
		# ESC = cancel, regardless of whether the user is currently rebinding
		# the pause action. Refusing to bind ESC is one less footgun.
		if key_event.physical_keycode == KEY_ESCAPE:
			_cancel_listen()
			get_viewport().set_input_as_handled()
			return
		_commit_binding(key_event)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if not mb.pressed:
			# Swallow the release that pairs with the press we already
			# captured — otherwise it would propagate to the GUI and (e.g.)
			# trigger the rebind button under the cursor.
			get_viewport().set_input_as_handled()
			return
		_commit_binding(mb)
		get_viewport().set_input_as_handled()


func _commit_binding(event: InputEvent) -> void:
	# Build a clean event object so we don't carry over modifier flags /
	# position / pressure from the capture frame.
	var clean: InputEvent = null
	if event is InputEventKey:
		var k := InputEventKey.new()
		k.physical_keycode = (event as InputEventKey).physical_keycode
		clean = k
	elif event is InputEventMouseButton:
		var m := InputEventMouseButton.new()
		m.button_index = (event as InputEventMouseButton).button_index
		clean = m
	if clean == null:
		_cancel_listen()
		return
	var displaced: Array[StringName] = InputActions.rebind_action(_listening_action, clean)
	_pending_events[_listening_action] = clean
	# Any actions cleared as collateral get an explicit NONE entry so Save
	# writes "" for them too (otherwise the next boot would silently
	# restore the defaults we just displaced).
	for d in displaced:
		_pending_events[d] = null
	_listening_action = &""
	_listening_button = null
	_refresh_all_rows()


func _cancel_listen() -> void:
	if _listening_button != null and is_instance_valid(_listening_button):
		_listening_button.text = InputActions.event_display_name(
			InputActions.primary_event(_listening_action)
		)
	_listening_action = &""
	_listening_button = null


# --- Snapshot / save / cancel ---


func _visible_actions() -> Array:
	# Walks the same lists controls_menu just rendered — gameplay always,
	# debug only when the user had debug_enabled at open time. _build_panel
	# already gates the debug rows the same way; this mirror keeps Cancel /
	# Reset from touching debug bindings the user never even saw.
	var out: Array = []
	out.append_array(InputActions.GAMEPLAY_ACTIONS)
	if Game.debug_enabled:
		out.append_array(InputActions.DEBUG_ACTIONS)
	return out


func _snapshot_baseline() -> void:
	# Capture the InputMap state at open so Cancel can restore it.
	for entry: Array in _visible_actions():
		var action: StringName = entry[0]
		_baseline[action] = InputActions.primary_event(action)


func _refresh_all_rows() -> void:
	for entry: Array in _visible_actions():
		var action: StringName = entry[0]
		var btn: Button = _rows.get(action)
		if btn == null:
			continue
		btn.text = InputActions.event_display_name(InputActions.primary_event(action))


func _on_save_pressed() -> void:
	# Persist every action the user actually touched. Unchanged actions
	# are left out of the cfg so they'll fall through to register_defaults
	# on next boot (lets us roll forward defaults without nuking saves).
	var cfg := ConfigFile.new()
	cfg.load(_SETTINGS_PATH)
	for action: StringName in _pending_events.keys():
		var ev: InputEvent = _pending_events[action]
		cfg.set_value("controls", action, InputActions.encode_event(ev))
	cfg.save(_SETTINGS_PATH)
	SFX.play_click()
	queue_free()


func _on_cancel_pressed() -> void:
	# Roll the live InputMap back to the baseline. Without this, any
	# rebinds the user did would persist for this session even though
	# they cancelled.
	for entry: Array in _visible_actions():
		var action: StringName = entry[0]
		InputMap.action_erase_events(action)
		var ev: InputEvent = _baseline[action]
		if ev != null:
			InputMap.action_add_event(action, ev)
	SFX.play_click()
	queue_free()


func _on_reset_pressed() -> void:
	# Wipe [controls] from settings.cfg and re-register defaults. Doesn't
	# auto-save — user still has to hit Save to commit, matching the
	# Save/Cancel contract for the rest of the screen.
	var cfg := ConfigFile.new()
	cfg.load(_SETTINGS_PATH)
	if cfg.has_section("controls"):
		cfg.erase_section("controls")
	# Force-reload defaults: clear current InputMap entries and re-run
	# register_defaults. Don't need to apply overrides on top since we
	# just emptied them.
	for entry: Array in _visible_actions():
		var action: StringName = entry[0]
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		_pending_events[action] = null
	InputActions.register_defaults()
	# Mark each visible action with its now-restored default so Save
	# writes them (otherwise Save would skip them and the on-disk cfg
	# would keep stale entries from a previous session).
	_pending_events.clear()
	for entry: Array in _visible_actions():
		var action: StringName = entry[0]
		_pending_events[action] = InputActions.primary_event(action)
	_refresh_all_rows()
	SFX.play_click()
