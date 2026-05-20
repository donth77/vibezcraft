class_name SelectWorldScreen
extends Control

# Step 7.6 of the save/load plan. Ports Alpha 1.2.6's GuiSelectWorld
# (vendor/alpha-1.2.6-src/src/le.java):
#   - Title: "Select world"
#   - Five fixed slots "World 1" through "World 5" (le.java:19-29)
#       - empty:  "- empty -" button — clicking creates the world + launches
#       - filled: "World N (X.XX MB)" — clicking loads + launches
#   - Cancel button returns to main menu
#
# Delete sub-screen lands in step 7.7. For now the slot list is read-only
# at boot — players hit Cancel + use the file system to wipe a world.

const _SLOT_COUNT: int = 5
const _MAIN_SCENE_PATH: String = "res://main.tscn"
const _MAIN_MENU_PATH: String = "res://scenes/ui/main_menu.tscn"
const _BG_TINT: Color = Color(0x40 / 255.0, 0x40 / 255.0, 0x40 / 255.0, 1.0)

var _slot_buttons: Array = []  # length _SLOT_COUNT


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_background()
	_build_title()
	_build_slot_buttons()
	_build_footer_buttons()
	# Force cursor visible (we may have come from in-game where it was
	# captured) — mirrors main_menu.gd's defense.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Pre-focus first slot so the menu is keyboard-usable without a cursor.
	if _slot_buttons.size() > 0 and _slot_buttons[0] != null:
		(_slot_buttons[0] as Control).call_deferred("grab_focus")


# Tiled-dirt backdrop tinted 0x404040, exactly matching main_menu +
# settings_menu so the three screens feel of-a-piece.
func _build_background() -> void:
	var bg := TextureRect.new()
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.stretch_mode = TextureRect.STRETCH_TILE
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	bg.modulate = _BG_TINT
	var dirt: Texture2D = VanillaButton.make_scaled_dirt_texture(4)
	if dirt != null:
		bg.texture = dirt
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)


func _build_title() -> void:
	var title := Label.new()
	title.text = "Select world"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.anchor_top = 0.05
	title.anchor_bottom = 0.05
	title.offset_bottom = 48
	title.add_theme_font_size_override("font_size", 48)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_shadow_color", Color.BLACK)
	title.add_theme_constant_override("shadow_offset_x", 6)
	title.add_theme_constant_override("shadow_offset_y", 6)
	add_child(title)


func _build_slot_buttons() -> void:
	var vbox := VBoxContainer.new()
	vbox.anchor_left = 0.5
	vbox.anchor_right = 0.5
	vbox.anchor_top = 0.18
	vbox.anchor_bottom = 0.18
	vbox.offset_left = -400
	vbox.offset_right = 400
	vbox.offset_top = 0
	vbox.offset_bottom = 400
	vbox.add_theme_constant_override("separation", 16)
	add_child(vbox)
	_slot_buttons.resize(_SLOT_COUNT)
	for i in range(_SLOT_COUNT):
		var slot_index: int = i + 1  # World1 .. World5, Alpha 1-indexed
		var btn := VanillaButton.new()
		btn.text = _slot_label(slot_index)
		btn.pressed.connect(_on_slot_pressed.bind(slot_index))
		vbox.add_child(btn)
		_slot_buttons[i] = btn


func _build_footer_buttons() -> void:
	var col := VBoxContainer.new()
	col.anchor_left = 0.5
	col.anchor_right = 0.5
	col.anchor_top = 0.82
	col.anchor_bottom = 0.82
	col.offset_left = -400
	col.offset_right = 400
	col.add_theme_constant_override("separation", 16)
	add_child(col)
	var cancel := VanillaButton.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(_on_cancel_pressed)
	col.add_child(cancel)


# Format follows le.java:25-28 verbatim: "World N (X.XX MB)" for filled
# slots, "- empty -" otherwise.
func _slot_label(slot_index: int) -> String:
	var world_name: String = "World%d" % slot_index
	if not SaveLoad.world_exists(world_name):
		return "- empty -"
	var bytes: int = SaveLoad.world_size_bytes(world_name)
	var mb: float = float(bytes) / (1024.0 * 1024.0)
	return "World %d (%.2f MB)" % [slot_index, mb]


# Either creates the world (if empty) or loads it (if filled). Both
# paths just set Game.active_world and scene-change into main.tscn —
# SaveLoad / WorldMeta / PlayerSave then default to that name.
func _on_slot_pressed(slot_index: int) -> void:
	var world_name: String = "World%d" % slot_index
	Game.active_world = world_name
	get_tree().change_scene_to_file(_MAIN_SCENE_PATH)


func _on_cancel_pressed() -> void:
	get_tree().change_scene_to_file(_MAIN_MENU_PATH)
