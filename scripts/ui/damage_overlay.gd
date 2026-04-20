extends ColorRect

# Vanilla MC's "hurtTime" red flash. GuiIngame renders a red-tinted
# fullscreen quad while hurtTime > 0; our equivalent is this ColorRect
# with alpha fading 0.4 → 0 over HURT_DURATION_SEC. Fires on
# player.damaged.

const HURT_DURATION_SEC: float = 0.5
const PEAK_ALPHA: float = 0.4

var _remaining: float = 0.0
var _player: Node


func _ready() -> void:
	color = Color(0.8, 0.1, 0.1, 0.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_player = get_tree().root.get_node_or_null("Main/Player")
	if _player != null and _player.has_signal("damaged"):
		_player.damaged.connect(_on_damaged)


func _process(delta: float) -> void:
	if _remaining <= 0.0:
		if color.a > 0.0:
			color.a = 0.0
		return
	_remaining -= delta
	# Linear fadeout from PEAK_ALPHA → 0.
	var ratio: float = maxf(_remaining / HURT_DURATION_SEC, 0.0)
	color.a = PEAK_ALPHA * ratio


func _on_damaged(_amount: int, _source: String) -> void:
	_remaining = HURT_DURATION_SEC
	color.a = PEAK_ALPHA
