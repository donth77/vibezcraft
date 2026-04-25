extends Control

# Vanilla MC's first-person "on fire" HUD render. `ku.java:268-299`
# (EntityRenderer.renderFireInFirstPerson) draws TWO flame quads in front
# of the camera at (±0.24, -0.3, -0.5) with a ±10° Y rotation while the
# entity has `bg > 0` (fire ticks remaining). Each quad samples the
# animated fire texture — vanilla proc-gens it at runtime from a
# convection sim; we use the canonical Beta fire_layer_0.png strip
# (16×512, 32 frames of 16×16) which matches the proc-gen output
# visually. Plays at 24 FPS (vanilla's texture-animation cadence).
#
# This is a Control with two TextureRect children positioned at bottom-
# left and bottom-right of the screen — the 2D HUD analog of vanilla's
# two 3D camera-space quads. Tried a full-screen ColorRect tint first;
# it communicated "you're burning" but the animated flame silhouettes
# read much more clearly.

const _FIRE_STRIP_PATH: String = "res://assets/textures/particles/fire_layer_0.png"
const _STRIP_FRAME_COUNT: int = 32
const _STRIP_CELL_PX: int = 16
const _ANIM_FPS: float = 24.0
const _PEAK_ALPHA: float = 0.85
const _FADE_IN_SEC: float = 0.1
const _FADE_OUT_SEC: float = 0.4
# Each quad takes 40% of the viewport width — vanilla's 1×1 m quads at
# z=-0.5 with 90° FOV cover roughly the inner half of the screen each
# (with mild overlap). 40% per side reads similarly without eating the
# whole HUD.
const _QUAD_WIDTH_RATIO: float = 0.40
# Positive offset below center, mirroring vanilla's `-0.3f` Y translate.
const _QUAD_VERTICAL_OFFSET_RATIO: float = 0.08

var _player: Node
var _target_alpha: float = 0.0
var _current_alpha: float = 0.0
var _anim_time: float = 0.0
# Two TextureRects — left and right flame panels. Each uses its own
# AtlasTexture so we can offset their animation frames by half the
# cycle; prevents them looking like identical mirrored copies.
var _rect_left: TextureRect
var _rect_right: TextureRect
var _atlas_left: AtlasTexture
var _atlas_right: AtlasTexture


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var strip: Texture2D = load(_FIRE_STRIP_PATH) as Texture2D
	_atlas_left = _build_atlas(strip)
	_atlas_right = _build_atlas(strip)
	_rect_left = _build_quad(_atlas_left, true)
	_rect_right = _build_quad(_atlas_right, false)
	add_child(_rect_left)
	add_child(_rect_right)
	_player = get_tree().root.get_node_or_null("Main/Player")
	# Start invisible; _process fades in on fire.
	modulate.a = 0.0
	visible = false
	resized.connect(_on_resized)


func _build_atlas(strip: Texture2D) -> AtlasTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = strip
	atlas.region = Rect2(0, 0, _STRIP_CELL_PX, _STRIP_CELL_PX)
	atlas.filter_clip = true
	return atlas


func _build_quad(atlas: AtlasTexture, mirror_h: bool) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = atlas
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	# Nearest-neighbor — pixel art, no bilinear smear.
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.flip_h = mirror_h
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


func _on_resized() -> void:
	_layout_quads()


func _layout_quads() -> void:
	if _rect_left == null or _rect_right == null:
		return
	var vp_size: Vector2 = get_viewport_rect().size
	var quad_w: float = vp_size.x * _QUAD_WIDTH_RATIO
	var quad_h: float = vp_size.y
	var y_offset: float = vp_size.y * _QUAD_VERTICAL_OFFSET_RATIO
	_rect_left.position = Vector2(0, y_offset)
	_rect_left.size = Vector2(quad_w, quad_h)
	_rect_right.position = Vector2(vp_size.x - quad_w, y_offset)
	_rect_right.size = Vector2(quad_w, quad_h)


func _process(delta: float) -> void:
	if _player == null:
		return
	var on_fire: bool = false
	if _player.has_method("on_fire"):
		on_fire = _player.call("on_fire")
	# Vanilla Alpha 1.2.6 has no third-person view (added in Beta 1.5),
	# so this HUD overlay never had to gate on perspective. We added F5
	# as QoL — in 3rd-person the body-wrap flames (character_model fire
	# billboards) already convey "burning"; layering the HUD overlay on
	# top is redundant and obscures the camera view.
	var first_person: bool = true
	if "perspective" in _player and "PERSPECTIVE_FIRST" in _player:
		first_person = _player.perspective == _player.PERSPECTIVE_FIRST
	_target_alpha = _PEAK_ALPHA if (on_fire and first_person) else 0.0
	# Asymmetric fade: pop fast on ignite, linger on cooldown. Matches
	# the feel of catching fire vs. the smouldering trail.
	var speed: float = 1.0 / _FADE_IN_SEC if _target_alpha > _current_alpha else 1.0 / _FADE_OUT_SEC
	_current_alpha = move_toward(_current_alpha, _target_alpha, speed * delta)
	modulate.a = _current_alpha
	visible = _current_alpha > 0.001
	if not visible:
		return
	# Advance the animated fire strip. Vanilla's texture anim runs at ~24
	# FPS (texture-fx step per 2 game ticks). Use modulo so the integer
	# frame cycles cleanly across the 32-cell strip.
	_anim_time += delta * _ANIM_FPS
	var frame_l: int = int(_anim_time) % _STRIP_FRAME_COUNT
	# Right panel offset by half-cycle so it doesn't look like a mirror.
	var frame_r: int = (frame_l + _STRIP_FRAME_COUNT / 2) % _STRIP_FRAME_COUNT
	_atlas_left.region = Rect2(0, frame_l * _STRIP_CELL_PX, _STRIP_CELL_PX, _STRIP_CELL_PX)
	_atlas_right.region = Rect2(0, frame_r * _STRIP_CELL_PX, _STRIP_CELL_PX, _STRIP_CELL_PX)
	if _rect_left.size == Vector2.ZERO:
		_layout_quads()
