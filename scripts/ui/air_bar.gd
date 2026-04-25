extends Control

# Vanilla MC HUD air bubble row — 10 bubbles that pop from right to left
# as submerged air runs out. Mirrors EntityLiving's airTicks: 300 ticks
# (15 s) of grace while the head is in water, then 2 damage per 20 ticks
# while air < 0. The bar is hidden entirely when air is full and the
# player isn't in water.
#
# Sprites sourced from gui/icons.png at vanilla atlas coords:
#   (16, 18) full bubble
#   (25, 18) popping bubble (transient visual on the next-to-pop slot)

const ICONS_PATH: String = "res://assets/textures/gui/icons.png"
const BUBBLE_PX: int = 9
const BUBBLE_STRIDE: int = 8  # vanilla overlaps 1 px like hearts
const SCALE: int = 4
const BUBBLES: int = 10

const _ATLAS_FULL: Rect2 = Rect2(16, 18, BUBBLE_PX, BUBBLE_PX)
const _ATLAS_POPPING: Rect2 = Rect2(25, 18, BUBBLE_PX, BUBBLE_PX)

var _bubble_rects: Array = []  # Array[TextureRect]
var _player: Node


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_bubbles()
	_player = get_tree().root.get_node_or_null("Main/Player")
	if _player != null and _player.has_signal("air_changed"):
		_player.air_changed.connect(_on_air_changed)
	_refresh(1.0)  # start hidden (full air)


func _build_bubbles() -> void:
	var sheet: Texture2D = load(ICONS_PATH) as Texture2D
	for i in range(BUBBLES):
		var x: int = i * BUBBLE_STRIDE * SCALE
		var atlas := AtlasTexture.new()
		atlas.atlas = sheet
		atlas.region = _ATLAS_FULL
		var tr := TextureRect.new()
		tr.texture = atlas
		tr.size = Vector2(BUBBLE_PX * SCALE, BUBBLE_PX * SCALE)
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.position = Vector2(x, 0)
		tr.visible = false
		add_child(tr)
		_bubble_rects.append(tr)
	custom_minimum_size = Vector2(BUBBLES * BUBBLE_STRIDE * SCALE, BUBBLE_PX * SCALE)


func _on_air_changed(fraction: float) -> void:
	_refresh(fraction)


# `fraction` in [0, 1]: 1.0 = full breath (bar hidden), 0.0 = drowning.
# Mirrors vanilla GuiIngame.renderAir (Bukkit/mc-dev, renderAir method):
#   int i = ceil((airFrac - 0.02) * 10);   // number of fully-lit bubbles
#   int j = ceil(airFrac * 10) - i;        // 0 or 1 "popping" bubble
#   render i full bubbles then j popping bubbles at the right edge.
# Result: the popping sprite only flashes for the ~0.12 s window right
# before a bubble disappears (not the whole 1.5 s of its life) — matches
# vanilla's visible animation where each bubble briefly flashes popping
# on its way out.
func _refresh(fraction: float) -> void:
	var show_bar: bool = fraction < 1.0
	var full_count: int = clampi(int(ceil((fraction - 0.02) * float(BUBBLES))), 0, BUBBLES)
	var popping_count: int = clampi(int(ceil(fraction * float(BUBBLES))) - full_count, 0, 1)
	var visible_total: int = full_count + popping_count
	for i in range(BUBBLES):
		var rect: TextureRect = _bubble_rects[i]
		if not show_bar or i >= visible_total:
			rect.visible = false
			continue
		var atlas: AtlasTexture = rect.texture as AtlasTexture
		# The slot just past full_count is the popping one.
		atlas.region = _ATLAS_POPPING if i >= full_count else _ATLAS_FULL
		rect.visible = true
