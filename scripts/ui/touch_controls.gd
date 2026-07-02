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
# Long-press a hotbar slot to drop one item from it (mobile stand-in
# for desktop Q). The press already selected the slot, so firing
# drop_selected targets exactly the held-down slot.
const HOTBAR_DROP_HOLD_MS: int = 500
# Finger travel allowed before a press stops counting as tap/hold and
# becomes pure look, as a fraction of viewport height (~32 px at 1080).
const TAP_SLOP_FRAC: float = 0.03
# How long interact_place stays "pressed" for a tap — single-tick place
# handlers fire on the press edge, but one frame is cutting it fine.
const PLACE_TAP_HOLD_S: float = 0.1

const _MOVE_ACTIONS: Array[String] = ["move_left", "move_right", "move_forward", "move_back"]
const _COL_IDLE := Color(1.0, 1.0, 1.0, 0.55)
const _COL_ACTIVE := Color(1.0, 1.0, 1.0, 0.9)
const _COL_FILL := Color(1.0, 1.0, 1.0, 0.22)
# Dark translucent halo under every HUD element. White strokes alone
# vanished against bright sky; a backing plate + under-stroke keeps the
# HUD readable on any background without blocking much of the view.
const _COL_BACKING := Color(0.0, 0.0, 0.0, 0.28)
const _COL_UNDERSTROKE := Color(0.0, 0.0, 0.0, 0.35)
const _LINE_W: float = 3.0

# Touch look sensitivity multiplier on LOOK_DEGREES_PER_SCREEN_HEIGHT.
# Loaded from settings.cfg [controls] in _ready; the in-game options
# slider writes it live. Static so the options screen can set it
# without holding a node reference.
static var look_sensitivity: float = 1.0

var _player: CharacterBody3D

# Look state. Accumulator drains once per _process tick.
var _look_finger: int = -1
var _look_accum := Vector2.ZERO
# Last observed position of the look finger. Look deltas are computed
# from POSITIONS, never from InputEventScreenDrag.relative: on Android
# Chrome, touch indices are recycled across contacts, and a mis-ordered
# release lets the engine-side relative span from the OLD contact's
# last position to the NEW one — a single phantom drag worth hundreds
# of degrees ("view snaps back after turning", measured 236-273° on
# device). Position deltas within one claimed contact can't jump.
var _look_prev_pos := Vector2.ZERO
var _look_travel: float = 0.0
var _look_start_ms: int = 0
var _look_breaking: bool = false
var _look_using: bool = false
var _look_rad_per_px: float = 0.0

# Floating joystick: origin spawns where the finger lands in the zone.
var _joy_finger: int = -1
var _joy_origin := Vector2.ZERO
var _joy_vec := Vector2.ZERO
# Last strength sent per move action (quantized). Lets _set_axis skip
# re-sending an unchanged value — a held-still thumb costs zero events
# per frame; only actual thumb movement allocates.
var _sent_move_strengths: Dictionary = {}

var _jump_finger: int = -1
# Hotbar long-press → drop tracking. Fires drop_selected once per press
# after HOTBAR_DROP_HOLD_MS; release re-arms.
var _hotbar_finger: int = -1
var _hotbar_press_ms: int = 0
var _hotbar_drop_fired: bool = false
var _sneak_on: bool = false
var _place_release_left: float = 0.0
var _blocked: bool = true

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
# Fullscreen ENTER button (top-right, windowed only). Zero rect when
# the browser has no Fullscreen API (iPhone Safari, native builds) or
# while already fullscreen (hidden — system gesture exits).
var _fs_rect := Rect2()
var _fs_available: bool = false
var _fs_visible: bool = false
var _hotbar_rect := Rect2()
var _tap_slop: float = 0.0
var _hotbar_node: Control


func setup(player: CharacterBody3D) -> void:
	_player = player


func _ready() -> void:
	look_sensitivity = float(
		SettingsMenu.load_config().get_value("controls", "touch_look_sensitivity", 1.0)
	)
	# Screens' touch gesture layer resolves us through this group to ask
	# owns_hud_point (see TouchSlotGestures._hud_owns).
	add_to_group("touch_controls")
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
	# Menu buttons hug the BOTTOM-right corner — thumb-reachable and
	# away from the sky, where light-on-light lines washed out. Order
	# left→right: inventory, pause.
	var btn: float = 8.0 * u
	var btn_y: float = _vp.y - btn - 2.0 * u
	_pause_rect = Rect2(Vector2(_vp.x - btn - 2.0 * u, btn_y), Vector2(btn, btn))
	_inv_rect = Rect2(Vector2(_vp.x - 2.0 * btn - 4.0 * u, btn_y), Vector2(btn, btn))
	# Fullscreen ENTER button lives alone at the TOP-right and only shows
	# while windowed — once fullscreen it disappears (exit = the system
	# back gesture, or the settings checkbox). Only where the browser
	# exposes the API (Android Chrome yes, iPhone Safari no). Entering /
	# exiting fullscreen always resizes the viewport, so _layout re-runs
	# and _fs_visible stays truthful without polling.
	_fs_available = Game.web_fullscreen_available()
	_fs_visible = _fs_available and not Game.web_is_fullscreen()
	if _fs_visible:
		_fs_rect = Rect2(Vector2(_vp.x - btn - 2.0 * u, 2.0 * u), Vector2(btn, btn))
	else:
		_fs_rect = Rect2()
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


# True when a viewport point lands on the always-live HUD buttons
# (pause / inventory). UI screens' tap-outside-to-close checks this so
# a tap on those buttons doesn't both close-via-outside AND toggle —
# which would re-open the screen in the same gesture.
func owns_hud_point(pos: Vector2) -> bool:
	if _fs_visible and _fs_rect.has_point(pos):
		return true
	return _pause_rect.has_point(pos) or _inv_rect.has_point(pos)


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
	# Fullscreen can change without a viewport resize in some
	# environments (emulated viewports; desktop F11) — re-check on each
	# press so the enter button's visibility tracks reality.
	if _fs_available and _fs_visible == Game.web_is_fullscreen():
		_layout()
	# Index-collision purge: a NEW press on an index proves the previous
	# contact using it ended, even if its release event never arrived
	# (Android gesture-nav and event coalescing can swallow touchends —
	# the root of the "view snaps back" phantom-drag bug: the stale look
	# binding routed the next finger's drags into the look accumulator).
	if event.index == _look_finger:
		_look_finger = -1
		_look_accum = Vector2.ZERO
		if _look_breaking:
			_look_breaking = false
			_send_action("interact_break", false)
		if _look_using:
			_look_using = false
			_send_action("interact_place", false)
	if event.index == _joy_finger:
		_joy_finger = -1
		_joy_vec = Vector2.ZERO
		_release_move_axes()
	if event.index == _jump_finger:
		_jump_finger = -1
		_send_action("jump", false)
	if event.index == _hotbar_finger:
		_hotbar_finger = -1
	var pos: Vector2 = event.position
	var owned: bool = true
	# Pause / inventory taps work even while a screen is open — "pause"
	# doubles as the close-screen action in player._unhandled_input, and
	# without a live button there's no Esc on a phone to escape with.
	if _pause_rect.has_point(pos):
		_tap_action("pause")
	elif _inv_rect.has_point(pos):
		_tap_action("toggle_inventory")
	elif _fs_visible and _fs_rect.has_point(pos):
		# Enter-only (the button hides while fullscreen; the system back
		# gesture or the settings checkbox exits). Explicitly entering
		# also re-arms Game's first-gesture auto-fullscreen.
		Game.web_set_fullscreen(true)
		Game.fullscreen_user_opt_out = false
		queue_redraw()
	elif _blocked:
		# A screen owns input: leave every other touch alone so its
		# emulated mouse drives the GUI normally.
		owned = false
	else:
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
		# Arm the long-press drop timer — the tap above already selected
		# the slot, so drop_selected (fired from _process after
		# HOTBAR_DROP_HOLD_MS) targets the slot under the finger.
		_hotbar_finger = event.index
		_hotbar_press_ms = Time.get_ticks_msec()
		_hotbar_drop_fired = false
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
	if pos.distance_to(_joy_rest) <= _joy_radius * 2.2 and _joy_finger == -1:
		_joy_finger = event.index
		# FIXED-position stick: the ring stays at its resting spot and
		# deflection is measured from there. The earlier floating origin
		# (ring re-anchoring to wherever the finger landed) read as the
		# stick "jumping" on activation. Grab area = 2.2× the ring radius
		# around the rest spot — presses farther out stay look-drags, so
		# the left half of the screen still works for camera. Seeding
		# _joy_vec from the press point starts walking immediately on an
		# off-center grab.
		_joy_origin = _joy_rest
		_joy_vec = ((pos - _joy_origin) / _joy_radius).limit_length(1.0)
		queue_redraw()
		return true
	if _look_finger == -1:
		_look_finger = event.index
		_look_accum = Vector2.ZERO
		_look_prev_pos = pos
		_look_travel = 0.0
		_look_start_ms = Time.get_ticks_msec()
		_look_breaking = false
		_look_using = false
		return true
	return false


func _on_release(event: InputEventScreenTouch) -> void:
	if event.index == _hotbar_finger:
		_hotbar_finger = -1
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
		# Position-derived delta — see _look_prev_pos for why the
		# engine-supplied `relative` can't be trusted on Android web.
		var rel: Vector2 = event.position - _look_prev_pos
		_look_prev_pos = event.position
		_look_accum += rel
		_look_travel += rel.length()
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
		var delta_angles: Vector2 = _look_accum * _look_rad_per_px * look_sensitivity
		_look_accum = Vector2.ZERO
		# Safety net: no humanly-possible flick exceeds ~100° in ONE
		# frame at our sensitivity (even at 3 fps a violent 180°-in-half-
		# a-second turn peaks ~60°/frame). Anything bigger is a phantom
		# from the recycled-index family that slipped the other guards.
		if absf(delta_angles.x) > 1.75 or absf(delta_angles.y) > 1.75:
			print("[look-diag] dropped phantom delta %.0f deg" % rad_to_deg(delta_angles.x))
		else:
			_player.apply_look_delta(delta_angles)
	# Hotbar long-press → drop one item from the held-down slot.
	if _hotbar_finger != -1 and not _hotbar_drop_fired:
		if Time.get_ticks_msec() - _hotbar_press_ms >= HOTBAR_DROP_HOLD_MS:
			_hotbar_drop_fired = true
			_tap_action("drop_selected")
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
	# Route through parse_input_event(InputEventAction), NOT
	# Input.action_press/action_release: on the web export the
	# action_press state never reached player.gd's Input.get_vector
	# (joystick tracked visually but the body stood still), while every
	# _send_action-driven action (jump / break / pause) worked in the
	# same build. InputEventAction carries strength, so the analog
	# walk-speed range is preserved.
	#
	# Quantize + dedupe so a held-still thumb sends nothing — events
	# only fire when the value actually changes (see _sent_move_strengths).
	var quantized: float = snappedf(strength, 1.0 / 64.0)
	var prev: float = _sent_move_strengths.get(action, 0.0)
	if quantized == prev:
		return
	_sent_move_strengths[action] = quantized
	var ev := InputEventAction.new()
	ev.action = action
	# Fully release the zero side instead of pressing with strength 0 —
	# is_action_pressed("move_forward") gates ladder climbing, and a
	# zero-strength "pressed" state would climb every ladder touched.
	if quantized > 0.0:
		ev.pressed = true
		ev.strength = quantized
	else:
		ev.pressed = false
	Input.parse_input_event(ev)


func _release_move_axes() -> void:
	for action: String in _MOVE_ACTIONS:
		_set_axis(action, 0.0)


func _release_all() -> void:
	_hotbar_finger = -1
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


func _draw() -> void:
	_draw_square_button(_pause_rect, false)
	_draw_pause_glyph(_pause_rect)
	_draw_square_button(_inv_rect, false)
	_draw_inventory_glyph(_inv_rect)
	if _fs_visible:
		_draw_square_button(_fs_rect, false)
		_draw_fullscreen_glyph(_fs_rect, false)
	if _blocked:
		return
	# Joystick — resting hint when idle, live base + nub while steering.
	# Dark under-stroke behind the ring keeps it visible against sky.
	var origin: Vector2 = _joy_origin if _joy_finger != -1 else _joy_rest
	var col: Color = _COL_ACTIVE if _joy_finger != -1 else _COL_IDLE
	draw_arc(origin, _joy_radius, 0.0, TAU, 48, _COL_UNDERSTROKE, _LINE_W * 2.4)
	draw_arc(origin, _joy_radius, 0.0, TAU, 48, col, _LINE_W)
	if _joy_finger != -1:
		draw_circle(origin + _joy_vec * _joy_radius, _joy_radius * 0.44, _COL_UNDERSTROKE)
		draw_circle(origin + _joy_vec * _joy_radius, _joy_radius * 0.38, _COL_ACTIVE)
	else:
		draw_circle(origin, _joy_radius * 0.36, _COL_UNDERSTROKE)
		draw_circle(origin, _joy_radius * 0.30, _COL_FILL)
	# Jump — circle with an up chevron over a dark backing disc.
	var jump_col: Color = _COL_ACTIVE if _jump_finger != -1 else _COL_IDLE
	draw_circle(_jump_center, _jump_radius, _COL_BACKING)
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
	# Sneak — labeled button ("SNEAK" in the MC font); filled while
	# toggled on. A down-chevron mis-read as "move down" next to jump's
	# up-chevron, and glyph experiments read worse — text is unambiguous.
	var sneak_col: Color = _COL_ACTIVE if _sneak_on else _COL_IDLE
	if _sneak_on:
		draw_rect(_sneak_rect, _COL_FILL)
	_draw_square_button(_sneak_rect, _sneak_on)
	var mc_font: Font = MinecraftFont.get_font()
	if mc_font != null:
		var fs: int = maxi(10, int(_sneak_rect.size.y * 0.26))
		draw_string(
			mc_font,
			Vector2(_sneak_rect.position.x, _sneak_rect.get_center().y + fs * 0.38),
			"SNEAK",
			HORIZONTAL_ALIGNMENT_CENTER,
			_sneak_rect.size.x,
			fs,
			sneak_col
		)


func _draw_square_button(rect: Rect2, active: bool) -> void:
	if rect == Rect2():
		return
	draw_rect(rect, _COL_BACKING)
	draw_rect(rect, _COL_ACTIVE if active else _COL_IDLE, false, _LINE_W)


func _draw_pause_glyph(rect: Rect2) -> void:
	var c: Vector2 = rect.get_center()
	var h: float = rect.size.y * 0.36
	var w: float = rect.size.x * 0.10
	var gap: float = rect.size.x * 0.12
	draw_rect(Rect2(c + Vector2(-gap - w, -h * 0.5), Vector2(w, h)), _COL_IDLE)
	draw_rect(Rect2(c + Vector2(gap, -h * 0.5), Vector2(w, h)), _COL_IDLE)


# Four corner brackets. Not fullscreen → brackets hug the button's
# corners opening inward ("expand"); fullscreen → brackets pulled toward
# the center opening outward ("contract"), the familiar exit icon.
func _draw_fullscreen_glyph(rect: Rect2, is_fullscreen: bool) -> void:
	var arm: float = rect.size.x * 0.16
	var inset: float = rect.size.x * 0.26
	var pull: float = rect.size.x * (0.12 if is_fullscreen else 0.0)
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner: Vector2 = (
				rect.get_center()
				+ Vector2(
					sx * (rect.size.x * 0.5 - inset - pull), sy * (rect.size.y * 0.5 - inset - pull)
				)
			)
			var dir_x: float = -sx if is_fullscreen else sx
			var dir_y: float = -sy if is_fullscreen else sy
			draw_line(corner, corner + Vector2(-dir_x * arm, 0), _COL_IDLE, _LINE_W)
			draw_line(corner, corner + Vector2(0, -dir_y * arm), _COL_IDLE, _LINE_W)


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
