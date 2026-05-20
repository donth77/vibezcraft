extends Control

# Pre-game title screen. Visual language ported from vanilla Alpha 1.2.6's
# GuiMainMenu (vendor/alpha-1.2.6-src/src/dj.java):
#
#   - Tiled dirt background tinted 0x404040, exactly matching the loading
#     screen's hu.java treatment. (The 3D spinning-stone-block wordmark
#     from dj.a(float) is too much work to port — we render a pixel-art
#     wordmark instead, which is the look Mojang used in Beta 1.5+ anyway.)
#   - Wordmark centered around y = d/4.
#   - Yellow splash line ("splashes.txt" ≈ dj:19), rotated -20°, pulsing
#     scale 1.8 − sin(t·2π)·0.1. Text color 0xFFFF00. Rendered behind the
#     wordmark corner offset (+90, +70 from wordmark centre in vanilla —
#     we preserve that relationship).
#   - Button column: 200×20 each in GUI-scale-1 space (400×40 at our 2×),
#     starting at d/4 + 48 with 24-px gaps. Text 0xE0E0E0 / 0xFFFFA0 hover
#     per gh.java. VanillaButton encapsulates all of that.
#   - Top-left version label in 0x505050 at (2,2) — per dj.java:106.
#   - Bottom-right copyright line — per dj.java:107–108 (we replace the
#     Mojang string with a clone disclaimer for legal hygiene; color +
#     alignment + position all match).

const _BG_TINT: Color = Color(0x40 / 255.0, 0x40 / 255.0, 0x40 / 255.0, 1.0)
const _MAIN_SCENE_PATH: String = "res://main.tscn"
const _SETTINGS_SCENE_PATH: String = "res://scenes/ui/settings_menu.tscn"
# Vanilla renders the version text in 0x505050 on a brighter-tinted
# backdrop, which we can't quite reproduce over our 0x404040 dirt tile
# without the text vanishing. Brightened to 0xC0C0C0 + black outline so
# it reads cleanly at any zoom level. Matches the footer's treatment
# so the two corners feel of-a-piece.
const _VERSION_COLOR: Color = Color(0xC0 / 255.0, 0xC0 / 255.0, 0xC0 / 255.0)
const _SPLASH_COLOR: Color = Color(1.0, 1.0, 0.0)  # 0xFFFF00 yellow
const _SPLASHES: Array[String] = [
	"So 2010!",
	"Blocks to the face!",
	"Best in class!",
	"Limited edition!",
	"Indie!",
	"100% fat free!",
	"Open source!",
	"Ask your doctor!",
	"Yaaay!",
	"Sensational!",
	"Hardcore!",
	"Awesome!",
	"It's here!",
	"Best game ever!",
	"Open world!",
	"Voxel-based!",
	"Try the mustard!",
	"Made in Godot!",
	"Vibes!",
]

var _splash_label: Label
var _splash_base_pos: Vector2
var _splash_time: float = 0.0


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	# Reset mouse capture — when the player quits to main menu from in-game
	# (player.gd captures the cursor during gameplay), the captured state
	# survives the scene change unless we explicitly release it here.
	#
	# Direct VISIBLE only — do NOT toggle through HIDDEN first. On macOS
	# the OS-cursor-show happens lazily after a HIDDEN→VISIBLE transition
	# and can leave the pointer invisible until the user clicks. Forcing
	# CURSOR_ARROW guarantees the OS draws an actual pointer over the
	# title screen on the first rendered frame.
	#
	# Avoid both `Input.set_custom_mouse_cursor(null)` AND
	# `DisplayServer.cursor_set_shape(...)` on macOS — both bottom out in
	# display_server_macos.mm:3052 where Godot tries to grab a NSBitmapImageRep
	# from the system cursor and the array is empty, logging
	# "Parameter 'imgrep' is null." ERROR every time. The Control's
	# mouse_default_cursor_shape + Input.mouse_mode = VISIBLE are enough to
	# show the pointer without hitting that path.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	call_deferred("_force_cursor_visible")
	mouse_filter = Control.MOUSE_FILTER_PASS
	_build_background()
	_build_wordmark()
	_build_splash()
	_build_buttons()
	_build_version_label()
	_build_footer_label()


func _force_cursor_visible() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	# Re-assert VISIBLE while the main menu is active. The cost is one
	# Input.mouse_mode write per frame (cheap) in exchange for a
	# guaranteed-visible cursor no matter what tried to capture it.
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _splash_label == null:
		return
	_splash_time += delta
	# Vanilla: scale = 1.8 - |sin(t·2π)|·0.1 ... then divided so text fits
	# in a 100-px corner box. We reproduce the pulse at a ~1 Hz rate.
	var pulse: float = 1.0 + 0.08 * sin(_splash_time * TAU)
	_splash_label.scale = Vector2(pulse, pulse)


func _build_background() -> void:
	var bg := TextureRect.new()
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.stretch_mode = TextureRect.STRETCH_TILE
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	bg.modulate = _BG_TINT
	# Vanilla draws each dirt tile at ~32 px / GUI-scale-1 (hu.java's
	# `f2 = 32.0f`). At our 3×–4× scale that's a 96–128-px tile; the 4×
	# upscale of the 16-px source lands at 64 px tiling, visibly close
	# to vanilla's density instead of the 16-px micro-tile we had.
	var dirt: Texture2D = VanillaButton.make_scaled_dirt_texture(4)
	if dirt != null:
		bg.texture = dirt
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)


# Pixel-art wordmark loaded from assets/textures/gui/logo.png. Sized to the
# same ~180 px vertical envelope the old text wordmark occupied (logo is
# 920×239 native → ~3× scale to ~690×180 on screen). Nearest-neighbor
# filter preserves the crisp pixel edges of the source art.
func _build_wordmark() -> void:
	var logo := TextureRect.new()
	var tex: Texture2D = load("res://assets/textures/gui/logo.png") as Texture2D
	if tex == null:
		return
	logo.texture = tex
	logo.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.anchor_left = 0.0
	logo.anchor_right = 1.0
	logo.anchor_top = 0.08
	logo.anchor_bottom = 0.08
	logo.offset_top = 0
	logo.offset_bottom = 240
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(logo)


# Yellow pulsing "splash" text — dj.java:101 rotates -20° and pulses scale.
# We pin it just off the upper-right corner of the wordmark to mirror
# vanilla's (c/2 + 90, 70) offset relative to centre.
func _build_splash() -> void:
	_splash_label = Label.new()
	_splash_label.text = _SPLASHES[randi() % _SPLASHES.size()]
	_splash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_splash_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_splash_label.anchor_left = 0.5
	_splash_label.anchor_right = 0.5
	_splash_label.anchor_top = 0.15
	_splash_label.anchor_bottom = 0.15
	_splash_label.offset_left = 200
	_splash_label.offset_top = 60
	_splash_label.offset_right = 580
	_splash_label.offset_bottom = 120
	_splash_label.pivot_offset = Vector2(190, 30)
	_splash_label.rotation_degrees = -20.0
	_splash_label.add_theme_font_size_override("font_size", 44)
	_splash_label.add_theme_color_override("font_color", _SPLASH_COLOR)
	_splash_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_splash_label.add_theme_constant_override("shadow_offset_x", 3)
	_splash_label.add_theme_constant_override("shadow_offset_y", 3)
	_splash_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_splash_label)


func _build_buttons() -> void:
	var vbox := VBoxContainer.new()
	vbox.anchor_left = 0.5
	vbox.anchor_right = 0.5
	vbox.anchor_top = 0.48
	vbox.anchor_bottom = 0.48
	# Matches VanillaButton's 800 px GUI-scale-4 width.
	vbox.offset_left = -400
	vbox.offset_right = 400
	vbox.offset_top = 0
	vbox.offset_bottom = 400
	# Vanilla buttons sit 24 GUI-scale-1 px apart; at our 4× scale that's
	# 16 px between rows.
	vbox.add_theme_constant_override("separation", 16)
	add_child(vbox)
	var play_btn := _add_button(vbox, "Play Game", _on_play_pressed)
	_add_button(vbox, "Settings...", _on_settings_pressed)
	_add_button(vbox, "Quit", _on_quit_pressed)
	# Pre-focus the first button so the menu is usable via Tab / arrow keys +
	# Enter without a mouse — covers cases where the OS cursor isn't being
	# rendered (e.g. macOS editor embedded play).
	play_btn.call_deferred("grab_focus")


func _add_button(parent: VBoxContainer, text: String, handler: Callable) -> VanillaButton:
	var btn := VanillaButton.new()
	btn.text = text
	btn.pressed.connect(handler)
	parent.add_child(btn)
	return btn


# Top-left version label — dj.java:106 renders "Minecraft Alpha v1.2.6" at
# (2, 2) in color 0x505050. We reuse the position and color, change the
# string.
func _build_version_label() -> void:
	var label := Label.new()
	label.text = "VibezCraft Alpha v0.1 (targeting MC Alpha v1.2.6)"
	label.anchor_left = 0.0
	label.anchor_top = 0.0
	label.offset_left = 10
	label.offset_top = 10
	label.add_theme_font_size_override("font_size", 28)
	label.add_theme_color_override("font_color", _VERSION_COLOR)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)


# Bottom-right corner — dj.java:107-108 renders the copyright line in
# white. We replace the Mojang string with a clone disclaimer for legal
# hygiene (see legal.md).
func _build_footer_label() -> void:
	var label := Label.new()
	label.text = "Unofficial Alpha-era clone. Not affiliated with Mojang AB."
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.anchor_left = 1.0
	label.anchor_right = 1.0
	label.anchor_top = 1.0
	label.anchor_bottom = 1.0
	label.offset_left = -1040
	label.offset_top = -56
	label.offset_right = -16
	label.offset_bottom = -12
	label.add_theme_font_size_override("font_size", 28)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)


func _on_play_pressed() -> void:
	get_tree().change_scene_to_file(_MAIN_SCENE_PATH)


func _on_settings_pressed() -> void:
	if ResourceLoader.exists(_SETTINGS_SCENE_PATH):
		get_tree().change_scene_to_file(_SETTINGS_SCENE_PATH)


func _on_quit_pressed() -> void:
	get_tree().quit()
