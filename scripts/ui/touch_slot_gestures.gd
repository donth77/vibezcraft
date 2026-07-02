class_name TouchSlotGestures
extends RefCounted

# Bedrock-style slot gestures for the container screens on touch
# devices. The desktop screens speak mouse (left = pick/place/swap,
# right = take-half/place-one, hold-drag = distribution painting), and
# running that model over Godot's emulated-mouse-from-touch made phones
# miserable: the DOM mouse position only moves at tap moments, drags
# triggered distribution painting ("crumbs" across slots), and there was
# no right-click at all — so no way to split stacks for crafting.
#
# Touch model implemented here (screens feed _input events + a _process
# poll; all slot mutations reuse the screens' EXISTING click handlers so
# item semantics can't diverge from desktop):
#   tap a slot                     → left-click (pick up / place / swap)
#   long-press (~0.35 s)           → right-click (take half — or place
#                                    ONE when holding a stack)
#   long-press then drag           → right-click painting: one item into
#                                    each slot dragged over (the plank-
#                                    across-the-craft-grid gesture)
#   press-drag-release             → carry: picks the stack up, follows
#                                    the finger, places on release
#   release/tap OUTSIDE the panel  → holding a stack: DROP it (when the
#                                    screen has drop plumbing); empty
#                                    hand: close the screen
# The touch HUD's own always-live buttons (pause/inventory) are excluded
# from outside-close so one tap can't close-then-reopen.

const LONG_PRESS_MS: int = 320
# Carry activates only past this drag distance. Canvas pixels: ~55 is
# just over half a slot — big enough that natural thumb wobble during a
# long-press (~1-2 mm) doesn't silently cancel the split gesture, small
# enough that a deliberate slot-to-slot drag still lifts the stack.
const DRAG_SLOP_PX: float = 55.0

# Wiring — set by each screen right after construction.
var tree: SceneTree
var panel: Control
var none_id: int = -1
var slot_under: Callable  # () -> int
var on_left: Callable  # (slot: int) -> void
var on_right: Callable  # (slot: int) -> void
var cursor_empty: Callable  # () -> bool
var on_drop: Callable = Callable()  # () -> void; invalid = no drop plumbing
var on_close: Callable

var _active: bool = false
var _pressed_slot: int = 0
var _press_pos := Vector2.ZERO
var _press_ms: int = 0
var _carrying: bool = false
var _split_mode: bool = false
var _last_split_slot: int = 0


# True while a finger is on the screen. Screens gate tooltips on this —
# desktop hover semantics over a frozen touch pointer left item tooltips
# permanently stuck on whatever slot was tapped last.
func is_touch_down() -> bool:
	return _active


func handle_event(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_active = true
			_press_pos = touch.position
			_press_ms = Time.get_ticks_msec()
			_carrying = false
			_split_mode = false
			_pressed_slot = slot_under.call()
			_last_split_slot = none_id
		else:
			_on_release(touch.position)
	elif event is InputEventScreenDrag and _active:
		_on_drag_moved(event as InputEventScreenDrag)


# Long-press detector — screens call this from _process.
func poll() -> void:
	if not _active or _carrying or _split_mode:
		return
	if Time.get_ticks_msec() - _press_ms < LONG_PRESS_MS:
		return
	_split_mode = true
	if _pressed_slot != none_id:
		_last_split_slot = _pressed_slot
		on_right.call(_pressed_slot)
		# Haptic tick so the split registers without looking away from
		# the thumb (no-op on platforms without a vibrator).
		Input.vibrate_handheld(25)


func _on_drag_moved(drag: InputEventScreenDrag) -> void:
	if _split_mode:
		# Right-click painting: one item into each newly entered slot.
		var slot: int = slot_under.call()
		if slot != none_id and slot != _last_split_slot and not bool(cursor_empty.call()):
			_last_split_slot = slot
			on_right.call(slot)
		return
	if _carrying or _pressed_slot == none_id:
		return
	if drag.position.distance_to(_press_pos) < DRAG_SLOP_PX:
		return
	# Drag-carry: pick the pressed stack up now; the cursor icon follows
	# the finger (screens track _pointer_pos) and release places it.
	_carrying = true
	if bool(cursor_empty.call()):
		on_left.call(_pressed_slot)


func _on_release(pos: Vector2) -> void:
	if not _active:
		return
	var slot: int = slot_under.call()
	var outside: bool = panel != null and not panel.get_global_rect().has_point(pos)
	if _split_mode:
		pass  # long-press already acted (and painted during any drag)
	elif _carrying:
		if outside:
			_drop_if_possible()
		elif slot != none_id:
			on_left.call(slot)
		elif _pressed_slot != none_id and not bool(cursor_empty.call()):
			# Released over panel chrome (between slots): return the
			# carried stack to its origin instead of leaving it floating
			# on the cursor — the classic "icon stuck in the UI" report.
			on_left.call(_pressed_slot)
	elif _pressed_slot != none_id and slot == _pressed_slot:
		on_left.call(slot)
	elif outside and not _hud_owns(pos):
		if not bool(cursor_empty.call()):
			_drop_if_possible()
		else:
			on_close.call()
	_active = false
	_carrying = false
	_split_mode = false
	_pressed_slot = none_id


func _drop_if_possible() -> void:
	if on_drop.is_valid() and not bool(cursor_empty.call()):
		on_drop.call()


# The touch HUD's pause/inventory buttons toggle screens themselves —
# an outside interaction on them must not also close-close/reopen.
func _hud_owns(pos: Vector2) -> bool:
	if tree == null:
		return false
	var hud: Node = tree.get_first_node_in_group("touch_controls")
	return hud != null and bool(hud.call("owns_hud_point", pos))
