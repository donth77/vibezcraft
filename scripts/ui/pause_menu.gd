extends Control

# Vanilla MC Alpha in-game pause menu (GuiIngameMenu in the Java sources).
# In Alpha singleplayer, pressing ESC opens this screen and also pauses the
# game loop — the menu is NOT drawn over a live simulation, so we flip
# get_tree().paused on open/close. (In multiplayer Alpha the game kept
# running; this clone is singleplayer-only so pause is always in effect.)
#
# Layout & strings follow vanilla's GuiIngameMenu, with two intentional
# divergences: "Quit to Title" instead of "Save and Quit to Title" (we
# don't have persistence yet — relabeling so the button doesn't lie to
# the player) and an extra "Quit to Desktop" row (modern convenience;
# vanilla only exposed desktop-quit from the title screen).
#
# The Options entry is deliberately disabled in-game: the settings we
# expose (texture pack, render distance) only take effect at scene boot
# — flipping them mid-session would require a live atlas rebuild +
# chunk-manager rewire we haven't plumbed. Players reach the settings
# screen from the title instead (MainMenu → Settings). The button stays
# on the pause menu for visual parity with vanilla.
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
	_font = MinecraftFont.get_font()
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
	# Vanilla MC uses a 1 px black drop shadow at native scale, not an outline.
	# Bitmap-font outlines stamp the glyph 8× at offsets which inflates the
	# visual footprint past the label's measured width.
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
	title.add_theme_constant_override("shadow_offset_x", SCALE)
	title.add_theme_constant_override("shadow_offset_y", SCALE)
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
	vbox.add_child(_make_button("Options...", false, _on_open_options))
	vbox.add_child(_make_button("Save and quit to title", false, _on_quit_to_title))
	vbox.add_child(_make_button("Quit to Desktop", false, _on_quit_to_desktop))


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
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
	label.add_theme_constant_override("shadow_offset_x", SCALE)
	label.add_theme_constant_override("shadow_offset_y", SCALE)
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
				SFX.play_click()
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


func _on_open_options() -> void:
	# In-game options is a SEPARATE scene from main-menu Settings — only
	# exposes live-applicable knobs (fps cap). Anything that requires a
	# scene reload (render_distance, clouds) or world regen (seed) stays
	# on the main-menu path where those needs are met naturally.
	var packed: PackedScene = load("res://scenes/ui/in_game_options.tscn") as PackedScene
	if packed == null:
		return
	var overlay: Control = packed.instantiate() as Control
	if overlay == null:
		return
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().get_root().add_child(overlay)
	# Hide the world HUD (crosshair, hotbar, hp, etc.) so it doesn't bleed
	# through the options overlay. The Crosshair CanvasLayer is the root
	# of all gameplay HUD per scenes/ui/crosshair.tscn. Restored in
	# _on_options_closed.
	var hud: CanvasLayer = get_tree().get_root().find_child("Crosshair", true, false) as CanvasLayer
	if hud != null:
		hud.visible = false
	visible = false
	overlay.tree_exited.connect(_on_options_closed.bind(hud))


func _on_options_closed(hud: CanvasLayer) -> void:
	# Fired when the options overlay queue_frees itself. Re-show pause
	# menu + game HUD; tree stays paused.
	visible = true
	if hud != null:
		hud.visible = true


func _on_quit_to_title() -> void:
	# Alpha 1.2.6's "Save and quit to title" (jl.java:12). The pause menu
	# in vanilla iterates chunk-saves over multiple frames while flashing
	# "Saving level.." at the bottom; our save is synchronous and fast,
	# but we still show the indicator for one frame so a slow save (many
	# dirty chunks) doesn't read as a freeze.
	await _save_world_with_indicator()
	Music.stop_music()
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


func _on_quit_to_desktop() -> void:
	# Modern convenience — vanilla Alpha only exposed Quit via the title
	# screen. We save before quitting so closing the game directly from
	# the pause menu doesn't drop the session.
	await _save_world_with_indicator()
	Music.stop_music()
	get_tree().quit()


# Flush the world to disk before changing scenes. Shows a "Saving level..."
# overlay for one frame so a slow save (many dirty chunks) doesn't read
# as a freeze. The overlay paints first (deferred via process_frame),
# THEN the actual save runs, then we return.
#
# Save covers: in-memory region cache → region files, entities.bin,
# player.bin, world.json (refreshes last_played + adds session-delta to
# play_time_seconds). Mirrors the autosave path on ChunkManager but
# triggered manually on quit instead of by the 5-min timer.
func _save_world_with_indicator() -> void:
	var overlay := _make_saving_overlay()
	add_child(overlay)
	# Yield one frame so the overlay paints before the synchronous save
	# locks the main thread. Without this, the overlay is invisible.
	await get_tree().process_frame
	SaveLoad.flush_all_regions()
	var chunk_manager: Node = get_tree().get_root().find_child("ChunkManager", true, false)
	if chunk_manager != null:
		EntitySave.save_all(chunk_manager)
	var player: Node3D = get_tree().get_root().find_child("Player", true, false) as Node3D
	if player != null:
		PlayerSave.save_player(player)
	var meta: Dictionary = WorldMeta.load_meta()
	if meta.is_empty():
		meta = WorldMeta.make_initial(Worldgen.WORLD_SEED, Vector3i(0, 70, 0), WorldTime.tick)
	meta["seed"] = Worldgen.WORLD_SEED
	meta["time_ticks"] = WorldTime.tick
	WorldMeta.save_meta(meta)
	overlay.queue_free()


# CanvasLayer + low-contrast "Saving level..." label, bottom-center.
# Mirrors Alpha jl.java:50's location + low-key styling. We don't
# implement the brightness pulse animation — the overlay flashes for
# only ~1 frame in practice (save is sub-100ms typical) so the pulse
# wouldn't have time to read.
func _make_saving_overlay() -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.layer = 16  # above pause menu (default ~4)
	var label := Label.new()
	label.text = "Saving level..."
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.anchor_left = 0.0
	label.anchor_right = 1.0
	label.anchor_top = 1.0
	label.anchor_bottom = 1.0
	label.offset_top = -32
	label.offset_bottom = -8
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.8))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	layer.add_child(label)
	return layer
