extends ColorRect

# Beta-style sleep fade. Reads the player's `sleep_ticks` field each
# frame and modulates this Control's alpha to drive a fade-to-black /
# fade-back when the player sleeps. The actual time skip + auto-wake
# happen in Player._tick_sleep — this overlay is render-only.
#
# Vanilla EntityHuman ticks `sleepTicks` from 0..100 while sleeping
# (overlay opacity rises) then 100..110 after wake (overlay fades
# back). We hold full black between SLEEP_PHASE (50) and SLEEP_CAP
# (100) so the world has a visibly dark window during the time skip,
# then fade out smoothly.

# Vanilla reference points (in vanilla `ticks` units, ×20 wall seconds):
#   sleep_ticks    visible behavior
#       0..50      fade IN from 0 to full black (linear)
#      50..100     hold full black
#     100..110     fade OUT from full black to 0 (linear)
const _PHASE_TICKS: float = 50.0
const _CAP_TICKS: float = 100.0
const _WAKE_TICKS: float = 110.0

var _player: Node3D = null


func _ready() -> void:
	# Fullscreen black. mouse_filter ignores so input passes through to
	# the UI underneath (chat HUD, pause menu, etc.) — vanilla's sleep
	# overlay doesn't gate input either.
	color = Color(0.0, 0.0, 0.0, 0.0)
	mouse_filter = MOUSE_FILTER_IGNORE
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0


func _process(_delta: float) -> void:
	var p: Node3D = _get_player()
	if p == null:
		_set_alpha(0.0)
		return
	if not ("sleep_ticks" in p):
		_set_alpha(0.0)
		return
	var ticks: float = float(p.get("sleep_ticks"))
	if ticks <= 0.0:
		_set_alpha(0.0)
		return
	var alpha: float
	if ticks < _PHASE_TICKS:
		# Fade-in: linear 0 → 1 over 50 ticks.
		alpha = ticks / _PHASE_TICKS
	elif ticks <= _CAP_TICKS:
		# Hold full black during the time-skip window.
		alpha = 1.0
	elif ticks < _WAKE_TICKS:
		# Fade-out: linear 1 → 0 over the post-wake 10-tick window.
		alpha = 1.0 - (ticks - _CAP_TICKS) / (_WAKE_TICKS - _CAP_TICKS)
	else:
		alpha = 0.0
	_set_alpha(clampf(alpha, 0.0, 1.0))


# Cached player reference. Lookup-deferred since the overlay starts
# before the player scene mounts.
func _get_player() -> Node3D:
	if _player != null and is_instance_valid(_player):
		return _player
	var main: Node = get_tree().root.get_node_or_null("Main")
	if main == null:
		return null
	_player = main.find_child("Player", true, false) as Node3D
	return _player


func _set_alpha(a: float) -> void:
	if not is_equal_approx(color.a, a):
		color = Color(0.0, 0.0, 0.0, a)
