extends Control

# Vanilla MC HUD heart row — 10 hearts laid out horizontally above the
# hotbar. Each heart represents 2 HP (full / half / empty). Sources its
# sprites from gui/icons.png at the canonical 9×9 atlas coords:
#   (16, 0) heart container (gray background)
#   (52, 0) full red heart
#   (61, 0) half red heart
# Drawn at SCALE = 4 to match the hotbar's chunky pixel-art density.

const ICONS_PATH: String = "res://assets/textures/gui/icons.png"
const HEART_PX: int = 9
const HEART_STRIDE: int = 8  # vanilla packs hearts 8 px apart, 1 px overlap
const SCALE: int = 4
const HEARTS: int = 10  # 10 hearts × 2 HP = 20

const _ATLAS_BG: Rect2 = Rect2(16, 0, HEART_PX, HEART_PX)
const _ATLAS_FULL: Rect2 = Rect2(52, 0, HEART_PX, HEART_PX)
const _ATLAS_HALF: Rect2 = Rect2(61, 0, HEART_PX, HEART_PX)

const _JITTER_DURATION: float = 0.35  # vanilla hurtTime = 10 ticks @ 20 TPS
const _JITTER_AMP_PX: int = 2  # vanilla nextInt(2) horizontal offset per heart

var _bg_rects: Array = []  # Array[TextureRect]
var _fill_rects: Array = []  # Array[TextureRect]
var _base_x: Array = []  # captured base positions so we can restore after jitter
var _jitter_remaining: float = 0.0
var _player: Node


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_hearts()
	_player = get_tree().root.get_node_or_null("Main/Player")
	if _player != null:
		if _player.has_signal("health_changed"):
			_player.health_changed.connect(_on_health_changed)
		if _player.has_signal("damaged"):
			_player.damaged.connect(_on_damaged)
	# Initial draw
	if _player != null and "health" in _player:
		_refresh(_player.health)
	else:
		_refresh(20)


func _process(delta: float) -> void:
	if _jitter_remaining <= 0.0:
		return
	_jitter_remaining -= delta
	if _jitter_remaining <= 0.0:
		# Reset to base positions.
		for i in range(_bg_rects.size()):
			(_bg_rects[i] as TextureRect).position.x = _base_x[i]
			(_fill_rects[i] as TextureRect).position.x = _base_x[i]
		return
	# Each heart randomly offsets -1, 0, or +1 native pixels per frame
	# (scaled to SCALE px) — vanilla jitter.
	for i in range(_bg_rects.size()):
		var jitter: int = (randi() % (2 * _JITTER_AMP_PX + 1)) - _JITTER_AMP_PX
		var x_offset: int = jitter * SCALE
		(_bg_rects[i] as TextureRect).position.x = _base_x[i] + x_offset
		(_fill_rects[i] as TextureRect).position.x = _base_x[i] + x_offset


func _on_damaged(_amount: int, _source: String) -> void:
	_jitter_remaining = _JITTER_DURATION


func _build_hearts() -> void:
	var sheet: Texture2D = load(ICONS_PATH) as Texture2D
	for i in range(HEARTS):
		var x: int = i * HEART_STRIDE * SCALE
		var bg: TextureRect = _make_heart(sheet, _ATLAS_BG)
		bg.position = Vector2(x, 0)
		add_child(bg)
		_bg_rects.append(bg)
		var fill: TextureRect = _make_heart(sheet, _ATLAS_FULL)
		fill.position = Vector2(x, 0)
		fill.visible = false
		add_child(fill)
		_fill_rects.append(fill)
		_base_x.append(x)
	# Sized to the row footprint so anchor-positioning works in the scene.
	custom_minimum_size = Vector2(HEARTS * HEART_STRIDE * SCALE, HEART_PX * SCALE)


func _make_heart(sheet: Texture2D, region: Rect2) -> TextureRect:
	var atlas := AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = region
	var tr := TextureRect.new()
	tr.texture = atlas
	tr.size = Vector2(HEART_PX * SCALE, HEART_PX * SCALE)
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


func _on_health_changed(current: int, _maximum: int) -> void:
	_refresh(current)


# Each heart slot covers 2 HP. Hearts 0..(N/2) are full; if HP is odd,
# the next heart is half; the rest are empty (just bg).
func _refresh(current_hp: int) -> void:
	for i in range(HEARTS):
		var hp_for_this: int = clampi(current_hp - i * 2, 0, 2)
		var fill: TextureRect = _fill_rects[i]
		if hp_for_this == 2:
			(fill.texture as AtlasTexture).region = _ATLAS_FULL
			fill.visible = true
		elif hp_for_this == 1:
			(fill.texture as AtlasTexture).region = _ATLAS_HALF
			fill.visible = true
		else:
			fill.visible = false
