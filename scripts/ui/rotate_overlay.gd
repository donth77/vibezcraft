class_name RotateOverlay
extends CanvasLayer

# Full-screen "rotate your device" prompt for mobile web. Shown whenever
# the viewport is portrait. Android normally never sees it — the first
# touch in TouchControls requests fullscreen + a landscape orientation
# lock — but iOS Safari has no Screen Orientation lock API at all, so
# the overlay is the only handling there. Swallows input while visible
# so a half-rotated game can't eat taps.

const _BG := Color(0.06, 0.04, 0.03, 0.97)
const _TEXT := Color(0.88, 0.88, 0.88)

var _root: Control
var _label: Label
var _phone: Control


func _ready() -> void:
	# Above every gameplay layer including screens (Crosshair CanvasLayer
	# defaults to 1) and the pause menu; keeps prompting while paused.
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var bg := ColorRect.new()
	bg.color = _BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(bg)
	_phone = Control.new()
	_phone.set_anchors_preset(Control.PRESET_CENTER)
	_phone.draw.connect(_draw_phone)
	_root.add_child(_phone)
	_label = Label.new()
	_label.text = "Rotate your device"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_override("font", MinecraftFont.get_font())
	_label.add_theme_font_size_override("font_size", 40)
	_label.add_theme_color_override("font_color", _TEXT)
	_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_label.add_theme_constant_override("shadow_offset_x", 3)
	_label.add_theme_constant_override("shadow_offset_y", 3)
	_label.set_anchors_preset(Control.PRESET_CENTER)
	_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_label.position.y = 70
	_root.add_child(_label)
	var viewport: Viewport = get_viewport()
	viewport.size_changed.connect(_update_visibility)
	_update_visibility()


# Simple phone outline rotating 90° is overkill — a static landscape
# phone glyph reads instantly and avoids per-frame redraw on a screen
# whose whole point is "the game is waiting".
func _draw_phone() -> void:
	var w: float = 120.0
	var h: float = 64.0
	var rect := Rect2(-w / 2.0, -h / 2.0 - 20.0, w, h)
	_phone.draw_rect(rect, _TEXT, false, 4.0)
	# Speaker dot on the right edge — sells "phone held sideways".
	_phone.draw_circle(Vector2(rect.end.x - 12.0, rect.get_center().y), 3.0, _TEXT)


func _update_visibility() -> void:
	var size: Vector2 = get_viewport().get_visible_rect().size
	visible = size.y > size.x
	if visible:
		_phone.queue_redraw()
