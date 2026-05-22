class_name VanillaButton
extends Button

# Vanilla Alpha main-menu button (gh.java) sourced from the real
# widgets.png sprite — same 9-slice the in-game pause menu draws, so
# every screen built from VanillaButton matches the pause menu's look.
#
# widgets.png stripe layout (verified by pixel-inspection):
#   y=46..65   disabled  (greyed)
#   y=66..85   normal
#   y=86..105  hover     (blue tint + lighter face)
# Each is 200×20 native; the 2-px black border + 1-px shadow row are
# preserved by the 9-slice margins below.
#
# Scaled 4× to 800×80 — matches vanilla's GUI-scale-4 preset (the
# auto-max on 1440p+ monitors, manual option on 1080p). Font-size 40
# keeps the text proportional inside the panel.

const _WIDGETS_PATH: String = "res://assets/textures/gui/widgets.png"
const _WIDTH: int = 800
const _HEIGHT: int = 80

# Source-texture regions for the three button states.
const _REGION_DISABLED: Rect2 = Rect2(0, 46, 200, 20)
const _REGION_NORMAL: Rect2 = Rect2(0, 66, 200, 20)
const _REGION_HOVER: Rect2 = Rect2(0, 86, 200, 20)

# 9-slice slice sizes in OUTPUT pixels. Source corners are 2 px so we use
# 8 (4× scale) — keeps the border 1:1 with the rest of the pixel art.
# Bottom is 12 to preserve the extra-thick vanilla shadow row.
const _SLICE: int = 8
const _SLICE_BOTTOM: int = 12

const _COLOR_NORMAL: Color = Color(0xE0 / 255.0, 0xE0 / 255.0, 0xE0 / 255.0)
const _COLOR_HOVER: Color = Color(0xFF / 255.0, 0xFF / 255.0, 0xA0 / 255.0)
const _COLOR_DISABLED: Color = Color(0xA0 / 255.0, 0xA0 / 255.0, 0xA0 / 255.0)


func _init() -> void:
	custom_minimum_size = Vector2(_WIDTH, _HEIGHT)
	# Nearest-neighbor sampling so the upscaled widgets.png stays crisp
	# pixel art instead of going soft like the default bilinear filter.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_theme_font_size_override("font_size", 40)
	add_theme_color_override("font_color", _COLOR_NORMAL)
	add_theme_color_override("font_hover_color", _COLOR_HOVER)
	add_theme_color_override("font_pressed_color", _COLOR_HOVER)
	add_theme_color_override("font_disabled_color", _COLOR_DISABLED)
	# 1-native-pixel drop shadow, 4× scaled. Bitmap fonts don't render
	# outlines cleanly (each outline px stamps the full glyph image), so
	# shadow is also more visually correct.
	add_theme_color_override("font_shadow_color", Color.BLACK)
	add_theme_constant_override("shadow_offset_x", 4)
	add_theme_constant_override("shadow_offset_y", 4)
	# All four states drawn from the same widgets.png — `pressed` reuses
	# hover so the button doesn't flash to a different sprite mid-click.
	add_theme_stylebox_override("normal", _make_widget_box(_REGION_NORMAL))
	add_theme_stylebox_override("hover", _make_widget_box(_REGION_HOVER))
	add_theme_stylebox_override("pressed", _make_widget_box(_REGION_HOVER))
	add_theme_stylebox_override("disabled", _make_widget_box(_REGION_DISABLED))
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# Vanilla MC plays random.click on every button activation. Wire it once
	# here so any VanillaButton gets the cue free.
	pressed.connect(SFX.play_click)


# Nearest-neighbor-upscales the active pack's dirt sprite so STRETCH_TILE
# produces a tile every ~64 screen px instead of every 16 — matches
# vanilla's `f2 = 32.0f` tile-size math in hu.java / dj.java, which drew
# the /gui/background.png as 32-px squares on a GUI-scale-1 canvas (so
# 128 px at scale 4, which is what we're hitting). Returns null if the
# active pack doesn't ship a dirt texture yet.
static func make_scaled_dirt_texture(scale: int = 4) -> Texture2D:
	var src: Texture2D = (
		load("%s%s/dirt.png" % [BlockAtlas.PACK_BASE, BlockAtlas.active_pack]) as Texture2D
	)
	if src == null:
		return null
	var img: Image = src.get_image()
	if img == null:
		return null
	img.resize(img.get_width() * scale, img.get_height() * scale, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(img)


static func _make_widget_box(region: Rect2) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = load(_WIDGETS_PATH) as Texture2D
	sb.region_rect = region
	# 9-slice margins in output-pixel space. Source corners are 2 px, so
	# at our 4× upscale they render as 8-px chunky pixel-art corners
	# (matches pause_menu's NinePatchRect-with-scale=4 approach). Bottom
	# at 12 preserves vanilla's slightly taller shadow row.
	sb.texture_margin_left = _SLICE
	sb.texture_margin_right = _SLICE
	sb.texture_margin_top = _SLICE
	sb.texture_margin_bottom = _SLICE_BOTTOM
	return sb
