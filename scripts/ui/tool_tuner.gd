class_name ToolTuner
extends Control

# Live-tuning panel for the FP held tool. Each row is one knob: drag the
# slider, see the value label update, see the pickaxe move in real time.
# Toggle visibility with KEY_T (only when Game.debug_enabled). Releases
# mouse capture while open so you can interact with the sliders.

signal value_changed(key: String, value: float)

# Per-mode best preset — keep in sync with the player.gd defaults so the
# in-game state matches what these would re-apply. Both presets assume
# Vanilla MC Curves ON and Vanilla Sprite Orient ON.
const _FP_BEST_PRESET: Dictionary = {
	"pos_x": 0.390,
	"pos_y": -0.630,
	"pos_z": -0.640,
	"rot_x_deg": 0.000,
	"rot_y_deg": 9.000,
	"rot_z_deg": 0.000,
	"pixel_size": 0.036,
	"swing_x_deg": -55.000,
	"swing_y_deg": 0.000,
	"swing_z_deg": 0.000,
	"swing_thrust_fwd": 0.080,
}
const _TP_BEST_PRESET: Dictionary = {
	"pos_x": 0.000,
	"pos_y": -0.750,
	"pos_z": -0.050,
	"rot_x_deg": -20.000,
	"rot_y_deg": 35.000,
	"rot_z_deg": 0.000,
	"pixel_size": 0.050,
}

# Knob spec. Each entry: [key, label, min, max, step].
const _SPECS: Array = [
	["pos_x", "Pos X", -2.0, 2.0, 0.01],
	["pos_y", "Pos Y", -2.0, 2.0, 0.01],
	["pos_z", "Pos Z", -2.0, 2.0, 0.01],
	["rot_x_deg", "Rot X (°)", -180.0, 180.0, 1.0],
	["rot_y_deg", "Rot Y (°)", -180.0, 180.0, 1.0],
	["rot_z_deg", "Rot Z (°)", -180.0, 180.0, 1.0],
	["pixel_size", "Pixel Size", 0.005, 0.10, 0.001],
	["swing_x_deg", "Swing X (°)", -180.0, 180.0, 1.0],
	["swing_y_deg", "Swing Y (°)", -180.0, 180.0, 1.0],
	["swing_z_deg", "Swing Z (°)", -180.0, 180.0, 1.0],
	["swing_thrust_fwd", "Swing Thrust Fwd", -0.5, 0.5, 0.005],
]

const _ROW_HEIGHT: int = 52
const _FONT_SIZE: int = 26
const _PANEL_WIDTH: int = 680

var _player: Node  # weak ref; we read/write its tunable vars directly
var _was_captured: bool = false
var _rows: Dictionary = {}  # key -> {slider, value_label}
var _vanilla_btn: Button
var _orient_btn: Button
var _mode_btn: Button


func setup(player: Node) -> void:
	_player = player


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	# Anchor top-left of the screen
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	offset_left = 16
	offset_top = 16
	offset_right = 16 + _PANEL_WIDTH
	# +6 rows = title + mode btn + vanilla btn + orient btn + preset btn + padding.
	offset_bottom = 16 + _ROW_HEIGHT * (_SPECS.size() + 6)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.65)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE  # don't eat clicks meant for sliders
	add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.offset_left = 12
	vbox.offset_top = 12
	vbox.offset_right = -12
	vbox.offset_bottom = -12
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	var title := Label.new()
	title.text = "Tool Tuner — T to close"
	title.add_theme_font_size_override("font_size", _FONT_SIZE + 4)
	vbox.add_child(title)

	# Mode switch — flips the slider value set between FP and TP rest poses.
	# Sliders refresh from the new mode's values on click.
	var mode_btn := Button.new()
	mode_btn.text = "Mode: FP"
	_style_button(mode_btn)
	mode_btn.pressed.connect(func() -> void: _toggle_mode())
	vbox.add_child(mode_btn)
	_mode_btn = mode_btn

	for spec: Array in _SPECS:
		var row := _build_row(spec[0], spec[1], spec[2], spec[3], spec[4])
		vbox.add_child(row)

	# Vanilla-curves toggle. When ON, _apply_tool_swing on the player uses
	# verbatim Beta 1.7.3 ItemRenderer math (3-axis sin curves + translate)
	# instead of the slider-controlled amplitudes. Rest-pose sliders still
	# apply (they feed the base position/rotation into the vanilla math).
	var vanilla_btn := Button.new()
	vanilla_btn.text = "Vanilla MC Curves: OFF"
	_style_button(vanilla_btn)
	vanilla_btn.pressed.connect(func() -> void: _toggle_vanilla(vanilla_btn))
	vbox.add_child(vanilla_btn)
	_vanilla_btn = vanilla_btn

	# Vanilla inner sprite tilt (the 50°Y / -25°Z that vanilla applies inside
	# renderItem). When ON, the held mesh sits in vanilla's tool orientation
	# instead of facing flat at the camera.
	var orient_btn := Button.new()
	orient_btn.text = "Vanilla Sprite Orient: OFF"
	_style_button(orient_btn)
	orient_btn.pressed.connect(func() -> void: _toggle_orient(orient_btn))
	vbox.add_child(orient_btn)
	_orient_btn = orient_btn

	# One-shot apply of the user's best-so-far preset (snaps every slider
	# to a known-good value AND turns vanilla curves on).
	var preset_btn := Button.new()
	preset_btn.text = "Apply Best Preset"
	_style_button(preset_btn)
	preset_btn.pressed.connect(func() -> void: _apply_best_preset())
	vbox.add_child(preset_btn)

	_pull_values_from_player()


func _build_row(key: String, label_text: String, vmin: float, vmax: float, step: float) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, _ROW_HEIGHT - 4)

	var name_label := Label.new()
	name_label.text = label_text
	name_label.custom_minimum_size = Vector2(230, 0)
	name_label.add_theme_font_size_override("font_size", _FONT_SIZE)
	row.add_child(name_label)

	var slider := HSlider.new()
	slider.min_value = vmin
	slider.max_value = vmax
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(220, 40)
	row.add_child(slider)

	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(110, 0)
	value_label.text = "%.3f" % 0.0
	value_label.add_theme_font_size_override("font_size", _FONT_SIZE)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)

	slider.value_changed.connect(func(v: float) -> void: _on_slider(key, v))
	_rows[key] = {"slider": slider, "value": value_label}
	return row


# Apply a consistent visual style + larger font to all the toggle buttons.
func _style_button(btn: Button) -> void:
	btn.add_theme_font_size_override("font_size", _FONT_SIZE)
	btn.custom_minimum_size = Vector2(0, _ROW_HEIGHT - 4)


func _on_slider(key: String, v: float) -> void:
	if _rows.has(key):
		_rows[key]["value"].text = "%.3f" % v
	if _player == null:
		return
	if _player.has_method("apply_tuner_value"):
		_player.apply_tuner_value(key, v)


func _pull_values_from_player() -> void:
	if _player == null:
		return
	for spec: Array in _SPECS:
		var key: String = spec[0]
		if not _player.has_method("get_tuner_value"):
			break
		var v: float = _player.get_tuner_value(key)
		var slider: HSlider = _rows[key]["slider"]
		slider.set_value_no_signal(v)
		_rows[key]["value"].text = "%.3f" % v
	_refresh_vanilla_btn()
	_refresh_orient_btn()
	_refresh_mode_btn()


func _toggle_vanilla(_btn: Button) -> void:
	if _player == null or not _player.has_method("toggle_vanilla_swing"):
		return
	_player.toggle_vanilla_swing()
	_refresh_vanilla_btn()


func _toggle_orient(_btn: Button) -> void:
	if _player == null or not _player.has_method("toggle_vanilla_orient"):
		return
	_player.toggle_vanilla_orient()
	_refresh_orient_btn()


func _toggle_mode() -> void:
	if _player == null or not _player.has_method("get_tuner_mode"):
		return
	var current: String = _player.get_tuner_mode()
	var next: String = "tp" if current == "fp" else "fp"
	_player.set_tuner_mode(next)
	_pull_values_from_player()  # refreshes sliders + button labels


# Snaps every slider to the active mode's preset. Forces vanilla curves
# (FP only) and vanilla orient on, since both presets were dialed in with
# those enabled.
func _apply_best_preset() -> void:
	if _player == null:
		return
	var mode: String = "fp"
	if _player.has_method("get_tuner_mode"):
		mode = _player.get_tuner_mode()
	var preset: Dictionary = _TP_BEST_PRESET if mode == "tp" else _FP_BEST_PRESET
	for key: String in preset.keys():
		var v: float = preset[key]
		if _rows.has(key):
			_rows[key]["slider"].set_value_no_signal(v)
			_rows[key]["value"].text = "%.3f" % v
		if _player.has_method("apply_tuner_value"):
			_player.apply_tuner_value(key, v)
	# Both presets assume vanilla orient on; FP also assumes vanilla curves.
	if _player.has_method("is_vanilla_orient") and not _player.is_vanilla_orient():
		if _player.has_method("toggle_vanilla_orient"):
			_player.toggle_vanilla_orient()
	if mode == "fp":
		if _player.has_method("is_vanilla_swing") and not _player.is_vanilla_swing():
			if _player.has_method("toggle_vanilla_swing"):
				_player.toggle_vanilla_swing()
	_refresh_vanilla_btn()
	_refresh_orient_btn()


func _refresh_vanilla_btn() -> void:
	if _vanilla_btn == null or _player == null:
		return
	var on: bool = false
	if _player.has_method("is_vanilla_swing"):
		on = _player.is_vanilla_swing()
	_vanilla_btn.text = "Vanilla MC Curves: %s" % ("ON" if on else "OFF")


func _refresh_orient_btn() -> void:
	if _orient_btn == null or _player == null:
		return
	var on: bool = false
	if _player.has_method("is_vanilla_orient"):
		on = _player.is_vanilla_orient()
	_orient_btn.text = "Vanilla Sprite Orient: %s" % ("ON" if on else "OFF")


func _refresh_mode_btn() -> void:
	if _mode_btn == null or _player == null:
		return
	var mode: String = "fp"
	if _player.has_method("get_tuner_mode"):
		mode = _player.get_tuner_mode()
	_mode_btn.text = "Mode: %s" % mode.to_upper()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	_pull_values_from_player()
	visible = true
	# Always release the cursor while the tuner is up, regardless of prior
	# state. We restore on close() based on _was_captured.
	_was_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	print(
		(
			"[ToolTuner] open: mouse_mode=%d (VISIBLE=%d), rect=%s"
			% [Input.mouse_mode, Input.MOUSE_MODE_VISIBLE, str(get_rect())]
		)
	)


func close() -> void:
	visible = false
	if _was_captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
