extends Control

# Vanilla MC's GuiGameOver — shown when the player's health hits 0. Dims
# the world, shows a red "You Died!" title + a Respawn button. Clicking
# Respawn routes through player._respawn() which restores health and
# teleports to spawn.
#
# Kept minimal for now: no score display, no "Exit to title" button
# (we have no save system yet), no chat overlay. Vanilla additions can
# layer on later.

const FONT_PATH: String = "res://assets/fonts/Minecraft.otf"

var _player: Node


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false

	var dim := ColorRect.new()
	dim.color = Color(0.4, 0.0, 0.0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 48)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "You Died!"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var font: FontFile = MinecraftFont.get_font()
	if font != null:
		title.add_theme_font_override("font", font)
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
	title.add_theme_constant_override("shadow_offset_x", 4)
	title.add_theme_constant_override("shadow_offset_y", 4)
	vbox.add_child(title)

	var btn := Button.new()
	btn.text = "Respawn"
	btn.custom_minimum_size = Vector2(320, 64)
	if font != null:
		btn.add_theme_font_override("font", font)
	btn.add_theme_font_size_override("font_size", 28)
	btn.pressed.connect(SFX.play_click)
	btn.pressed.connect(_on_respawn_pressed)
	vbox.add_child(btn)


func open() -> void:
	if _player == null:
		_player = get_tree().root.get_node_or_null("Main/Player")
	visible = true


func _on_respawn_pressed() -> void:
	if _player == null:
		return
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _player.has_method("_respawn"):
		_player._respawn()
