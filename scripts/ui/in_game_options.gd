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
	title.anchor_top = 0.18
	title.anchor_bottom = 0.18
	title.offset_bottom = 96
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_shadow_color", Color.BLACK)
	title.add_theme_constant_override("shadow_offset_x", 8)
	title.add_theme_constant_override("shadow_offset_y", 8)
	add_child(title)

	var vbox := VBoxContainer.new()
	vbox.anchor_left = 0.5
	vbox.anchor_right = 0.5
	vbox.anchor_top = 0.34
	vbox.anchor_bottom = 0.34
	vbox.offset_left = -360
	vbox.offset_right = 360
	vbox.offset_top = 0
	# 5 rows × 64 px + 4 × 16 separation = 384 px.
	vbox.offset_bottom = 384
	vbox.add_theme_constant_override("separation", 16)
	add_child(vbox)

	_add_music_row(vbox)
	_sfx_checkbox = _add_checkbox_row(vbox, "Sound effects")
	_fps_option = _add_option_row(vbox, "Frame rate cap", _FPS_CAP_LABELS)
	_vsync_checkbox = _add_checkbox_row(vbox, "VSync")
	_fog_checkbox = _add_checkbox_row(vbox, "Fog")

	# Save + Cancel stacked vertically below the options. Two
	# VanillaButtons (800×80 each) + 16 px separation = 176 px tall.
	var button_col := VBoxContainer.new()
	button_col.anchor_left = 0.5
	button_col.anchor_right = 0.5
	button_col.anchor_top = 0.72
	button_col.anchor_bottom = 0.72
	button_col.offset_left = -400
	button_col.offset_right = 400
	button_col.offset_top = 0
	button_col.offset_bottom = 176
	button_col.add_theme_constant_override("separation", 16)
	button_col.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(button_col)
	var save_btn := VanillaButton.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(_on_save_pressed)
	button_col.add_child(save_btn)
	var cancel_btn := VanillaButton.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_on_cancel_pressed)
	button_col.add_child(cancel_btn)


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
