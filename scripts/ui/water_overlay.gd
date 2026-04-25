extends ColorRect

# Vanilla MC underwater blue tint — when the player's head is submerged,
# the world dims toward a saturated blue. In vanilla this is a combination
# of GL_FOG with a WATER color and a full-screen viewport tint; we fake it
# with a full-screen ColorRect that fades in when the player's eye cell is
# water. Color sampled from vanilla a1.2.6's water fog (RGB ~(32, 74, 178)).
#
# Uses the player's `head_submerged_changed(bool)` signal so the overlay
# only repaints on actual transitions, not every frame.

const TINT_COLOR: Color = Color(0.08, 0.20, 0.50, 0.55)
const FADE_TIME: float = 0.25  # seconds — quick but not instant

var _target_alpha: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Full-screen overlay sized by the scene's anchor, but force the color
	# here so the default red damage overlay hex doesn't get baked in.
	color = Color(TINT_COLOR.r, TINT_COLOR.g, TINT_COLOR.b, 0.0)
	var player: Node = get_tree().root.get_node_or_null("Main/Player")
	if player != null and player.has_signal("head_submerged_changed"):
		player.head_submerged_changed.connect(_on_head_submerged_changed)


func _on_head_submerged_changed(submerged: bool) -> void:
	_target_alpha = TINT_COLOR.a if submerged else 0.0


func _process(delta: float) -> void:
	if is_equal_approx(color.a, _target_alpha):
		return
	var step: float = (TINT_COLOR.a / FADE_TIME) * delta
	var new_a: float = move_toward(color.a, _target_alpha, step)
	color = Color(TINT_COLOR.r, TINT_COLOR.g, TINT_COLOR.b, new_a)
