extends Control

# Vanilla MC Alpha in-game pause menu (GuiIngameMenu in the Java sources).
# In Alpha singleplayer, pressing ESC opens this screen and also pauses the
# game loop — the menu is NOT drawn over a live simulation, so we flip
# get_tree().paused on open/close. (In multiplayer Alpha the game kept
# running; this clone is singleplayer-only so pause is always in effect.)
#
# Layout & strings match GuiIngameMenu: title "Game menu", three 200×20
# buttons centered vertically: "Back to Game", "Options...", "Save and Quit
# to Title". Options is disabled until we have an options screen; Save and
# Quit calls get_tree().quit() — the world-save hook will land in phase 5.
#
# Button visuals come from the vanilla widgets.png (three 200×20 rows at
# y=46/66/86 for disabled/normal/hover). We draw the sprite through a
# NinePatchRect so the 2px beveled corners slice correctly, and apply a
# uniform `scale` so the corners upscale with the rest of the button —
# vanilla MC's pixel-art look at a modern resolution.

const WIDGETS_PATH: String = "res://assets/textures/gui/widgets.png"
const FONT_PATH: String = "res://assets/fonts/Minecraft.otf"

# 4× upscale matches the hotbar. At SCALE=3 the Minecraft.otf glyphs were
# too thin to read against the dimmed world; SCALE=4 gives ~40pt button
# labels and ~48pt title without overflowing the viewport vertically.
const SCALE: int = 4
const BTN_NATIVE_W: int = 200
const BTN_NATIVE_H: int = 20
const BTN_W: int = BTN_NATIVE_W * SCALE
const BTN_H: int = BTN_NATIVE_H * SCALE
const BTN_SPACING: int = 4 * SCALE  # gap between buttons, vanilla 4px native

# Button texture regions in widgets.png. Verified by pixel-inspection:
# row borders are solid black at y=46/66/86 and y=65/85/105.
const BTN_REGION_DISABLED: Rect2 = Rect2(0, 46, BTN_NATIVE_W, BTN_NATIVE_H)
const BTN_REGION_NORMAL: Rect2 = Rect2(0, 66, BTN_NATIVE_W, BTN_NATIVE_H)
const BTN_REGION_HOVER: Rect2 = Rect2(0, 86, BTN_NATIVE_W, BTN_NATIVE_H)

# Vanilla GuiIngameMenu colors: white text with black drop-shadow, yellow
# tint on hover, grey on disabled. Hex values from the Java client.
const _TEXT_NORMAL: Color = Color8(224, 224, 224)
const _TEXT_HOVER: Color = Color8(255, 255, 160)
const _TEXT_DISABLED: Color = Color8(160, 160, 160)

var _font: FontFile
var _widgets: Texture2D


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# PROCESS_MODE_ALWAYS lets our _input() fire even after we pause the tree —
	# without it, we couldn't close the menu with ESC.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = load(FONT_PATH) as FontFile
	_widgets = load(WIDGETS_PATH) as Texture2D
	_build_ui()


func _build_ui() -> void:
	# Semi-transparent dark overlay on top of the frozen game view —
	# matches vanilla's ingame pause (no dirt tile; that's the title screen).
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# CenterContainer auto-centers its single child (the VBox) within the full
	# viewport rect, regardless of viewport size — same pattern the inventory
	# screen uses. Anchoring the VBox directly with PRESET_CENTER places its
	# top-left at the center instead of the VBox itself, so the menu drifts
	# down-and-right of center.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", BTN_SPACING)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Game menu"
	title.add_theme_font_override("font", _font)
	title.add_theme_font_size_override("font_size", 12 * SCALE)
	title.add_theme_color_override("font_color", _TEXT_NORMAL)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	title.add_theme_constant_override("outline_size", 4)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.custom_minimum_size = Vector2(BTN_W, 0)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(title)

	# Spacer — vanilla places the first button 40px below the title.
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(BTN_W, 12 * SCALE)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(gap)

	vbox.add_child(_make_button("Back to Game", false, _on_resume))
	# "Options..." stays disabled until phase 7's settings screen lands.
	vbox.add_child(_make_button("Options...", true, Callable()))
	vbox.add_child(_make_button("Save and Quit to Title", false, _on_quit))


func _make_button(label_text: String, disabled: bool, on_click: Callable) -> Control:
	# Root is a plain Control sized to the final rendered button. Child
	# NinePatchRect is scaled up uniformly so the 2px beveled corners grow
	# with the rest — vanilla MC's pixel-art look at SCALE:1.
	var root := Control.new()
	root.custom_minimum_size = Vector2(BTN_W, BTN_H)
	root.mouse_filter = (Control.MOUSE_FILTER_IGNORE if disabled else Control.MOUSE_FILTER_STOP)

	var npr := NinePatchRect.new()
	npr.texture = _widgets
	npr.region_rect = BTN_REGION_NORMAL if not disabled else BTN_REGION_DISABLED
	# 2px 9-slice margins (3px bottom to preserve vanilla's extra shadow pixel).
	npr.patch_margin_left = 2
	npr.patch_margin_right = 2
	npr.patch_margin_top = 2
	npr.patch_margin_bottom = 3
	npr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	npr.size = Vector2(BTN_NATIVE_W, BTN_NATIVE_H)
	npr.scale = Vector2(SCALE, SCALE)
	npr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(npr)

	var label := Label.new()
	label.text = label_text
	label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", 10 * SCALE)
	label.add_theme_color_override("font_color", _TEXT_DISABLED if disabled else _TEXT_NORMAL)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	label.add_theme_constant_override("outline_size", 4)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(label)

	if disabled:
		return root

	# Hover: swap to the blue-highlight row + tint the label yellow. Restored
	# on exit. Click fires the callback on release — vanilla MC behavior.
	root.mouse_entered.connect(
		func() -> void:
			npr.region_rect = BTN_REGION_HOVER
			label.add_theme_color_override("font_color", _TEXT_HOVER)
	)
	root.mouse_exited.connect(
		func() -> void:
			npr.region_rect = BTN_REGION_NORMAL
			label.add_theme_color_override("font_color", _TEXT_NORMAL)
	)
	root.gui_input.connect(
		func(event: InputEvent) -> void:
			if (
				event is InputEventMouseButton
				and event.button_index == MOUSE_BUTTON_LEFT
				and not event.pressed
			):
				on_click.call()
	)
	return root


# --- Open / close ---


func open() -> void:
	if visible:
		return
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = true


func close() -> void:
	if not visible:
		return
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_open() -> bool:
	return visible


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("pause"):
		close()
		get_viewport().set_input_as_handled()


# --- Button callbacks ---


func _on_resume() -> void:
	close()


func _on_quit() -> void:
	# Vanilla Alpha saves the world then returns to the title screen. Our
	# save system lands in phase 5 and we have no title; quitting the app
	# is the closest equivalent. Revisit once save/load is wired up.
	get_tree().quit()
