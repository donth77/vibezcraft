class_name VanillaButton
extends Button

# Vanilla Alpha main-menu button footprint + text palette ported from
# vendor/alpha-1.2.6-src/src/gh.java.
#
#   width × height ... 200 × 20 px in GUI-scale-1 space
#   text color     ... 0xE0E0E0 normal, 0xFFFFA0 hover, 0xA0A0A0 disabled
#   panel         ... flat stone-gray with 1-px dark outline + lighter bevel
#                     (we can't ship Mojang's /gui/gui.png per legal.md, so
#                      the look is approximated via StyleBoxFlat)
#
# GUI-scale-2 was the default on pre-Beta; we render at 2× (400×40) so the
# footprint is physically the same size a player would see in vanilla on a
# typical 1024×768 window. Font-size 22 keeps the text proportional.

# Scaled 4× from vanilla's 200×20 — matches vanilla's GUI-scale-4 preset
# (the auto-max on 1440p+ monitors and a manual option on 1080p). Keeps
# the 10:1 width-to-height ratio of Alpha's gh.java button, and the font
# scales proportionally below so the text fills the panel the same way.
const _WIDTH: int = 800
const _HEIGHT: int = 80
const _COLOR_NORMAL: Color = Color(0xE0 / 255.0, 0xE0 / 255.0, 0xE0 / 255.0)
const _COLOR_HOVER: Color = Color(0xFF / 255.0, 0xFF / 255.0, 0xA0 / 255.0)
const _COLOR_DISABLED: Color = Color(0xA0 / 255.0, 0xA0 / 255.0, 0xA0 / 255.0)
const _PANEL_FILL: Color = Color(0x6C / 255.0, 0x6C / 255.0, 0x6C / 255.0)
const _PANEL_FILL_HOVER: Color = Color(0x8B / 255.0, 0x8F / 255.0, 0x9C / 255.0)
const _PANEL_BORDER: Color = Color(0x00 / 255.0, 0x00 / 255.0, 0x00 / 255.0)
const _PANEL_BEVEL: Color = Color(0xFF / 255.0, 0xFF / 255.0, 0xFF / 255.0, 0.35)


func _init() -> void:
	custom_minimum_size = Vector2(_WIDTH, _HEIGHT)
	add_theme_font_size_override("font_size", 40)
	add_theme_color_override("font_color", _COLOR_NORMAL)
	add_theme_color_override("font_hover_color", _COLOR_HOVER)
	add_theme_color_override("font_pressed_color", _COLOR_HOVER)
	add_theme_color_override("font_disabled_color", _COLOR_DISABLED)
	# Vanilla's drop-shadow effect — 1 native pixel offset, scaled with our
	# 4× GUI scale. Native drop-shadow theme keys exist on Button + Label;
	# bitmap fonts don't render an outline correctly anyway (each outline px
	# stamps the full glyph image) so shadow is also more visually correct.
	add_theme_color_override("font_shadow_color", Color.BLACK)
	add_theme_constant_override("shadow_offset_x", 4)
	add_theme_constant_override("shadow_offset_y", 4)
	add_theme_stylebox_override("normal", _make_panel(_PANEL_FILL))
	add_theme_stylebox_override("hover", _make_panel(_PANEL_FILL_HOVER))
	add_theme_stylebox_override("pressed", _make_panel(_PANEL_FILL_HOVER))
	add_theme_stylebox_override("disabled", _make_panel(_PANEL_FILL.darkened(0.3)))
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	# Vanilla MC plays random.click on every button activation. Wire it once
	# here so any VanillaButton (main menu, settings, etc.) gets the cue free.
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


static func _make_panel(fill: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = _PANEL_BORDER
	# Inner bevel — vanilla's button sprite has a 1-px lighter highlight
	# along the top / left and a slightly darker 1-px shadow along the
	# bottom / right. StyleBoxFlat doesn't expose asymmetric bevels, so
	# we fake it with expand_margin + a light border via a child bevel
	# approach isn't available either; settle for a flat dark outline.
	sb.corner_radius_top_left = 0
	sb.corner_radius_top_right = 0
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	return sb
