class_name TouchControls
extends Control

# On-screen touch HUD for mobile web (and MC_CLONE_FORCE_TOUCH=1 desktop
# preview). One Control, no child nodes: every element is a cached Rect2
# hit-test plus _draw primitives, and ALL touches are routed manually in
# _input. Godot's mouse-from-touch emulation only mirrors the FIRST
# finger, so Control-based buttons would go dead the moment a second
# finger lands (jump while steering) — manual routing is what makes
# multi-touch work, not a style choice.
#
# Look-smoothness contract (the part that must never regress):
#   • _input only ACCUMULATES drag deltas — no rotation, no allocation,
#     no node lookups. Touch events can arrive 0..N times per rendered
#     frame (and browsers batch them); rotating per-event aliases that
#     cadence into visible stutter.
#   • _process applies the accumulated delta exactly ONCE per rendered
#     frame via player.apply_look_delta — camera motion happens at
#     render cadence regardless of the touch event rate.
#   • No smoothing/inertia filter: filtering trades latency for polish
#     and drag-look reads "floaty" with even one frame of lag. 1:1 raw,
#     like Pocket Edition.
#   • Sensitivity is normalized by viewport height so a full-height drag
#     pitches the same number of degrees on every device/DPI; the scale
#     is recomputed only on size_changed, never per frame.
#
# Gestures on the look finger (classic Pocket Edition):
#   tap (short, under slop)        → interact_place (place / use)
#   hold still ~0.3 s              → interact_break held (mine) — or
#                                    interact_place held when the
#                                    selected item wants hold-to-use
#                                    (bow charge, eating)
#   drag any time                  → look; mining keeps running
#
# Everything else feeds the existing InputMap: the joystick writes
# analog strengths the player's Input.get_vector already consumes, and
# buttons parse InputEventAction so edge handlers (is_action_pressed
# in _unhandled_input) fire exactly as they do for keys.

const LOOK_DEGREES_PER_SCREEN_HEIGHT: float = 130.0
# Joystick's own deadzone (thumb jitter), in deflection fraction.
const JOY_DEADZONE: float = 0.18
# get_vector() applies the actions' default 0.5 deadzone to the COMPOSED
# vector length. Emitting strengths below that would zero out deliberate
# walking, so deflection past JOY_DEADZONE maps into [0.55, 1.0] —
# get_vector's remap then yields a usable 10%..100% analog speed range.
const JOY_STRENGTH_FLOOR: float = 0.55
const TAP_MAX_MS: int = 240
const HOLD_ACT_MS: int = 280
# Finger travel allowed before a press stops counting as tap/hold and
# becomes pure look, as a fraction of viewport height (~32 px at 1080).
const TAP_SLOP_FRAC: float = 0.03
# How long interact_place stays "pressed" for a tap — single-tick place
# handlers fire on the press edge, but one frame is cutting it fine.
const PLACE_TAP_HOLD_S: float = 0.1
const FS_RETRY_MS: int = 3000

const _MOVE_ACTIONS: Array[String] = ["move_left", "move_right", "move_forward", "move_back"]
const _COL_IDLE := Color(1.0, 1.0, 1.0, 0.32)
const _COL_ACTIVE := Color(1.0, 1.0, 1.0, 0.65)
const _COL_FILL := Color(1.0, 1.0, 1.0, 0.18)
const _LINE_W: float = 3.0

# Browsers only honor fullscreen + orientation lock from inside a user
# gesture, which Godot's web input callbacks run within. iOS Safari has
# neither API on iPhone — both promises reject and the RotateOverlay
# carries the UX instead.
const _JS_FULLSCREEN_LANDSCAPE: String = """
(function () {
	if (document.fullscreenElement) { return; }
	var el = document.documentElement;
	if (!el.requestFullscreen) { return; }
	el.requestFullscreen({ navigationUI: "hide" }).then(function () {
		if (screen.orientation && screen.orientation.lock) {
			screen.orientation.lock("landscape").catch(function () {});
		}
	}).catch(function () {});
})();
"""

var _player: CharacterBody3D

# Look state. Accumulator drains once per _process tick.
var _look_finger: int = -1
var _look_accum := Vector2.ZERO
var _look_travel: float = 0.0
var _look_start_ms: int = 0
var _look_breaking: bool = false
var _look_using: bool = false
var _look_rad_per_px: float = 0.0

# Floating joystick: origin spawns where the finger lands in the zone.
var _joy_finger: int = -1
var _joy_origin := Vector2.ZERO
var _joy_vec := Vector2.ZERO

var _jump_finger: int = -1
var _sneak_on: bool = false
var _place_release_left: float = 0.0
var _blocked: bool = true
var _fs_last_attempt_ms: int = -FS_RETRY_MS

# Layout cache — recomputed on viewport resize only.
var _vp := Vector2.ZERO
var _joy_rest := Vector2.ZERO
var _joy_radius: float = 0.0
var _joy_zone := Rect2()
var _jump_center := Vector2.ZERO
var _jump_radius: float = 0.0
var _sneak_rect := Rect2()
var _pause_rect := Rect2()
var _inv_rect := Rect2()
var _hotbar_rect := Rect2()
var _tap_slop: float = 0.0
var _hotbar_node: Control


func setup(player: CharacterBody3D) -> void:
	_player = player


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Never participate in GUI picking — taps reach inventory screens via
	# the emulated mouse; this layer listens to raw touches in _input.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_viewport().size_changed.connect(_layout)
	_layout()


func _layout() -> void:
	_vp = get_viewport().get_visible_rect().size
	if _vp.y <= 0.0:
		return
	var u: float = _vp.y * 0.01
	_look_rad_per_px = deg_to_rad(LOOK_DEGREES_PER_SCREEN_HEIGHT) / _vp.y
	_tap_slop = _vp.y * TAP_SLOP_FRAC
	_joy_rest = Vector2(_vp.x * 0.17, _vp.y * 0.68)
	_joy_radius = 11.0 * u
	_joy_zone = Rect2(0.0, _vp.y * 0.20, _vp.x * 0.45, _vp.y * 0.80)
	_jump_center = Vector2(_vp.x * 0.90, _vp.y * 0.60)
	_jump_radius = 8.0 * u
	var sneak_size: float = 9.0 * u
	_sneak_rect = Rect2(
		Vector2(_vp.x * 0.80 - sneak_size * 0.5, _vp.y * 0.78 - sneak_size * 0.5),
		Vector2(sneak_size, sneak_size)
	)
	var btn: float = 8.0 * u
	_pause_rect = Rect2(Vector2(_vp.x - btn - 2.0 * u, 2.0 * u), Vector2(btn, btn))
	_inv_rect = Rect2(Vector2(_vp.x - 2.0 * btn - 4.0 * u, 2.0 * u), Vector2(btn, btn))
	_refresh_hotbar_rect()
	queue_redraw()


# The Hotbar sibling may not exist yet at our _ready (scene order), and
# its rect moves on resize — resolve lazily and re-pad on each layout.
func _refresh_hotbar_rect() -> void:
	if _hotbar_node == null or not is_instance_valid(_hotbar_node):
		var crosshair: Node = get_parent()
		if crosshair != null:
			_hotbar_node = crosshair.get_node_or_null("Hotbar") as Control
	if _hotbar_node != null:
		_hotbar_rect = _hotbar_node.get_global_rect().grow(_vp.y * 0.01)
	else:
		_hotbar_rect = Rect2()


func _input(event: InputEvent) -> void:
	if _player == null:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_on_press(event)
		else:
			_on_release(event)
	elif event is InputEventScreenDrag:
		_on_drag(event)


func _on_press(event: InputEventScreenTouch) -> void:
	var pos: Vector2 = event.position
	var owned: bool = true
	# Pause / inventory taps work even while a screen is open — "pause"
	# doubles as the close-screen action in player._unhandled_input, and
	# without a live button there's no Esc on a phone to escape with.
	if _pause_rect.has_point(pos):
		_tap_action("pause")
	elif _inv_rect.has_point(pos):
		_tap_action("toggle_inventory")
	elif _blocked:
		# A screen owns input: leave every other touch alone so its
		# emulated mouse drives the GUI normally.
		owned = false
	else:
		_try_fullscreen_lock()
		owned = _press_gameplay(event, pos)
	if owned:
		get_viewport().set_input_as_handled()


# Hit-tests in priority order: HUD widgets claim the finger before the
# zones, the joystick zone before the look fallback. Returns whether the
# touch was claimed.
func _press_gameplay(event: InputEventScreenTouch, pos: Vector2) -> bool:
	if _hotbar_rect != Rect2() and _hotbar_rect.has_point(pos):
		var frac: float = (pos.x - _hotbar_rect.position.x) / _hotbar_rect.size.x
		var slot: int = clampi(int(frac * 9.0), 0, 8)
		_tap_action("hotbar_%d" % (slot + 1))
		return true
	if pos.distance_to(_jump_center) <= _jump_radius * 1.25 and _jump_finger == -1:
		_jump_finger = event.index
		_send_action("jump", true)
		queue_redraw()
		return true
	if _sneak_rect.has_point(pos):
		_sneak_on = not _sneak_on
		_send_action("sneak", _sneak_on)
		queue_redraw()
		return true
	if _joy_zone.has_point(pos) and _joy_finger == -1:
		_joy_finger = event.index
		_joy_origin = pos
		_joy_vec = Vector2.ZERO
		queue_redraw()
		return true
	if _look_finger == -1:
		_look_finger = event.index
		_look_accum = Vector2.ZERO
		_look_travel = 0.0
		_look_start_ms = Time.get_ticks_msec()
		_look_breaking = false
		_look_using = false
		return true
	return false


func _on_release(event: InputEventScreenTouch) -> void:
	if event.index == _jump_finger:
		_jump_finger = -1
		_send_action("jump", false)
		queue_redraw()
	elif event.index == _joy_finger:
		_joy_finger = -1
		_joy_vec = Vector2.ZERO
		_release_move_axes()
		queue_redraw()
	elif event.index == _look_finger:
		_look_finger = -1
		if _look_breaking:
			_look_breaking = false
			_send_action("interact_break", false)
		elif _look_using:
			_look_using = false
			_send_action("interact_place", false)
		elif Time.get_ticks_msec() - _look_start_ms <= TAP_MAX_MS and _look_travel <= _tap_slop:
			# Quick tap → place/use. Held for a beat (not released same
			# frame) so press-edge handlers can't race the release.
			_send_action("interact_place", true)
			_place_release_left = PLACE_TAP_HOLD_S


func _on_drag(event: InputEventScreenDrag) -> void:
	if event.index == _look_finger:
		_look_accum += event.relative
		_look_travel += event.relative.length()
		get_viewport().set_input_as_handled()
	elif event.index == _joy_finger:
		var v: Vector2 = (event.position - _joy_origin) / _joy_radius
		_joy_vec = v.limit_length(1.0)
		get_viewport().set_input_as_handled()
		queue_redraw()


func _process(delta: float) -> void:
	if _player == null:
		return
	# Deferred release for tap-place runs even while blocked — leaving
	# interact_place latched on while an inventory opens would charge
	# bows forever.
	if _place_release_left > 0.0:
		_place_release_left -= delta
		if _place_release_left <= 0.0:
			_send_action("interact_place", false)
	var blocked: bool = _compute_blocked()
	if blocked != _blocked:
		_blocked = blocked
		if blocked:
			_release_all()
		queue_redraw()
	if _blocked:
		return
	if _hotbar_node == null:
		_refresh_hotbar_rect()
	# --- Look: drain the accumulator exactly once per rendered frame. ---
	if _look_accum != Vector2.ZERO:
		_player.apply_look_delta(_look_accum * _look_rad_per_px)
		_look_accum = Vector2.ZERO
	# Hold-still gesture matured → start mining (or charging/eating when
	# the held item wants hold-to-use, mirroring Pocket Edition).
	if (
		_look_finger != -1
		and not _look_breaking
		and not _look_using
		and _look_travel <= _tap_slop
		and Time.get_ticks_msec() - _look_start_ms >= HOLD_ACT_MS
	):
		if _player.touch_hold_prefers_use():
			_look_using = true
			_send_action("interact_place", true)
		else:
			_look_breaking = true
			_send_action("interact_break", true)
	if _joy_finger != -1:
		_apply_move_axes()


func _compute_blocked() -> bool:
	# Portrait on mobile web = RotateOverlay is up; don't fight it.
	if _vp.y > _vp.x:
		return true
	if float(_player.get("health")) <= 0.0:
		return true
	if bool(_player.get("is_sleeping")):
		return true
	return bool(_player.call("is_any_screen_open"))


func _apply_move_axes() -> void:
	var deflection: float = _joy_vec.length()
	if deflection < JOY_DEADZONE:
		_release_move_axes()
		return
	var t: float = (deflection - JOY_DEADZONE) / (1.0 - JOY_DEADZONE)
	var magnitude: float = JOY_STRENGTH_FLOOR + (1.0 - JOY_STRENGTH_FLOOR) * t
	var dir: Vector2 = _joy_vec / deflection
	_set_axis("move_left", maxf(0.0, -dir.x) * magnitude)
	_set_axis("move_right", maxf(0.0, dir.x) * magnitude)
	_set_axis("move_forward", maxf(0.0, -dir.y) * magnitude)
	_set_axis("move_back", maxf(0.0, dir.y) * magnitude)


func _set_axis(action: String, strength: float) -> void:
	# Fully release the zero side instead of pressing with strength 0 —
	# is_action_pressed("move_forward") gates ladder climbing, and a
	# zero-strength "pressed" state would climb every ladder touched.
	if strength > 0.0:
		Input.action_press(action, strength)
	else:
		Input.action_release(action)


func _release_move_axes() -> void:
	for action: String in _MOVE_ACTIONS:
		Input.action_release(action)


func _release_all() -> void:
	if _jump_finger != -1:
		_jump_finger = -1
		_send_action("jump", false)
	if _joy_finger != -1:
		_joy_finger = -1
		_joy_vec = Vector2.ZERO
	_release_move_axes()
	if _look_breaking:
		_look_breaking = false
		_send_action("interact_break", false)
	if _look_using:
		_look_using = false
		_send_action("interact_place", false)
	_look_finger = -1
	_look_accum = Vector2.ZERO
	if _sneak_on:
		_sneak_on = false
		_send_action("sneak", false)


# InputEventAction through parse_input_event — unlike Input.action_press
# it flows through the scene-tree input pipeline, so the edge handlers
# (event.is_action_pressed in player/interaction _unhandled_input) fire
# exactly as they do for a key. Allocates one event per EDGE, never per
# frame.
func _send_action(action: String, pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _tap_action(action: String) -> void:
	_send_action(action, true)
	_send_action(action, false)


func _try_fullscreen_lock() -> void:
	if not Game.is_mobile_web():
		return
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		return
	var now: int = Time.get_ticks_msec()
	if now - _fs_last_attempt_ms < FS_RETRY_MS:
		return
	_fs_last_attempt_ms = now
	JavaScriptBridge.eval(_JS_FULLSCREEN_LANDSCAPE, true)


func _draw() -> void:
	_draw_square_button(_pause_rect, false)
	_draw_pause_glyph(_pause_rect)
	_draw_square_button(_inv_rect, false)
	_draw_inventory_glyph(_inv_rect)
	if _blocked:
		return
	# Joystick — resting hint when idle, live base + nub while steering.
	var origin: Vector2 = _joy_origin if _joy_finger != -1 else _joy_rest
	var col: Color = _COL_ACTIVE if _joy_finger != -1 else _COL_IDLE
	draw_arc(origin, _joy_radius, 0.0, TAU, 48, col, _LINE_W)
	if _joy_finger != -1:
		draw_circle(origin + _joy_vec * _joy_radius, _joy_radius * 0.38, _COL_ACTIVE)
	else:
		draw_circle(origin, _joy_radius * 0.30, _COL_FILL)
	# Jump — circle with an up chevron.
	var jump_col: Color = _COL_ACTIVE if _jump_finger != -1 else _COL_IDLE
	if _jump_finger != -1:
		draw_circle(_jump_center, _jump_radius, _COL_FILL)
	draw_arc(_jump_center, _jump_radius, 0.0, TAU, 48, jump_col, _LINE_W)
	var jr: float = _jump_radius * 0.40
	var chevron_up := PackedVector2Array(
		[
			_jump_center + Vector2(-jr, jr * 0.6),
			_jump_center + Vector2(0.0, -jr * 0.6),
			_jump_center + Vector2(jr, jr * 0.6),
		]
	)
	draw_polyline(chevron_up, jump_col, _LINE_W)
	# Sneak — square with a down chevron; filled while toggled on.
	var sneak_col: Color = _COL_ACTIVE if _sneak_on else _COL_IDLE
	if _sneak_on:
		draw_rect(_sneak_rect, _COL_FILL)
	_draw_square_button(_sneak_rect, _sneak_on)
	var sc: Vector2 = _sneak_rect.get_center()
	var sr: float = _sneak_rect.size.x * 0.22
	var chevron_down := PackedVector2Array(
		[
			sc + Vector2(-sr, -sr * 0.6),
			sc + Vector2(0.0, sr * 0.6),
			sc + Vector2(sr, -sr * 0.6),
		]
	)
	draw_polyline(chevron_down, sneak_col, _LINE_W)


func _draw_square_button(rect: Rect2, active: bool) -> void:
	if rect == Rect2():
		return
	draw_rect(rect, _COL_ACTIVE if active else _COL_IDLE, false, _LINE_W)


func _draw_pause_glyph(rect: Rect2) -> void:
	var c: Vector2 = rect.get_center()
	var h: float = rect.size.y * 0.36
	var w: float = rect.size.x * 0.10
	var gap: float = rect.size.x * 0.12
	draw_rect(Rect2(c + Vector2(-gap - w, -h * 0.5), Vector2(w, h)), _COL_IDLE)
	draw_rect(Rect2(c + Vector2(gap, -h * 0.5), Vector2(w, h)), _COL_IDLE)


func _draw_inventory_glyph(rect: Rect2) -> void:
	var c: Vector2 = rect.get_center()
	var cell: float = rect.size.x * 0.16
	var gap: float = rect.size.x * 0.10
	for gx in range(2):
		for gy in range(2):
			var off := Vector2(
				(gx - 1) * cell + (gx - 0.5) * gap, (gy - 1) * cell + (gy - 0.5) * gap
			)
			draw_rect(Rect2(c + off, Vector2(cell, cell)), _COL_IDLE)
