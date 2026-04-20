class_name DurabilityBar
extends Control

# Vanilla-style green-to-red durability bar drawn at the bottom of an
# inventory slot. Set bar height + bottom margin via the constants below.
# The bar shows nothing if the bound stack is non-tool or pristine.

const _BAR_HEIGHT_NATIVE: int = 1  # 1 native pixel — vanilla MC's bar
const _BAR_BG: Color = Color(0, 0, 0, 0.85)

# Pixel scale (caller passes the same SCALE the slot is rendered at).
var scale_factor: int = 4
var _stack: ItemStack


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func bind(stack: ItemStack, inner_size_px: int) -> void:
	# Position bar at the BOTTOM of the inner-slot area. Caller is expected
	# to set our position to the slot's inner origin and our size to the
	# inner-slot footprint before / right after calling bind.
	_stack = stack
	size = Vector2(inner_size_px, _BAR_HEIGHT_NATIVE * scale_factor)
	# Caller positions us; we just resize. Repaint to reflect current state.
	queue_redraw()


func refresh() -> void:
	queue_redraw()


func _draw() -> void:
	if _stack == null or not _stack.should_show_durability():
		return
	var max_d: int = _stack.max_durability()
	var remaining: int = max_d - _stack.damage
	var ratio: float = clampf(float(remaining) / float(max_d), 0.0, 1.0)
	# Vanilla color: hue lerps green → red as durability drops. Saturation
	# fixed at 1, value at 1.
	var hue: float = ratio / 3.0  # 0 = red, 1/3 = green
	var fg := Color.from_hsv(hue, 1.0, 1.0, 1.0)
	# Draw bg full width, fg the remaining-fraction width.
	var w: float = size.x
	var h: float = size.y
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), _BAR_BG, true)
	draw_rect(Rect2(Vector2.ZERO, Vector2(w * ratio, h)), fg, true)
