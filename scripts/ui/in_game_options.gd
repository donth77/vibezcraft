class_name InGameOptions
extends Control

# In-game options overlay — reachable from pause menu → Options.
# Intentional friendlier UX than vanilla: dropdowns + Save/Cancel instead
# of cycle buttons. Scope is trimmed to only live-applicable settings;
# anything that requires a scene reload (render distance, clouds) or
# world regen (seed) lives on the main-menu Settings screen so we don't
# lie to the player about Save actually doing something in-game.
#
# Opens as an overlay child of the tree root — paused game stays loaded
# underneath. Save/Cancel queue_free self; pause_menu's tree_exited hook
# restores the pause menu + HUD.

const _SETTINGS_PATH: String = "user://settings.cfg"

const _FPS_CAPS: Array[int] = [0, 60, 90, 120, 144]
const _FPS_CAP_LABELS: Array[String] = ["Uncapped", "60", "90", "120", "144"]

# VSync is binary here (On/Off) — Adaptive/Mailbox are power-user options
# left out of the UI to keep it friendly. Advanced users can set
# graphics.vsync directly in user://settings.cfg.
var _music_slider: HSlider
var _sensitivity_slider: HSlider
var _sensitivity_label: Label
var _fullscreen_checkbox: CheckBox
var _music_label: Label
var _fps_option: OptionButton
var _vsync_checkbox: CheckBox
var _fog_checkbox: CheckBox
var _sfx_checkbox: CheckBox


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_background()
	_build_panel()
	_load_settings()


func _build_background() -> void:
	# Semi-transparent dim over the paused world. Matches pause_menu's
	# 0.55 alpha so opening Options feels like "another page" of the same
	# screen rather than a completely separate context.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)


func _build_panel() -> void:
	var title := Label.new()
	title.text = "Options"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	# Anchor + offset numbers re-balanced after adding the "Controls..." button:
	# title→vbox→button_col is now ~960 px tall at 80 px/button, so the whole
	# stack lives between y≈108..968 at 1080p (≈100 px margin top + bottom).
	title.anchor_top = 0.10
	title.anchor_bottom = 0.10
	title.offset_bottom = 96
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_shadow_color", Color.BLACK)
	title.add_theme_constant_override("shadow_offset_x", 8)
	title.add_theme_constant_override("shadow_offset_y", 8)
	add_child(title)

	# Options rows live in a ScrollContainer so a tall list (mobile adds
	# Fullscreen + Touch sensitivity rows) scrolls instead of colliding
	# with the pinned button column below. Desktop's 5 rows fit the
	# window without scrolling. The window sits between the title and the
	# button column (fixed anchors, 0.20..0.58).
	var scroll := ScrollContainer.new()
	scroll.anchor_left = 0.5
	scroll.anchor_right = 0.5
	scroll.anchor_top = 0.19
	scroll.anchor_bottom = 0.58
	scroll.offset_left = -380
	scroll.offset_right = 380
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 16)
	scroll.add_child(vbox)

	_add_music_row(vbox)
	_sfx_checkbox = _add_checkbox_row(vbox, "Sound effects")
	_fps_option = _add_option_row(vbox, "Frame rate cap", _FPS_CAP_LABELS)
	_vsync_checkbox = _add_checkbox_row(vbox, "VSync")
	_fog_checkbox = _add_checkbox_row(vbox, "Fog")
	# Web-only: browsers gate the Fullscreen API on a user gesture, so
	# the toggle acts immediately (the checkbox press IS the gesture)
	# rather than waiting for Save. Hidden where the API doesn't exist
	# (native desktop, iPhone Safari).
	if Game.web_fullscreen_available():
		_fullscreen_checkbox = _add_checkbox_row(vbox, "Fullscreen")
		_fullscreen_checkbox.set_pressed_no_signal(Game.web_is_fullscreen())
		_fullscreen_checkbox.text = "On" if _fullscreen_checkbox.button_pressed else "Off"
		_fullscreen_checkbox.toggled.connect(_on_fullscreen_toggled)
	# Touch-only: look sensitivity for the drag-look gesture. Applied on
	# Save like the rest of the column.
	if Game.touch_controls_enabled():
		_add_sensitivity_row(vbox)

	# Recovery row + Controls + Save + Cancel, pinned above the bottom
	# edge (anchor 0.60, 4 rows ≈ 372 px → ends ≈ y=1020 at 1080 p). The
	# ScrollContainer above absorbs any option-row growth, so this column
	# never needs a per-row shift and never clips.
	var button_col := VBoxContainer.new()
	button_col.anchor_left = 0.5
	button_col.anchor_right = 0.5
	button_col.anchor_top = 0.60
	button_col.anchor_bottom = 0.60
	button_col.offset_left = -400
	button_col.offset_right = 400
	button_col.offset_top = 0
	button_col.offset_bottom = 372
	button_col.add_theme_constant_override("separation", 16)
	button_col.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(button_col)
	# Recovery + diagnostics entry — one MC-styled button matching the
	# rest of the column; opens the Unstuck / Debug submenu. First so a
	# softlocked player reaches it fastest. See issue #5.
	var unstuck_btn := VanillaButton.new()
	unstuck_btn.text = "Unstuck / Debug"
	unstuck_btn.pressed.connect(_on_unstuck_debug_pressed)
	button_col.add_child(unstuck_btn)
	# Hidden in touch mode (mobile web) — same reasoning as
	# settings_menu.gd: there's no keyboard to rebind. A connected
	# gamepad overrides that: the screen carries the pad rows.
	if not Game.touch_controls_enabled() or not Input.get_connected_joypads().is_empty():
		var controls_btn := VanillaButton.new()
		controls_btn.text = "Controls..."
		controls_btn.pressed.connect(_on_controls_pressed)
		button_col.add_child(controls_btn)
	var save_btn := VanillaButton.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(_on_save_pressed)
	button_col.add_child(save_btn)
	var cancel_btn := VanillaButton.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_on_cancel_pressed)
	button_col.add_child(cancel_btn)


# Open the Unstuck / Debug submenu (recovery + diagnostics). Same
# overlay pattern as _on_controls_pressed: hide this screen, add the
# submenu at the tree root, re-show ourselves when it closes.
func _on_unstuck_debug_pressed() -> void:
	var packed: PackedScene = load("res://scenes/ui/unstuck_debug_menu.tscn") as PackedScene
	if packed == null:
		return
	var overlay: Control = packed.instantiate() as Control
	if overlay == null:
		return
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	if overlay.has_method("setup"):
		overlay.call("setup", self)
	visible = false
	# Re-show Options when the submenu backs out (Esc). If the submenu's
	# Teleport action closed us to gameplay instead, we've been freed and
	# Godot drops this connection automatically — so no guard needed.
	overlay.tree_exited.connect(_on_unstuck_debug_closed)
	get_tree().get_root().add_child(overlay)


func _on_unstuck_debug_closed() -> void:
	visible = true


# Dismiss this overlay AND the pause menu beneath it, returning straight
# to gameplay. Public so the Unstuck / Debug submenu's Teleport action
# can resume all the way out instead of unwinding menu-by-menu. The
# pause menu re-shows itself on our tree_exited; we ask it to fully
# resume instead so a teleport doesn't dump the player back on a menu
# stacked over their fresh spawn.
func close_to_gameplay() -> void:
	var pause: Node = get_tree().root.find_child("PauseMenu", true, false)
	if pause != null and pause.has_method("request_resume_after_options"):
		pause.call("request_resume_after_options")
	queue_free()


func _add_option_row(parent: VBoxContainer, label_text: String, options: Array) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 32)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_shadow_color", Color.BLACK)
	lbl.add_theme_constant_override("shadow_offset_x", 4)
	lbl.add_theme_constant_override("shadow_offset_y", 4)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(0, 64)
	row.add_child(lbl)

	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(360, 64)
	opt.add_theme_font_size_override("font_size", 32)
	opt.add_theme_color_override("font_color", Color.WHITE)
	opt.add_theme_color_override(
		"font_hover_color", Color(0xFF / 255.0, 0xFF / 255.0, 0xA0 / 255.0)
	)
	opt.add_theme_color_override("font_focus_color", Color.WHITE)
	opt.add_theme_color_override("font_shadow_color", Color.BLACK)
	opt.add_theme_constant_override("shadow_offset_x", 4)
	opt.add_theme_constant_override("shadow_offset_y", 4)
	opt.add_theme_stylebox_override(
		"normal", _make_option_panel(Color(0x28 / 255.0, 0x28 / 255.0, 0x2C / 255.0))
	)
	opt.add_theme_stylebox_override(
		"hover", _make_option_panel(Color(0x4A / 255.0, 0x4C / 255.0, 0x58 / 255.0))
	)
	opt.add_theme_stylebox_override(
		"pressed", _make_option_panel(Color(0x4A / 255.0, 0x4C / 255.0, 0x58 / 255.0))
	)
	opt.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for value in options:
		opt.add_item(str(value))
	opt.item_selected.connect(func(_idx: int) -> void: SFX.play_click())
	opt.pressed.connect(SFX.play_click)
	row.add_child(opt)
	_style_popup(opt.get_popup())
	return opt


# Binary on/off row using CheckBox. Same row height + font treatment as
# the dropdown rows so the column stays visually aligned. Shows "On" /
# "Off" beside the tick so the state is unambiguous.
func _add_checkbox_row(parent: VBoxContainer, label_text: String) -> CheckBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 32)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_shadow_color", Color.BLACK)
	lbl.add_theme_constant_override("shadow_offset_x", 4)
	lbl.add_theme_constant_override("shadow_offset_y", 4)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(0, 64)
	row.add_child(lbl)

	var cb := CheckBox.new()
	cb.custom_minimum_size = Vector2(360, 64)
	cb.text = "Off"
	cb.add_theme_font_size_override("font_size", 32)
	cb.add_theme_color_override("font_color", Color.WHITE)
	cb.add_theme_color_override("font_hover_color", Color(0xFF / 255.0, 0xFF / 255.0, 0xA0 / 255.0))
	cb.add_theme_color_override("font_shadow_color", Color.BLACK)
	cb.add_theme_constant_override("shadow_offset_x", 4)
	cb.add_theme_constant_override("shadow_offset_y", 4)
	cb.add_theme_constant_override("h_separation", 18)
	cb.toggled.connect(func(pressed: bool) -> void: cb.text = "On" if pressed else "Off")
	cb.toggled.connect(func(_pressed: bool) -> void: SFX.play_click())
	row.add_child(cb)
	return cb


func _add_music_row(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = "Music"
	lbl.add_theme_font_size_override("font_size", 32)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_shadow_color", Color.BLACK)
	lbl.add_theme_constant_override("shadow_offset_x", 4)
	lbl.add_theme_constant_override("shadow_offset_y", 4)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(0, 64)
	row.add_child(lbl)

	_music_label = Label.new()
	_music_label.text = "100%"
	_music_label.add_theme_font_size_override("font_size", 24)
	_music_label.add_theme_color_override("font_color", Color.WHITE)
	_music_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_music_label.add_theme_constant_override("shadow_offset_x", 3)
	_music_label.add_theme_constant_override("shadow_offset_y", 3)
	_music_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_music_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_music_label.custom_minimum_size = Vector2(80, 64)
	row.add_child(_music_label)

	_music_slider = HSlider.new()
	_music_slider.min_value = 0.0
	_music_slider.max_value = 1.0
	_music_slider.step = 0.01
	_music_slider.value = 1.0
	_music_slider.custom_minimum_size = Vector2(260, 64)
	_music_slider.value_changed.connect(_on_music_slider_changed)
	row.add_child(_music_slider)


func _on_music_slider_changed(value: float) -> void:
	if value <= 0.0:
		_music_label.text = "OFF"
	else:
		_music_label.text = "%d%%" % int(value * 100.0)


# Touch look sensitivity — same row layout as the music slider. Range
# 40%..200% of the default 130°-per-screen-height drag rate.
func _add_sensitivity_row(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = "Touch look sensitivity"
	lbl.add_theme_font_size_override("font_size", 32)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_shadow_color", Color.BLACK)
	lbl.add_theme_constant_override("shadow_offset_x", 4)
	lbl.add_theme_constant_override("shadow_offset_y", 4)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(0, 64)
	row.add_child(lbl)

	_sensitivity_label = Label.new()
	_sensitivity_label.text = "100%"
	_sensitivity_label.add_theme_font_size_override("font_size", 24)
	_sensitivity_label.add_theme_color_override("font_color", Color.WHITE)
	_sensitivity_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_sensitivity_label.add_theme_constant_override("shadow_offset_x", 3)
	_sensitivity_label.add_theme_constant_override("shadow_offset_y", 3)
	_sensitivity_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_sensitivity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_sensitivity_label.custom_minimum_size = Vector2(80, 64)
	row.add_child(_sensitivity_label)

	_sensitivity_slider = HSlider.new()
	_sensitivity_slider.min_value = 0.4
	_sensitivity_slider.max_value = 2.0
	_sensitivity_slider.step = 0.05
	_sensitivity_slider.value = 1.0
	_sensitivity_slider.custom_minimum_size = Vector2(260, 64)
	_sensitivity_slider.value_changed.connect(_on_sensitivity_changed)
	row.add_child(_sensitivity_slider)


func _on_sensitivity_changed(value: float) -> void:
	_sensitivity_label.text = "%d%%" % int(round(value * 100.0))


func _on_fullscreen_toggled(enable: bool) -> void:
	Game.web_set_fullscreen(enable)
	# Turning it off latches the opt-out so Game's first-gesture
	# auto-fullscreen (mobile) stops re-entering on the next tap.
	Game.fullscreen_user_opt_out = not enable


static func _style_popup(popup: PopupMenu) -> void:
	popup.add_theme_font_size_override("font_size", 24)
	popup.add_theme_color_override("font_color", Color.WHITE)
	popup.add_theme_color_override(
		"font_hover_color", Color(0xFF / 255.0, 0xFF / 255.0, 0xA0 / 255.0)
	)
	popup.add_theme_stylebox_override(
		"panel", _make_option_panel(Color(0x28 / 255.0, 0x28 / 255.0, 0x2C / 255.0))
	)
	popup.add_theme_stylebox_override(
		"hover", _make_option_panel(Color(0x4A / 255.0, 0x4C / 255.0, 0x58 / 255.0))
	)


static func _make_option_panel(fill: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(0, 0, 0, 1.0)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


# --- Load / save / apply ---


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(_SETTINGS_PATH)
	var music_vol: float = float(cfg.get_value("audio", "music_volume", 0.25))
	_music_slider.value = music_vol
	_on_music_slider_changed(music_vol)
	var fps_cap: int = int(cfg.get_value("graphics", "fps_cap", 90))
	var vsync_mode: int = int(cfg.get_value("graphics", "vsync", DisplayServer.VSYNC_DISABLED))
	_fps_option.selected = maxi(_FPS_CAPS.find(fps_cap), 0)
	_vsync_checkbox.button_pressed = vsync_mode != DisplayServer.VSYNC_DISABLED
	_vsync_checkbox.text = "On" if _vsync_checkbox.button_pressed else "Off"
	var fog_on: bool = bool(cfg.get_value("graphics", "fog_enabled", true))
	_fog_checkbox.button_pressed = fog_on
	_fog_checkbox.text = "On" if fog_on else "Off"
	var sfx_on: bool = bool(cfg.get_value("audio", "sfx_enabled", true))
	_sfx_checkbox.button_pressed = sfx_on
	_sfx_checkbox.text = "On" if sfx_on else "Off"
	if _sensitivity_slider != null:
		var sens: float = float(cfg.get_value("controls", "touch_look_sensitivity", 1.0))
		_sensitivity_slider.value = sens
		_on_sensitivity_changed(sens)


func _on_save_pressed() -> void:
	var cfg := ConfigFile.new()
	cfg.load(_SETTINGS_PATH)
	var cap: int = _FPS_CAPS[_fps_option.selected]
	var vmode: int = (
		DisplayServer.VSYNC_ENABLED
		if _vsync_checkbox.button_pressed
		else DisplayServer.VSYNC_DISABLED
	)
	cfg.set_value("graphics", "fps_cap", cap)
	cfg.set_value("graphics", "vsync", vmode)
	cfg.set_value("graphics", "fog_enabled", _fog_checkbox.button_pressed)
	cfg.set_value("audio", "sfx_enabled", _sfx_checkbox.button_pressed)
	cfg.set_value("audio", "music_volume", _music_slider.value)
	if _sensitivity_slider != null:
		cfg.set_value("controls", "touch_look_sensitivity", _sensitivity_slider.value)
		TouchControls.look_sensitivity = _sensitivity_slider.value
	cfg.save(_SETTINGS_PATH)
	Engine.max_fps = cap
	DisplayServer.window_set_vsync_mode(vmode)
	Game.fog_enabled = _fog_checkbox.button_pressed
	Game.sfx_enabled = _sfx_checkbox.button_pressed
	_apply_fog_live()
	if Music != null:
		Music.set_volume(_music_slider.value)
	queue_free()


func _apply_fog_live() -> void:
	var env_node: WorldEnvironment = get_tree().root.find_child("WorldEnvironment", true, false)
	if env_node != null and env_node.environment != null:
		env_node.environment.fog_enabled = Game.fog_enabled


func _on_cancel_pressed() -> void:
	queue_free()


# Open the controls rebinding screen. Hide this screen while controls is
# open so the two layered modals don't fight visually. The overlay has
# to live on the scene root, NOT as our child — when we set visible=false,
# Godot recursively hides all descendants, and a child overlay would
# vanish along with us (this softlocked an early version: controls UI
# invisible but its modal grab was active, so the game was unreachable).
func _on_controls_pressed() -> void:
	var packed: PackedScene = load("res://scenes/ui/controls_menu.tscn") as PackedScene
	if packed == null:
		return
	var overlay: Control = packed.instantiate() as Control
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	overlay.tree_exited.connect(func() -> void: visible = true)
	get_tree().get_root().add_child(overlay)
