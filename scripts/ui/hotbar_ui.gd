extends Control

# Vanilla MC hotbar rendered using the actual widgets.png texture.
# Layout (native px, sourced from gui/widgets.png):
#   • Strip background: 182×22 in the upper-left of the texture
#   • Selection indicator: 24×23 at (0, 22) — drawn over the active slot
#   • Each slot's inner 16×16 area starts at strip-local (3, 3) for slot 0
#     and steps 20px right per slot
#
# We render at SCALE=4 (matching the inventory's chunky pixel-art look)
# and position slots / selection ring with the canonical pixel offsets.

const WIDGETS_PATH: String = "res://assets/textures/gui/widgets.png"
const FONT_PATH: String = "res://assets/fonts/Minecraft.otf"

const SCALE: int = 4
const STRIP_W: int = 182 * SCALE  # 728
const STRIP_H: int = 22 * SCALE  # 88
const SLOT_STRIDE: int = 20 * SCALE  # distance between slot inner-area origins
const SLOT_INNER_PX: int = 16 * SCALE  # item-render area per slot
const SLOT_INNER_X0: int = 3 * SCALE  # first slot inner-area x in strip-local
const SLOT_INNER_Y0: int = 3 * SCALE  # all slots share the same y inside the strip
const SELECTION_W: int = 24 * SCALE
const SELECTION_H: int = 23 * SCALE
# Vanilla MC draws the selection indicator at strip-local (-1, -1) for slot 0
# (one pixel left/above the strip itself!). Slot 0's inner area is at (3, 3),
# so the indicator's top-left is 4 pixels up-and-left of the slot inner.
const SELECTION_PAD: int = 4 * SCALE

var inventory: Inventory
var _slot_icons: Array = []  # Array[TextureRect]
var _slot_counts: Array = []  # Array[Label]
var _slot_dur_bars: Array = []  # Array[DurabilityBar]
var _selection_rect: TextureRect
var _font: FontFile = MinecraftFont.get_font()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Center the strip horizontally, anchored to the bottom of the viewport
	# with a small gap. Override the .tscn anchors entirely.
	custom_minimum_size = Vector2(STRIP_W, STRIP_H)
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_KEEP_SIZE)
	offset_top = -STRIP_H - 10
	offset_bottom = -10
	offset_left = -STRIP_W / 2
	offset_right = STRIP_W / 2

	_build_strip()
	_build_slots()
	_build_selection_indicator()


func bind(inv: Inventory) -> void:
	inventory = inv
	inv.changed.connect(_refresh)
	_refresh()


# --- Build ---


func _build_strip() -> void:
	var bg := TextureRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	# Crop the 182×22 hotbar strip out of the 256×256 widgets atlas.
	var atlas := AtlasTexture.new()
	atlas.atlas = load(WIDGETS_PATH) as Texture2D
	atlas.region = Rect2(0, 0, 182, 22)
	bg.texture = atlas
	add_child(bg)


func _build_slots() -> void:
	for i in range(Inventory.HOTBAR_SIZE):
		var slot_x: int = SLOT_INNER_X0 + i * SLOT_STRIDE
		var icon := TextureRect.new()
		icon.position = Vector2(slot_x, SLOT_INNER_Y0)
		icon.size = Vector2(SLOT_INNER_PX, SLOT_INNER_PX)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(icon)
		_slot_icons.append(icon)

		var count := Label.new()
		count.position = Vector2(slot_x, SLOT_INNER_Y0)
		count.size = Vector2(SLOT_INNER_PX, SLOT_INNER_PX)
		if _font != null:
			count.add_theme_font_override("font", _font)
		# Vanilla MC uses 8-native-pixel font; at SCALE=4 that's 32px tall.
		# 8×SCALE keeps the glyphs at the original aspect for crisp pixel art.
		count.add_theme_font_size_override("font_size", 8 * SCALE)
		count.add_theme_color_override("font_color", Color(1, 1, 1))
		count.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
		# Native MC drop-shadow — 1 source-pixel offset, scaled by SCALE.
		count.add_theme_constant_override("shadow_offset_x", SCALE)
		count.add_theme_constant_override("shadow_offset_y", SCALE)
		count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		count.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(count)
		_slot_counts.append(count)

		# Durability bar — pinned 1 native pixel above the slot's bottom edge.
		var bar := DurabilityBar.new()
		bar.scale_factor = SCALE
		var bar_y: int = SLOT_INNER_Y0 + SLOT_INNER_PX - (2 * SCALE)
		bar.position = Vector2(slot_x, bar_y)
		bar.size = Vector2(SLOT_INNER_PX, SCALE)
		add_child(bar)
		_slot_dur_bars.append(bar)


func _build_selection_indicator() -> void:
	_selection_rect = TextureRect.new()
	_selection_rect.size = Vector2(SELECTION_W, SELECTION_H)
	_selection_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_selection_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_selection_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_selection_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var atlas := AtlasTexture.new()
	atlas.atlas = load(WIDGETS_PATH) as Texture2D
	atlas.region = Rect2(0, 22, 24, 23)
	_selection_rect.texture = atlas
	add_child(_selection_rect)


# --- Render ---


func _refresh() -> void:
	if inventory == null:
		return
	for i in range(Inventory.HOTBAR_SIZE):
		var stack: ItemStack = inventory.slots[i]
		if stack.is_empty():
			_slot_icons[i].texture = null
			_slot_counts[i].text = ""
		else:
			_slot_icons[i].texture = ItemIcons.icon_for(stack.item_id)
			_slot_counts[i].text = str(stack.count) if stack.count > 1 else ""
		_slot_dur_bars[i].bind(stack, SLOT_INNER_PX)
	_position_selection_rect()


func _position_selection_rect() -> void:
	# The selection indicator wraps around the slot's inner 16×16 area with
	# 4px padding on each side (24×23 native). Position so its inner area
	# aligns with the selected slot.
	var slot_x: int = SLOT_INNER_X0 + inventory.selected_slot * SLOT_STRIDE
	_selection_rect.position = Vector2(slot_x - SELECTION_PAD, SLOT_INNER_Y0 - SELECTION_PAD)
