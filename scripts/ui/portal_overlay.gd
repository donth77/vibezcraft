extends TextureRect

# Vanilla's in-portal screen overlay — the purple that closes in as the
# exposure meter fills. Alpha's GuiIngame draws the portal block's
# ANIMATED texture over the whole screen at alpha equal to the meter
# (interpolated `timeInPortal`), so standing in a portal reads as being
# swallowed rather than as waiting out a timer, and arriving in the
# other dimension opens on a one-second purple fade-out as the meter
# drains at 0.05/tick.
#
# Required by plan §7.1 ("Add the screen overlay/transition effect…")
# and missed by Batch 7 — the audit's seam-focused pass missed it too;
# it surfaced when re-checking the shipped feature line-by-line against
# the plan's presentation requirements.
#
# Same shape as the other HUD overlays in crosshair.tscn: a full-rect
# node that polls Main/Player each frame. The texture is the shared
# PortalTexture frame set — no new resources, and the animation stays on
# vanilla's one-frame-per-tick cadence via frame_at().

var _player: Node = null
var _elapsed: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	stretch_mode = TextureRect.STRETCH_SCALE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	visible = false
	_player = get_tree().root.get_node_or_null("Main/Player")


func _process(delta: float) -> void:
	_elapsed += delta
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().root.get_node_or_null("Main/Player")
		return
	var strength: float = 0.0
	if _player.has_method("portal_overlay_strength"):
		strength = _player.call("portal_overlay_strength")
	if strength <= 0.0 or Game.is_loading:
		visible = false
		return
	visible = true
	# Vanilla: alpha IS the meter, no easing — the acceleration the player
	# feels comes from the swirl texture growing more visible, not a curve.
	modulate = Color(1.0, 1.0, 1.0, clampf(strength, 0.0, 1.0))
	texture = PortalTexture.frame_texture(PortalTexture.frame_at(_elapsed))
