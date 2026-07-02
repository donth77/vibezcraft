class_name TouchCloseButton
extends RefCounted

# Shared mobile close affordances for the container screens (inventory,
# chest, crafting table, furnace, jukebox). Phones have no E/Esc and the
# touch HUD's corner buttons draw UNDERNEATH open screens, so each panel
# gets an explicit ✕ plus tap-outside-to-close. Both are touch-gated at
# the call sites — desktop keeps the vanilla chrome-less panels.

# Button geometry in the panels' native (pre-SCALE) pixel space: a
# 14×14 square inset 2 px from the panel's top-right corner. Every
# screen multiplies its own SCALE in, so the ✕ tracks each panel size.
const _NATIVE_SIZE: float = 14.0
const _NATIVE_MARGIN: float = 2.0


# Build the ✕ button anchored to the top-right of a fixed-size panel
# root. `on_close` is the screen's own close routine (cursor-leftover
# handling and mouse-mode restore stay in one place).
static func build(on_close: Callable, scale: float) -> Button:
	var btn := Button.new()
	btn.text = "X"
	btn.flat = true
	var mc_font: Font = MinecraftFont.get_font()
	if mc_font != null:
		btn.add_theme_font_override("font", mc_font)
	btn.add_theme_font_size_override("font_size", int(8.0 * scale))
	# White + black outline so the glyph reads on the grey panel art.
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", Color(1.0, 0.55, 0.5))
	btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.3, 0.25))
	btn.add_theme_color_override("font_focus_color", Color.WHITE)
	btn.add_theme_color_override("font_outline_color", Color.BLACK)
	btn.add_theme_constant_override("outline_size", int(scale))
	btn.focus_mode = Control.FOCUS_NONE
	# Screens add this right after creating the panel root, BEFORE the
	# panel art TextureRect — which would draw over the glyph (input
	# still reached it; the art ignores mouse). Lift above siblings.
	btn.z_index = 20
	btn.anchor_left = 1.0
	btn.anchor_right = 1.0
	btn.anchor_top = 0.0
	btn.anchor_bottom = 0.0
	var size_px: float = _NATIVE_SIZE * scale
	var margin_px: float = _NATIVE_MARGIN * scale
	btn.offset_left = -(size_px + margin_px)
	btn.offset_right = -margin_px
	btn.offset_top = margin_px
	btn.offset_bottom = margin_px + size_px
	btn.pressed.connect(on_close)
	return btn
