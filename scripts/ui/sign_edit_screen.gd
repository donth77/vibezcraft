class_name SignEditScreen
extends Control

# Vanilla MC's GuiEditSign — opens after placing a sign so the player
# can inscribe the 4 lines of text. Vanilla qc.java (TileEntitySign)
# stores 4 lines × 15 chars; the GUI enforces the length cap via the
# LineEdit max_length.
#
# Flow:
#   1. _try_place_sign in interaction.gd places the sign + creates the
#      empty SignStorage entry, then calls this screen's `open(pos)`.
#   2. The 4 LineEdits prefill from SignStorage.get_lines(pos) (empty
#      strings on fresh placements; existing text on right-click-edit
#      in stage 2D).
#   3. Done button (or Enter on the last line) writes all 4 lines back
#      to SignStorage and closes. Esc closes without saving — keeps
#      whatever text was there before opening.
#   4. Mouse cursor is unhidden while the screen is open; restored on
#      close. The player's locomotion is gated on `_screen_blocking()`
#      checks in player.gd via the existing pause / inventory pattern.
#
# Scene is added as a CanvasLayer child in crosshair.tscn next to the
# other modal screens (inventory, furnace, chest).

const FONT_PATH: String = "res://assets/fonts/Minecraft.otf"

# Vanilla nq.aD (BlockSign) caps each line at 15 chars. The GUI
# enforces this via LineEdit.max_length so the player can't even type
# past it; SignStorage.set_text also clips defensively.
const MAX_CHARS_PER_LINE: int = 15

var _lines: Array[LineEdit] = []
var _target_pos: Vector3i = Vector3i.ZERO
var _is_open: bool = false
var _prev_mouse_mode: int = Input.MOUSE_MODE_CAPTURED


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	# Dim the world behind the dialog so the focus reads cleanly.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	# Centered panel.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.12, 0.98)
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(0.45, 0.45, 0.50)
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 24
	sb.content_margin_right = 24
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)
	var title := Label.new()
	title.text = "Edit Sign"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	vbox.add_child(title)
	var sub := Label.new()
	sub.text = "(Esc to cancel — Done saves)"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", Color(0.75, 0.75, 0.78))
	vbox.add_child(sub)
	# 4 LineEdit rows. Each enforces max_length so typing past 15 chars
	# is silently dropped (vanilla parity — the GUI input cap matches
	# the storage cap, no separate truncation needed).
	for i in range(4):
		var line := LineEdit.new()
		line.placeholder_text = "Line %d" % (i + 1)
		line.max_length = MAX_CHARS_PER_LINE
		line.custom_minimum_size = Vector2(360, 32)
		line.add_theme_font_size_override("font_size", 18)
		# Enter on the last line acts as Done. Enter on lines 1-3
		# advances focus to the next line (vanilla "tab to next line").
		var next_idx: int = i + 1
		line.text_submitted.connect(_on_line_submitted.bind(next_idx))
		_lines.append(line)
		vbox.add_child(line)
	# Done button.
	var done := Button.new()
	done.text = "Done"
	done.custom_minimum_size = Vector2(120, 36)
	done.add_theme_font_size_override("font_size", 18)
	done.pressed.connect(_save_and_close)
	var done_center := CenterContainer.new()
	done_center.add_child(done)
	vbox.add_child(done_center)


# Public entry point — called by interaction.gd after a successful
# sign placement (or by the right-click handler in stage 2D).
func open(pos: Vector3i) -> void:
	_target_pos = pos
	_is_open = true
	_prev_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Prefill with current text (empty on fresh placement; existing on
	# right-click edit). SignStorage.get_lines returns 4 strings even
	# when the position has no entry, so we don't need a has_sign guard.
	var existing: Array = SignStorage.get_lines(pos)
	for i in range(4):
		_lines[i].text = String(existing[i])
	visible = true
	# Focus the first line so the player can type immediately.
	if not _lines.is_empty():
		_lines[0].grab_focus()


# Esc cancels (closes without writing). Anything else, the LineEdit
# captures.
func _unhandled_input(event: InputEvent) -> void:
	if not _is_open:
		return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			_close_without_saving()
			get_viewport().set_input_as_handled()


# Enter on a line either advances focus (lines 1-3) or saves (line 4).
func _on_line_submitted(_text: String, next_idx: int) -> void:
	if next_idx < 4:
		_lines[next_idx].grab_focus()
	else:
		_save_and_close()


# Write all 4 lines to SignStorage and close. Vanilla parity: if the
# player typed nothing, the sign stays blank (SignStorage already has
# 4 empty strings from the placement-time get_or_create).
func _save_and_close() -> void:
	for i in range(4):
		SignStorage.set_text(_target_pos, i, _lines[i].text)
	_close_internal()


# Close without writing — text reverts to whatever was there before.
func _close_without_saving() -> void:
	_close_internal()


func _close_internal() -> void:
	_is_open = false
	visible = false
	Input.mouse_mode = _prev_mouse_mode


# Used by player.gd / pause_menu logic to gate locomotion + camera
# rotation while the sign editor is open.
func is_open() -> bool:
	return _is_open
