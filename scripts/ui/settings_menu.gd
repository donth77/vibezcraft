class_name SettingsMenu
extends Control

# Settings screen — modern dropdown + Save/Cancel UX. Intentionally
# diverges from vanilla Alpha's GuiOptions (bf.java) cycle buttons
# because those were clunky; we want a friendly PC-games UX.
#
# Covers both flows:
#   - Main menu → Options: dirt-tile bg, Save/Cancel scene-swap back.
#   - Pause menu → Options (overlay mode): dim bg over paused world;
#     Save/Cancel queue_free self and the pause menu resumes.
#
# Six settings in a single vertical column with labels, each a dropdown:
#   Render distance | Texture pack | Clouds | Frame rate cap | VSync | Seed
#
# Seed gets a separate "New Seed" button to re-roll rather than cycling
# dropdown values (random 32-bit int; 0 = sentinel for "random each launch").

const _SETTINGS_PATH: String = "user://settings.cfg"
const _MAIN_MENU_PATH: String = "res://scenes/ui/main_menu.tscn"
const _BG_TINT: Color = Color(0x40 / 255.0, 0x40 / 255.0, 0x40 / 255.0, 1.0)

# Vanilla Alpha render-distance values (gq.java:16 + kb.java:195): 2/4/8/16
# = TINY/SHORT/NORMAL/FAR.
const _RENDER_DISTANCES: Array[int] = [2, 4, 8, 16]
const _RENDER_DISTANCE_LABELS: Array[String] = ["Tiny", "Short", "Normal", "Far"]
const _PACKS: Array[String] = ["alpha_vanilla", "pixel_perfection", "programmer_art"]
const _CLOUD_QUALITY_LABELS: Array[String] = ["Off", "Fast", "Fancy"]
const _FPS_CAPS: Array[int] = [0, 60, 90, 120, 144]
const _FPS_CAP_LABELS: Array[String] = ["Uncapped", "60", "90", "120", "144"]
# Resolution dropdown. Stored as "WxH" or "fullscreen" in settings.cfg so the
# string round-trips cleanly with the MC_CLONE_RESOLUTION env-var format
# (Game._apply_resolution_override). Env still wins at boot for one-off
# overrides; cfg is what the settings UI persists.
const _RESOLUTION_VALUES: Array[String] = [
	"1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160", "fullscreen"
]
const _RESOLUTION_LABELS: Array[String] = [
	"1280×720", "1600×900", "1920×1080", "2560×1440", "3840×2160 (4K)", "Fullscreen"
]
# VSync is exposed as a simple on/off checkbox — the Adaptive/Mailbox
# modes are power-user territory that added UI complexity for no 95%-
# case benefit. Advanced users can set graphics.vsync directly in
# user://settings.cfg. Default = off so fps_cap is the real ceiling
# (Godot's native ENABLED default would clamp to display refresh and
# silently override the cap).

var _music_slider: HSlider
var _music_label: Label
var _resolution_option: OptionButton
# Active option list — usually == _RESOLUTION_VALUES, but drops "fullscreen"
# when running in the editor's embedded play window (DisplayServer rejects
# the mode change). Built in `_build_panel`, read by load / save.
var _active_resolution_values: Array[String]
var _distance_option: OptionButton
var _pack_option: OptionButton
var _cloud_option: OptionButton
var _fps_option: OptionButton
var _vsync_checkbox: CheckBox
var _fog_checkbox: CheckBox
var _sfx_checkbox: CheckBox
# Pack-conditional row — visible only when the texture pack dropdown
# is set to alpha_vanilla. The label + checkbox both hide/show as a pair.
var _vintage_foliage_row: HBoxContainer
var _vintage_foliage_checkbox: CheckBox
var _seed_label: Label
var _pending_seed: int = 0
# Overlay mode: Done-equivalents (Save/Cancel) queue_free instead of
# scene-swapping to main menu. pause_menu sets this via set_overlay_mode.
var _overlay_mode: bool = false


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_background()
	_build_panel()
	_load_settings()


func _build_background() -> void:
	if _overlay_mode:
		var dim := ColorRect.new()
		dim.color = Color(0, 0, 0, 0.55)
		dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		dim.mouse_filter = Control.MOUSE_FILTER_STOP
		add_child(dim)
		return
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


func _build_panel() -> void:
	var title := Label.new()
	title.text = "Settings"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = 0.0
	title.anchor_right = 1.0
	title.anchor_top = 0.03
	title.anchor_bottom = 0.03
	title.offset_bottom = 48
	title.add_theme_font_size_override("font_size", 48)
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_shadow_color", Color.BLACK)
	# Bitmap font is 8 px native; shadow offset of font_size/8 = one source
	# pixel keeps the drop-shadow aligned to the glyph grid (vanilla MC's
	# 1-px drop-shadow). Non-multiple offsets render at sub-pixel positions
	# which read as soft / blurry against the crisp glyph pixels.
	title.add_theme_constant_override("shadow_offset_x", 6)
	title.add_theme_constant_override("shadow_offset_y", 6)
	add_child(title)

	var vbox := VBoxContainer.new()
	vbox.anchor_left = 0.5
	vbox.anchor_right = 0.5
	vbox.anchor_top = 0.03
	vbox.anchor_bottom = 0.03
	vbox.offset_left = -360
	vbox.offset_right = 360
	# 60 px below the title's anchor. Was 88 before the "Controls..." button
	# added a third row to button_col (+96 px); shifted vbox up to recover
	# the bottom-edge margin at 1080p (without this, button_col bottom
	# landed at y=1098 — off-screen).
	vbox.offset_top = 60
	# 11 rows × 60 px + 10 × 10 separation = 760 px. Bumped from 690 to
	# reserve space for the conditional Alpha-1.1.2-foliage row (visible
	# only when the pack dropdown is on alpha_vanilla). When hidden, the
	# bottom 70 px just reads as extra breathing room — acceptable
	# tradeoff for not having to reflow button_col on every pack change.
	vbox.offset_bottom = 60 + 760
	vbox.add_theme_constant_override("separation", 10)
	add_child(vbox)

	_add_music_row(vbox)
	_sfx_checkbox = _add_checkbox_row(vbox, "Sound effects")
	# Drop the "Fullscreen" entry when embedded — DisplayServer.window_set_mode
	# is rejected ("Embedded window can't be resized."), so offering it would
	# just dead-end the user. Other sizes stay visible (apply_resolution_value
	# silently no-ops them too, but at least they're not actively broken-looking).
	_active_resolution_values = _RESOLUTION_VALUES.duplicate()
	var labels: Array[String] = _RESOLUTION_LABELS.duplicate()
	if _window_is_embedded():
		var fs_idx: int = _active_resolution_values.find("fullscreen")
		if fs_idx >= 0:
			_active_resolution_values.remove_at(fs_idx)
			labels.remove_at(fs_idx)
	_resolution_option = _add_option_row(vbox, "Resolution", labels)
	var dist_labels: Array = []
	for i in range(_RENDER_DISTANCES.size()):
		dist_labels.append("%s (%d)" % [_RENDER_DISTANCE_LABELS[i], _RENDER_DISTANCES[i]])
	_distance_option = _add_option_row(vbox, "Render distance", dist_labels)
	_pack_option = _add_option_row(vbox, "Texture pack", _PACKS)
	# Pack-conditional toggle. The label is intentionally specific to the
	# era — when more pack-scoped era flags ship later, each gets its own
	# row rather than a generic "vintage" umbrella so persisted cfg keys
	# stay stable. Visibility is wired through _on_pack_selected below.
	_vintage_foliage_checkbox = _add_checkbox_row(vbox, "Alpha 1.1.2 foliage")
	_vintage_foliage_row = _vintage_foliage_checkbox.get_parent() as HBoxContainer
	_pack_option.item_selected.connect(_on_pack_selected)
	_cloud_option = _add_option_row(vbox, "Clouds", _CLOUD_QUALITY_LABELS)
	_fps_option = _add_option_row(vbox, "Frame rate cap", _FPS_CAP_LABELS)
	_vsync_checkbox = _add_checkbox_row(vbox, "VSync")
	_fog_checkbox = _add_checkbox_row(vbox, "Fog")
	_add_seed_row(vbox)

	var button_col := VBoxContainer.new()
	button_col.anchor_left = 0.5
	button_col.anchor_right = 0.5
	button_col.anchor_top = 0.03
	button_col.anchor_bottom = 0.03
	button_col.offset_left = -400
	button_col.offset_right = 400
	# 766 = vbox bottom (750) + 16 px breathing gap. 3 × 80 px buttons +
	# 2 × 16 px separation = 272 px, so bottom lands at y=1038 — fits the
	# 1080p viewport with ~40 px margin to spare.
	button_col.offset_top = 766
	button_col.offset_bottom = 766 + 272
	button_col.add_theme_constant_override("separation", 16)
	button_col.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(button_col)
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
	lbl.custom_minimum_size = Vector2(0, 60)
	row.add_child(lbl)

	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(360, 60)
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
	# Vanilla MC plays random.click on every option-cycle. OptionButton's
	# item_selected signal fires when the user picks a value from the popup;
	# pressed fires when the dropdown is opened. Wire both for full UI feedback.
	opt.item_selected.connect(func(_idx: int) -> void: SFX.play_click())
	opt.pressed.connect(SFX.play_click)
	row.add_child(opt)
	_style_popup(opt.get_popup())
	return opt


# Binary on/off setting row — same Label layout as dropdowns but with
# a CheckBox on the right instead of an OptionButton. Scaled up to match
# the dropdown row height so the whole form stays visually aligned.
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
	lbl.custom_minimum_size = Vector2(0, 60)
	row.add_child(lbl)

	# CheckBox right-aligned in the same 360-wide slot the dropdowns use
	# so the column stays visually aligned. Text shows "On" / "Off" next
	# to the tick so the state is unambiguous at a glance.
	var cb := CheckBox.new()
	cb.custom_minimum_size = Vector2(360, 60)
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


func _add_seed_row(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = "World seed"
	lbl.add_theme_font_size_override("font_size", 32)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_shadow_color", Color.BLACK)
	lbl.add_theme_constant_override("shadow_offset_x", 4)
	lbl.add_theme_constant_override("shadow_offset_y", 4)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.custom_minimum_size = Vector2(0, 60)
	row.add_child(lbl)

	_seed_label = Label.new()
	_seed_label.text = "(random)"
	_seed_label.add_theme_font_size_override("font_size", 24)
	_seed_label.add_theme_color_override("font_color", Color.WHITE)
	_seed_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_seed_label.add_theme_constant_override("shadow_offset_x", 3)
	_seed_label.add_theme_constant_override("shadow_offset_y", 3)
	_seed_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_seed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_seed_label.custom_minimum_size = Vector2(200, 60)
	row.add_child(_seed_label)

	var new_seed_btn := VanillaButton.new()
	new_seed_btn.text = "New Seed"
	new_seed_btn.pressed.connect(_on_new_seed_pressed)
	new_seed_btn.custom_minimum_size = Vector2(280, 60)
	row.add_child(new_seed_btn)


func _on_new_seed_pressed() -> void:
	# Preview a new random seed. Not persisted until Save — player can
	# re-roll or Cancel without mutating the stored seed.
	randomize()
	_pending_seed = randi_range(1, 0x7FFFFFFF)
	if _seed_label != null:
		_seed_label.text = str(_pending_seed)


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
	lbl.custom_minimum_size = Vector2(0, 60)
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
	_music_label.custom_minimum_size = Vector2(80, 60)
	row.add_child(_music_label)

	_music_slider = HSlider.new()
	_music_slider.min_value = 0.0
	_music_slider.max_value = 1.0
	_music_slider.step = 0.01
	_music_slider.value = 1.0
	_music_slider.custom_minimum_size = Vector2(260, 60)
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


# --- Load / save / apply / close ---


static func load_config() -> ConfigFile:
	var cfg := ConfigFile.new()
	var err := cfg.load(_SETTINGS_PATH)
	if err != OK:
		cfg.set_value("graphics", "render_distance", 8)
		cfg.set_value("graphics", "texture_pack", BlockAtlas.active_pack)
		cfg.set_value("graphics", "cloud_quality", Game.CLOUD_QUALITY_FANCY)
		cfg.set_value("graphics", "fps_cap", 90)
		cfg.set_value("graphics", "vsync", DisplayServer.VSYNC_DISABLED)
		cfg.set_value("graphics", "fog_enabled", true)
		cfg.set_value("audio", "sfx_enabled", true)
	return cfg


static func apply_config(cfg: ConfigFile) -> void:
	var pack: String = cfg.get_value("graphics", "texture_pack", BlockAtlas.active_pack)
	if pack != BlockAtlas.active_pack:
		BlockAtlas.active_pack = pack
		BlockAtlas.reset()
		BlockAtlas.build()
	# cloud_quality + render_distance take effect on next scene load.
	Game.cloud_quality = int(cfg.get_value("graphics", "cloud_quality", Game.cloud_quality))
	Engine.max_fps = int(cfg.get_value("graphics", "fps_cap", 90))
	DisplayServer.window_set_vsync_mode(
		int(cfg.get_value("graphics", "vsync", DisplayServer.VSYNC_DISABLED))
	)
	var resolution: String = cfg.get_value("graphics", "resolution", "")
	if resolution != "":
		apply_resolution_value(resolution)
	Game.fog_enabled = bool(cfg.get_value("graphics", "fog_enabled", true))
	# Route through the setter so the signal fires + chunks/materials live-
	# update without a relog (only matters when value actually changed).
	Game.set_alpha_vintage_foliage(bool(cfg.get_value("graphics", "alpha_vintage_foliage", false)))
	Game.sfx_enabled = bool(cfg.get_value("audio", "sfx_enabled", true))
	var music_vol: float = float(cfg.get_value("audio", "music_volume", 0.25))
	if Music != null:
		Music.set_volume(music_vol)


# Apply a resolution string ("WxH" or "fullscreen") to the live window.
# Shared by Game._ready (boot-time cfg load) and _on_save_pressed (live
# apply). Skipped in headless mode and when the game is running in the
# editor's embedded play window — Godot prints "Embedded window can't
# be resized." and the resize is rejected, so we no-op cleanly instead
# of triggering the warning. Run from terminal (godot --path . main.tscn)
# or unset Editor → Run → Window Placement → "Embed Subwindows" to use
# Fullscreen / custom sizes.
static func apply_resolution_value(value: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	# Embedded play silently skips: DisplayServer rejects the call, the
	# Fullscreen dropdown entry is already hidden in this mode, and the
	# user can't meaningfully test the change without leaving embedded.
	# A warning here just noisies the console on every Save / boot.
	if _window_is_embedded():
		return
	if value.to_lower() == "fullscreen":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	# Toggling fullscreen → windowed first; otherwise window_set_size is a
	# no-op while the window is still fullscreen.
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	var parts: PackedStringArray = value.to_lower().split("x")
	if parts.size() != 2:
		return
	var w: int = int(parts[0])
	var h: int = int(parts[1])
	if w < 320 or h < 240:
		return
	DisplayServer.window_set_size(Vector2i(w, h))
	var screen_size: Vector2i = DisplayServer.screen_get_size()
	var window_size: Vector2i = DisplayServer.window_get_size()
	DisplayServer.window_set_position((screen_size - window_size) / 2)


# True when the game is running under the Godot editor (the common case
# where the play window is embedded and DisplayServer resize / mode calls
# are rejected with "Embedded window can't be resized."). Exported builds
# return false. Heuristic, not a direct embedded-check — there's no clean
# API for that across Godot 4.x versions — but it's safe: editor users
# always have the option to run from terminal or disable Embed Subwindows
# in Editor → Settings → Run → Window Placement.
static func _window_is_embedded() -> bool:
	return OS.has_feature("editor")


func _load_settings() -> void:
	var cfg := load_config()
	var dist: int = int(cfg.get_value("graphics", "render_distance", 8))
	var pack: String = cfg.get_value("graphics", "texture_pack", BlockAtlas.active_pack)
	var clouds: int = int(cfg.get_value("graphics", "cloud_quality", Game.CLOUD_QUALITY_FANCY))
	var fps_cap: int = int(cfg.get_value("graphics", "fps_cap", 90))
	var vsync_mode: int = int(cfg.get_value("graphics", "vsync", DisplayServer.VSYNC_DISABLED))
	# Default selection mirrors the project.godot 1920×1080 window size so
	# first-launch users see their actual current resolution preselected.
	var resolution: String = cfg.get_value("graphics", "resolution", "1920x1080")
	_distance_option.selected = maxi(_RENDER_DISTANCES.find(dist), 0)
	_pack_option.selected = maxi(_PACKS.find(pack), 0)
	_cloud_option.selected = clamp(clouds, 0, _CLOUD_QUALITY_LABELS.size() - 1)
	_fps_option.selected = maxi(_FPS_CAPS.find(fps_cap), 0)
	# Look up against the filtered list — when fullscreen was previously
	# saved but we're now embedded (so it's not in the dropdown), find()
	# returns -1 → clamp to 0 (first available size).
	_resolution_option.selected = maxi(_active_resolution_values.find(resolution.to_lower()), 0)
	# Treat anything non-DISABLED as "on" — if the user had Adaptive or
	# Mailbox saved before this UI simplified, flipping the checkbox to
	# On preserves the gist; manual editing of settings.cfg can restore
	# those modes if they really want them.
	_vsync_checkbox.button_pressed = vsync_mode != DisplayServer.VSYNC_DISABLED
	_vsync_checkbox.text = "On" if _vsync_checkbox.button_pressed else "Off"
	var fog_on: bool = bool(cfg.get_value("graphics", "fog_enabled", true))
	_fog_checkbox.button_pressed = fog_on
	_fog_checkbox.text = "On" if fog_on else "Off"
	var sfx_on: bool = bool(cfg.get_value("audio", "sfx_enabled", true))
	_sfx_checkbox.button_pressed = sfx_on
	_sfx_checkbox.text = "On" if sfx_on else "Off"
	var music_vol: float = float(cfg.get_value("audio", "music_volume", 0.25))
	_music_slider.value = music_vol
	_on_music_slider_changed(music_vol)
	_pending_seed = int(cfg.get_value("world", "seed", 0))
	if _seed_label != null:
		_seed_label.text = str(_pending_seed) if _pending_seed != 0 else "(random)"
	var vintage_on: bool = bool(cfg.get_value("graphics", "alpha_vintage_foliage", false))
	_vintage_foliage_checkbox.button_pressed = vintage_on
	_vintage_foliage_checkbox.text = "On" if vintage_on else "Off"
	_refresh_vintage_foliage_visibility(pack)


# Show/hide the vintage-foliage row whenever the pack dropdown changes.
# Calibrated values are alpha_vanilla-specific (grayscale grass_top), so
# pre-tinted packs (pixel_perfection, programmer_art) would land wrong.
func _on_pack_selected(idx: int) -> void:
	_refresh_vintage_foliage_visibility(_PACKS[idx])


func _refresh_vintage_foliage_visibility(pack: String) -> void:
	if _vintage_foliage_row == null:
		return
	_vintage_foliage_row.visible = pack == "alpha_vanilla"


func _on_save_pressed() -> void:
	var cfg := ConfigFile.new()
	cfg.load(_SETTINGS_PATH)
	cfg.set_value("graphics", "render_distance", _RENDER_DISTANCES[_distance_option.selected])
	cfg.set_value("graphics", "texture_pack", _PACKS[_pack_option.selected])
	cfg.set_value("graphics", "cloud_quality", _cloud_option.selected)
	cfg.set_value("graphics", "fps_cap", _FPS_CAPS[_fps_option.selected])
	cfg.set_value("graphics", "resolution", _active_resolution_values[_resolution_option.selected])
	var vsync_value: int = (
		DisplayServer.VSYNC_ENABLED
		if _vsync_checkbox.button_pressed
		else DisplayServer.VSYNC_DISABLED
	)
	cfg.set_value("graphics", "vsync", vsync_value)
	cfg.set_value("graphics", "fog_enabled", _fog_checkbox.button_pressed)
	cfg.set_value("graphics", "alpha_vintage_foliage", _vintage_foliage_checkbox.button_pressed)
	cfg.set_value("audio", "sfx_enabled", _sfx_checkbox.button_pressed)
	cfg.set_value("audio", "music_volume", _music_slider.value)
	if _pending_seed != 0:
		cfg.set_value("world", "seed", _pending_seed)
	cfg.save(_SETTINGS_PATH)
	apply_config(cfg)
	_close()


func _on_cancel_pressed() -> void:
	_close()


# Open the controls rebinding screen. Hide this screen while controls is
# open. Overlay lives on the scene root, NOT as our child — hiding self
# would otherwise hide the overlay too (Godot propagates visible=false
# to descendants) and the user would be stuck in an invisible modal.
func _on_controls_pressed() -> void:
	var packed: PackedScene = load("res://scenes/ui/controls_menu.tscn") as PackedScene
	if packed == null:
		return
	var overlay: Control = packed.instantiate() as Control
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	# Main-menu Settings flow paints the dirt-tile bg. In overlay mode
	# (in-game pause) the paused world behind reads as enough context;
	# the default semi-transparent dim is correct there.
	if not _overlay_mode and overlay.has_method("set_dirt_background_mode"):
		overlay.call("set_dirt_background_mode", true)
	visible = false
	overlay.tree_exited.connect(func() -> void: visible = true)
	get_tree().get_root().add_child(overlay)


func _close() -> void:
	if _overlay_mode:
		queue_free()
	else:
		get_tree().change_scene_to_file(_MAIN_MENU_PATH)


func set_overlay_mode(enabled: bool) -> void:
	_overlay_mode = enabled
