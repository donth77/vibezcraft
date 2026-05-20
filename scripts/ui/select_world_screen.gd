class_name SelectWorldScreen
extends Control

# Steps 7.6 + 7.7 of the save/load plan. Ports Alpha 1.2.6's
# GuiSelectWorld (vendor/alpha-1.2.6-src/src/le.java) + GuiDeleteWorld
# (jh.java) + GuiYesNo confirm (kn.java).
#
# Alpha uses three separate screens (le → jh → kn). We collapse into one
# screen with a delete-mode toggle since we only have 5 slots and the
# extra screen transitions add no information. Plan §3.3 explicitly
# chose this collapse.
#
# Behavior:
#   - Title: "Select world" normally, "Delete world" while in delete mode
#   - 5 slot buttons: in normal mode show "- empty -" or "World N (X.XX MB)"
#     and load/create on click; in delete mode show the same text but
#     clicking opens a confirm dialog ("Are you sure ... will be lost
#     forever!" matching kn.java's message verbatim).
#   - "Delete world..." button enters delete mode (button hides while in
#     delete mode; replaced by "Done" exit).
#   - "Cancel" returns to main menu (also exits delete mode first if
#     active — single button covers both back-out cases).

const _SLOT_COUNT: int = 5
const _MAIN_SCENE_PATH: String = "res://main.tscn"
const _MAIN_MENU_PATH: String = "res://scenes/ui/main_menu.tscn"
const _BG_TINT: Color = Color(0x40 / 255.0, 0x40 / 255.0, 0x40 / 255.0, 1.0)

var _slot_buttons: Array = []  # length _SLOT_COUNT
var _title_label: Label
var _delete_button: VanillaButton
var _done_button: VanillaButton
var _delete_mode: bool = false


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
	_title_label = Label.new()
	_title_label.text = "Select world"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.anchor_left = 0.0
	_title_label.anchor_right = 1.0
	_title_label.anchor_top = 0.05
	_title_label.anchor_bottom = 0.05
	_title_label.offset_bottom = 48
	_title_label.add_theme_font_size_override("font_size", 48)
	_title_label.add_theme_color_override("font_color", Color.WHITE)
	_title_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_title_label.add_theme_constant_override("shadow_offset_x", 6)
	_title_label.add_theme_constant_override("shadow_offset_y", 6)
	add_child(_title_label)


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
	col.anchor_top = 0.78
	col.anchor_bottom = 0.78
	col.offset_left = -400
	col.offset_right = 400
	col.add_theme_constant_override("separation", 16)
	add_child(col)
	_delete_button = VanillaButton.new()
	_delete_button.text = "Delete world..."
	_delete_button.pressed.connect(_enter_delete_mode)
	col.add_child(_delete_button)
	_done_button = VanillaButton.new()
	_done_button.text = "Done"
	_done_button.pressed.connect(_exit_delete_mode)
	_done_button.visible = false
	col.add_child(_done_button)
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


# Either creates the world (if empty) or loads it (if filled) in normal
# mode; in delete mode it opens the confirm dialog. Empty slots in delete
# mode are a no-op (nothing to delete).
func _on_slot_pressed(slot_index: int) -> void:
	if _delete_mode:
		var world_name: String = "World%d" % slot_index
		if not SaveLoad.world_exists(world_name):
			return  # empty slot in delete mode — nothing to delete
		_show_delete_confirm(slot_index)
		return
	var world_name: String = "World%d" % slot_index
	# Sample existence BEFORE _prepare_world_seed — that helper writes
	# world.json for fresh slots, which would flip world_exists to true
	# and confuse the LoadingScreen's "fresh vs loaded" message picker.
	Game.world_is_fresh = not SaveLoad.world_exists(world_name)
	Game.active_world = world_name
	_prepare_world_seed(world_name)
	get_tree().change_scene_to_file(_MAIN_SCENE_PATH)


# Ensure the worldgen seed matches this slot's saved seed BEFORE main.tscn
# spawns ChunkManager. Without this, every slot would use whatever seed
# settings.cfg had (a global) — picking World3 would generate the same
# terrain as World1. Two cases:
#   - Existing world: read world.json, apply its seed.
#   - Fresh slot:     roll a random seed, write a new world.json with it,
#                     then apply. The world.json gets the rest of its
#                     fields (spawn, time, timestamps) filled by
#                     ChunkManager's first autosave.
func _prepare_world_seed(world_name: String) -> void:
	var meta: Dictionary = WorldMeta.load_meta(world_name)
	if meta.is_empty():
		randomize()
		var fresh_seed: int = randi_range(1, 0x7FFFFFFF)
		meta = WorldMeta.make_initial(fresh_seed, Vector3i(0, 70, 0), 6000)
		WorldMeta.save_meta(meta, world_name)
	Worldgen.apply_world_seed(int(meta.get("seed", Worldgen.WORLD_SEED)))


func _on_cancel_pressed() -> void:
	# Cancel does double duty: exits delete mode if active, otherwise
	# bounces back to the main menu. Matches le.java's single-button
	# Cancel behavior.
	if _delete_mode:
		_exit_delete_mode()
		return
	get_tree().change_scene_to_file(_MAIN_MENU_PATH)


# --- Delete mode (step 7.7) ---


func _enter_delete_mode() -> void:
	_delete_mode = true
	_title_label.text = "Delete world"
	_delete_button.visible = false
	_done_button.visible = true


func _exit_delete_mode() -> void:
	_delete_mode = false
	_title_label.text = "Select world"
	_delete_button.visible = true
	_done_button.visible = false


# Confirm dialog matching kn.java's GuiYesNo: question on top, body text
# below, Yes / Cancel buttons. Uses Godot's built-in ConfirmationDialog
# so we don't reinvent modal layout / focus capture; styled to match
# the rest of the menus via theme font overrides.
func _show_delete_confirm(slot_index: int) -> void:
	var world_name: String = "World%d" % slot_index
	var dialog := ConfirmationDialog.new()
	dialog.title = "Delete world"
	dialog.dialog_text = (
		"Are you sure you want to delete this world?\n'%s' will be lost forever!" % world_name
	)
	dialog.get_ok_button().text = "Yes"
	dialog.get_cancel_button().text = "Cancel"
	dialog.confirmed.connect(_on_delete_confirmed.bind(slot_index, dialog))
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


# Yes pressed — wipe the world directory (region files, player.bin,
# entities.bin, world.json all go) and refresh the slot list so the row
# flips back to "- empty -". Exits delete mode afterward to keep the
# user from accidentally deleting another world on a stray click.
func _on_delete_confirmed(slot_index: int, dialog: ConfirmationDialog) -> void:
	var world_name: String = "World%d" % slot_index
	SaveLoad.delete_world(world_name)
	# Refresh just the affected slot label rather than rebuilding the
	# whole vbox.
	if slot_index - 1 < _slot_buttons.size():
		var btn: VanillaButton = _slot_buttons[slot_index - 1]
		if btn != null:
			btn.text = _slot_label(slot_index)
	dialog.queue_free()
	_exit_delete_mode()
