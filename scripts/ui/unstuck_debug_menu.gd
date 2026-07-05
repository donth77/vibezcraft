class_name UnstuckDebugMenu
extends Control

# Recovery + diagnostics submenu, reached from Pause → Options →
# "Unstuck / Debug". Shows the player debug report in a read-only text
# box with two vanilla-styled actions in a row: Teleport to Spawn (left,
# the universal un-stick) and Copy Debug Log (right, report → clipboard).
#
# Opens as an overlay child of the tree root while the game is paused —
# the same pattern controls_menu uses. Esc (or Back) returns to Options;
# Teleport closes everything and resumes gameplay so the player lands
# back in the world at spawn instead of on a stack of menus.

# Set by InGameOptions before this overlay enters the tree. Used only by
# the Teleport action to hand off "resume all the way to gameplay."
var _options: Control = null
var _copy_btn: VanillaButton = null
var _copy_flash_sec: float = 0.0


func setup(options: Control) -> void:
	_options = options


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)
	_build_background()
	_build_panel()


func _build_background() -> void:
	# Match InGameOptions' dim so this reads as a deeper page of the same
	# paused-menu flow rather than a separate context.
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)


func _build_panel() -> void:
	var title := Label.new()
	title.text = "Unstuck / Debug"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.anchor_top = 0.08
	title.anchor_bottom = 0.08
	title.offset_bottom = 80
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_shadow_color", Color.BLACK)
	title.add_theme_constant_override("shadow_offset_x", 6)
	title.add_theme_constant_override("shadow_offset_y", 6)
	add_child(title)

	var hint := Label.new()
	hint.text = "Share this log with a bug report. Esc to go back."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.anchor_left = 0.0
	hint.anchor_right = 1.0
	hint.anchor_top = 0.08
	hint.anchor_bottom = 0.08
	hint.offset_top = 92
	hint.offset_bottom = 92 + 30
	hint.add_theme_font_size_override("font_size", 22)
	hint.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	add_child(hint)

	# Read-only debug log, snapshotted when the screen opens. Sized to
	# fill the space between the hint and the button row, with word-wrap +
	# vertical scroll so a long rolling event log stays fully readable.
	var log_box := TextEdit.new()
	log_box.text = _collect_report()
	log_box.editable = false
	log_box.scroll_fit_content_height = false
	log_box.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	log_box.scroll_vertical = 0  # start at the top (snapshot header first)
	log_box.anchor_left = 0.5
	log_box.anchor_right = 0.5
	log_box.anchor_top = 0.20
	log_box.anchor_bottom = 0.76
	log_box.offset_left = -490
	log_box.offset_right = 490
	log_box.offset_top = 0
	log_box.offset_bottom = 0
	var mc_font: Font = MinecraftFont.get_font()
	if mc_font != null:
		log_box.add_theme_font_override("font", mc_font)
	log_box.add_theme_font_size_override("font_size", 24)
	log_box.add_theme_color_override("font_color", Color(0.9, 0.95, 0.9))
	log_box.add_theme_color_override(
		"background_color", Color(0x14 / 255.0, 0x14 / 255.0, 0x18 / 255.0)
	)
	add_child(log_box)

	# Two vanilla-styled actions in a row (same pattern as controls_menu's
	# Reset/Save/Cancel row). Teleport left, Copy right.
	var button_row := HBoxContainer.new()
	button_row.anchor_left = 0.5
	button_row.anchor_right = 0.5
	button_row.anchor_top = 0.80
	button_row.anchor_bottom = 0.80
	button_row.offset_left = -470
	button_row.offset_right = 470
	button_row.offset_top = 0
	button_row.offset_bottom = 80
	button_row.add_theme_constant_override("separation", 24)
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(button_row)

	var tp_btn := VanillaButton.new()
	tp_btn.text = "Teleport to Spawn"
	tp_btn.custom_minimum_size = Vector2(460, 80)
	tp_btn.set_font_size(30)
	tp_btn.pressed.connect(_on_teleport_pressed)
	button_row.add_child(tp_btn)

	_copy_btn = VanillaButton.new()
	_copy_btn.text = "Copy Debug Log"
	_copy_btn.custom_minimum_size = Vector2(460, 80)
	_copy_btn.set_font_size(30)
	_copy_btn.pressed.connect(_on_copy_pressed)
	button_row.add_child(_copy_btn)


# Player debug report, or a clear placeholder if the player node is
# somehow absent (shouldn't happen — this only opens over a live world).
func _collect_report() -> String:
	var player: Node3D = get_tree().root.get_node_or_null("Main/Player") as Node3D
	if player != null and player.has_method("_build_debug_report"):
		return String(player.call("_build_debug_report"))
	return "[debug report unavailable — player node not found]"


func _on_teleport_pressed() -> void:
	var player: Node3D = get_tree().root.get_node_or_null("Main/Player") as Node3D
	if player != null and player.has_method("_teleport_to_spawn"):
		player.call("_teleport_to_spawn")
	# Close this submenu AND the Options screen underneath, resuming
	# gameplay — teleporting means the player wants to play, not stare at
	# menus stacked over their fresh spawn.
	if is_instance_valid(_options) and _options.has_method("close_to_gameplay"):
		_options.call("close_to_gameplay")
	queue_free()


func _on_copy_pressed() -> void:
	# Refresh the snapshot so the copied log reflects the moment of the
	# copy, not screen-open, then confirm before the clipboard write (the
	# web export's async Clipboard API can reject without a fresh gesture;
	# the copy still lands on real taps/clicks).
	var report: String = _collect_report()
	_copy_btn.text = "Copied!"
	_copy_flash_sec = 1.4
	set_process(true)
	DisplayServer.clipboard_set(report)


func _process(delta: float) -> void:
	if _copy_flash_sec <= 0.0:
		return
	_copy_flash_sec -= delta
	if _copy_flash_sec <= 0.0 and _copy_btn != null:
		_copy_btn.text = "Copy Debug Log"
		set_process(false)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") or event.is_action_pressed("toggle_inventory"):
		# Esc / inventory key backs out to Options (which re-shows itself
		# on our tree_exited).
		queue_free()
		get_viewport().set_input_as_handled()
