class_name VanillaButton
extends Control

# Vanilla Alpha button (gh.java) — Control + NinePatchRect + Label,
# matching scripts/ui/pause_menu.gd's `_make_button` byte for byte so
# every VanillaButton renders identically to the in-game pause menu
# buttons. (Earlier attempt extended Button + StyleBoxTexture, which
# subtly mismatched the pause menu's NinePatchRect-with-scale: text
# inset, font fallback, and 9-slice sampling all drifted off pause-
# menu parity. Living with two near-duplicate implementations is the
# right trade — the pause menu has its own button code for legacy
# reasons we don't want to touch.)
#
# widgets.png stripe layout:
#   y=46..65   disabled
#   y=66..85   normal
#   y=86..105  hover (blue tint + lighter face)
#
# Scaled 4× to 800×80 — vanilla's GUI-scale-4 preset. Font-size 40 keeps
# the bitmap font readable at modern resolutions.
#
# API surface (kept stable for the existing 8+ call-sites):
#   • .text                        — display label
#   • .pressed (signal)            — fires on mouse-left release
#   • .disabled                    — greys out + swaps to disabled sprite
#   • .custom_minimum_size         — inherited from Control
#   • .set_font_size(int)          — per-instance label font override

signal pressed

const _WIDGETS_PATH: String = "res://assets/textures/gui/widgets.png"
const SCALE: int = 4
const _NATIVE_W: int = 200
const _NATIVE_H: int = 20
const _WIDTH: int = _NATIVE_W * SCALE  # 800
const _HEIGHT: int = _NATIVE_H * SCALE  # 80
const _DEFAULT_FONT_SIZE: int = 10 * SCALE  # 40, matches pause_menu

# 9-slice source-pixel margins — measured in the UPSCALED texture
# (2-px native × 4× upscale = 8-px corner, 3-px native shadow → 12-px).
# pause_menu's NinePatchRect-with-scale=4 produces the same effective
# corner footprint; here the upscale is baked into the texture so the
# NinePatchRect can size freely to the parent Control without needing
# its own scale (which would lock every button to 800×80 and overflow
# any custom_minimum_size smaller than that).
const _PATCH_LEFT: int = 8
const _PATCH_RIGHT: int = 8
const _PATCH_TOP: int = 8
const _PATCH_BOTTOM: int = 12

# Source regions in the ORIGINAL widgets.png. The upscaled cache below
# pulls these rects, nearest-neighbor-resizes them 4×, and stores the
# result so every VanillaButton gets crisp 8-px borders independent of
# its final rendered size.
const _REGION_DISABLED: Rect2 = Rect2(0, 46, _NATIVE_W, _NATIVE_H)
const _REGION_NORMAL: Rect2 = Rect2(0, 66, _NATIVE_W, _NATIVE_H)
const _REGION_HOVER: Rect2 = Rect2(0, 86, _NATIVE_W, _NATIVE_H)

# Vanilla GuiButton text palette (gh.java).
const _TEXT_NORMAL: Color = Color8(224, 224, 224)
const _TEXT_HOVER: Color = Color8(255, 255, 160)
const _TEXT_DISABLED: Color = Color8(160, 160, 160)

# State-keyed cache of upscaled button sprites. Lazy-initialized on the
# first VanillaButton._build_background; same texture reused by every
# subsequent button. Keyed by state name to keep call-sites obvious.
static var _state_textures: Dictionary = {}

@export var text: String = "":
	set(value):
		text = value
		if _label != null:
			_label.text = value

var disabled: bool:
	get:
		return _disabled
	set(value):
		_disabled = value
		_apply_state()

var _npr: NinePatchRect
var _label: Label
# Tracking flags. We can't easily proxy `disabled` through Button (we're
# a Control), so we maintain our own state + sprite/color sync.
var _disabled: bool = false
var _hovered: bool = false


func _init() -> void:
	custom_minimum_size = Vector2(_WIDTH, _HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	_build_background()
	_build_label()
	# Callers commonly do `btn = VanillaButton.new(); btn.text = "..."`
	# BEFORE the node enters the tree — so the `text` setter fires while
	# `_label` is still null and silently drops the value. Re-apply
	# whatever's been stored once the label exists. Same for `disabled`.
	_label.text = text
	_apply_state()
	mouse_entered.connect(_on_mouse_enter)
	mouse_exited.connect(_on_mouse_exit)
	gui_input.connect(_on_gui_input)


func _build_background() -> void:
	_npr = NinePatchRect.new()
	_npr.texture = _state_texture("normal")
	_npr.patch_margin_left = _PATCH_LEFT
	_npr.patch_margin_right = _PATCH_RIGHT
	_npr.patch_margin_top = _PATCH_TOP
	_npr.patch_margin_bottom = _PATCH_BOTTOM
	_npr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Fill the parent Control. Combined with 8-px source patch margins on
	# the pre-upscaled texture, the corners always render at 8 px crisp,
	# while the stretchy regions flex with the parent's custom_minimum_size.
	# Works for the default 800×80 button AND the smaller 220×80 / 280×60
	# overrides used in controls_menu + settings_menu's New Seed row.
	_npr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_npr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_npr)


# Lazy-load + cache the upscaled state textures. Original widgets.png
# button strips are 200×20 native; we resize each to 800×80 with
# INTERPOLATE_NEAREST so the borders stay crisp pixel art even when the
# NinePatchRect ends up rendering at a non-default size (e.g. the small
# 280×60 "New Seed" button). One copy per state, shared across every
# VanillaButton in the session.
static func _state_texture(state: String) -> Texture2D:
	if _state_textures.has(state):
		return _state_textures[state]
	var src: Texture2D = load(_WIDGETS_PATH) as Texture2D
	if src == null:
		return null
	var region: Rect2 = _REGION_NORMAL
	if state == "hover":
		region = _REGION_HOVER
	elif state == "disabled":
		region = _REGION_DISABLED
	var img: Image = src.get_image()
	if img == null:
		return null
	var cropped: Image = Image.create_empty(
		int(region.size.x), int(region.size.y), false, img.get_format()
	)
	cropped.blit_rect(img, Rect2i(Vector2i(region.position), Vector2i(region.size)), Vector2i.ZERO)
	cropped.resize(
		int(region.size.x) * SCALE, int(region.size.y) * SCALE, Image.INTERPOLATE_NEAREST
	)
	var tex: ImageTexture = ImageTexture.create_from_image(cropped)
	_state_textures[state] = tex
	return tex


func _build_label() -> void:
	_label = Label.new()
	# Explicit font + size override matches pause_menu exactly; relying
	# on ThemeDB fallback was the source of subtle differences (font
	# sometimes failed to apply for theme-overridden children).
	var font: FontFile = MinecraftFont.get_font()
	if font != null:
		_label.add_theme_font_override("font", font)
	_label.add_theme_font_size_override("font_size", _DEFAULT_FONT_SIZE)
	_label.add_theme_color_override("font_color", _TEXT_NORMAL)
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
	_label.add_theme_constant_override("shadow_offset_x", SCALE)
	_label.add_theme_constant_override("shadow_offset_y", SCALE)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)


# --- Public API ---


func set_font_size(px: int) -> void:
	if _label != null:
		_label.add_theme_font_size_override("font_size", px)


# --- Internal ---


func _on_mouse_enter() -> void:
	if _disabled:
		return
	_hovered = true
	_apply_state()


func _on_mouse_exit() -> void:
	if _disabled:
		return
	_hovered = false
	_apply_state()


func _on_gui_input(event: InputEvent) -> void:
	if _disabled:
		return
	if (
		event is InputEventMouseButton
		and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT
		and not (event as InputEventMouseButton).pressed
	):
		SFX.play_click()
		pressed.emit()


func _apply_state() -> void:
	if _npr == null or _label == null:
		return
	if _disabled:
		_npr.texture = _state_texture("disabled")
		_label.add_theme_color_override("font_color", _TEXT_DISABLED)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	elif _hovered:
		_npr.texture = _state_texture("hover")
		_label.add_theme_color_override("font_color", _TEXT_HOVER)
		mouse_filter = Control.MOUSE_FILTER_STOP
	else:
		_npr.texture = _state_texture("normal")
		_label.add_theme_color_override("font_color", _TEXT_NORMAL)
		mouse_filter = Control.MOUSE_FILTER_STOP


# Nearest-neighbor-upscales the active pack's dirt sprite so STRETCH_TILE
# produces a tile every ~64 screen px instead of every 16 — matches
# vanilla's `f2 = 32.0f` tile-size math. Returns null if the active pack
# doesn't ship a dirt texture yet. (Unrelated to the button itself, but
# main_menu / loading_screen / select_world_screen all reach for it
# through VanillaButton.make_scaled_dirt_texture(...).)
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
