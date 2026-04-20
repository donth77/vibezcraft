extends Control

# Vanilla MC furnace UI (ContainerFurnace) — 3 slots (input, fuel, output)
# + arrow + flame progress bars + player inventory below.
#
# Architecture mirrors CraftingTableScreen: same texture-overlay approach
# (furnace.png crop as background, click-target Panels at the canonical
# pixel coords vanilla mc-dev uses), same click model. Differences:
#   • 3 local slots instead of 10
#   • Slots are NOT local to the screen — they live in the FurnaceManager
#     state for the bound furnace position (so they persist across opens
#     and the ticker can read/write them while the screen is closed)
#   • Two progress widgets driven from the same furnace state

const FURNACE_TEXTURE_PATH: String = "res://assets/textures/gui/furnace.png"
const FONT_PATH: String = "res://assets/fonts/Minecraft.otf"

const SCALE: int = 5
const PANEL_W: int = 176 * SCALE
const PANEL_H: int = 166 * SCALE
const SLOT_PX: int = 18 * SCALE

# Vanilla mc-dev ContainerFurnace slot coords (item-render top-left).
const _INPUT_POS: Vector2i = Vector2i(56, 17)
const _FUEL_POS: Vector2i = Vector2i(56, 53)
const _OUTPUT_POS: Vector2i = Vector2i(116, 35)
# Arrow (cook progress): from (79, 35), 24×17 pixels, fills left→right.
const _ARROW_POS: Vector2i = Vector2i(79, 35)
const _ARROW_SIZE: Vector2i = Vector2i(24, 17)
# Flame (burn time): bottom-up at (57, 37), 14×14 pixels.
const _FLAME_POS: Vector2i = Vector2i(57, 37)
const _FLAME_SIZE: Vector2i = Vector2i(14, 14)
const _MAIN_TL: Vector2i = Vector2i(8, 84)
const _HOTBAR_TL: Vector2i = Vector2i(8, 142)
const _TITLE_POS: Vector2i = Vector2i(60, 6)

# Local-slot indices for _slot_at routing.
const SLOT_INPUT: int = 0
const SLOT_FUEL: int = 1
const SLOT_OUTPUT: int = 2

const _COLOR_TITLE: Color = Color8(64, 64, 64)

var inventory: Inventory  # bound to player's inventory for the bottom rows
var _cursor: ItemStack
var _slot_nodes: Array = []  # Array[Panel]; inventory slots only
var _local_node_for: Dictionary = {}  # local_index -> Panel
var _cursor_icon: TextureRect
var _cursor_count_label: Label
var _font: FontFile

# Currently-bound furnace world position. Set by `open_at(pos)`.
var _furnace_pos: Vector3i = Vector3i.ZERO
var _has_furnace: bool = false

# Progress widgets — AtlasTexture rects sliced from the right edge of the
# furnace GUI sheet, clipped to the vanilla pixel sizes (24×17 arrow at
# (176, 14); 14×14 flame at (176, 0)).
var _arrow_fill: TextureRect
var _flame_fill: TextureRect
var _arrow_atlas: AtlasTexture
var _flame_atlas: AtlasTexture
var _tooltip: Label
var _root: Control


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cursor = ItemStack.new()
	_font = load(FONT_PATH) as FontFile
	_build_dim_background()
	_build_panel()
	_build_cursor_overlay()
	_build_tooltip()


func bind(inv: Inventory) -> void:
	inventory = inv
	inv.changed.connect(_refresh)
	_refresh()


# Open this screen targeting the furnace at `pos`. Pulls/creates the
# tile-entity state from FurnaceManager so subsequent slot edits route to
# THAT furnace's input/fuel/output rather than a screen-local buffer.
func open_at(pos: Vector3i) -> void:
	_furnace_pos = pos
	_has_furnace = true
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh()


func close() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Cursor stack returns to inventory if it has anything (vanilla MC drops
	# it on the floor; we'll route through inventory here for now).
	if not _cursor.is_empty():
		inventory.add_item(_cursor.item_id, _cursor.count)
		_cursor.item_id = Blocks.AIR
		_cursor.count = 0
	_has_furnace = false
	_refresh_cursor_overlay()


func toggle() -> void:
	if visible:
		close()


func is_open() -> bool:
	return visible


# --- Build ---


func _build_dim_background() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.5)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)


func _build_panel() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(center)

	_root = Control.new()
	_root.custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	_root.mouse_filter = Control.MOUSE_FILTER_PASS
	center.add_child(_root)

	# Background — crop the 176×166 panel out of the 256² atlas.
	var bg := TextureRect.new()
	bg.size = Vector2(PANEL_W, PANEL_H)
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var atlas := AtlasTexture.new()
	atlas.atlas = load(FURNACE_TEXTURE_PATH) as Texture2D
	atlas.region = Rect2(0, 0, 176, 166)
	bg.texture = atlas
	_root.add_child(bg)

	var title := Label.new()
	title.text = "Furnace"
	title.add_theme_color_override("font_color", _COLOR_TITLE)
	title.add_theme_font_override("font", _font)
	title.add_theme_font_size_override("font_size", 8 * SCALE)
	title.position = Vector2(_TITLE_POS.x * SCALE, _TITLE_POS.y * SCALE)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(title)

	# Three local slots (LIVE — backed by FurnaceManager state).
	_place_local_slot_overlay(_root, SLOT_INPUT, _INPUT_POS.x, _INPUT_POS.y)
	_place_local_slot_overlay(_root, SLOT_FUEL, _FUEL_POS.x, _FUEL_POS.y)
	_place_local_slot_overlay(_root, SLOT_OUTPUT, _OUTPUT_POS.x, _OUTPUT_POS.y)

	# Player's main 3x9 inventory + hotbar (GLOBAL slots in player.inventory).
	for r in range(3):
		for c in range(9):
			_place_inv_slot_overlay(
				_root, Inventory.MAIN_START + r * 9 + c, _MAIN_TL.x + c * 18, _MAIN_TL.y + r * 18
			)
	for c in range(9):
		_place_inv_slot_overlay(
			_root, Inventory.HOTBAR_START + c, _HOTBAR_TL.x + c * 18, _HOTBAR_TL.y
		)

	# Arrow + flame progress overlays. Vanilla packs the FILLED versions of
	# both at the right edge of the same gui sheet — arrow at (176, 14),
	# flame at (176, 0). We crop progressively narrower / shorter regions
	# and stretch the TextureRect to match, so the texture itself reveals
	# pixel-by-pixel rather than a solid colored block.
	var sheet: Texture2D = load(FURNACE_TEXTURE_PATH) as Texture2D

	_arrow_atlas = AtlasTexture.new()
	_arrow_atlas.atlas = sheet
	_arrow_atlas.region = Rect2(176, 14, 0, _ARROW_SIZE.y)
	_arrow_fill = TextureRect.new()
	_arrow_fill.texture = _arrow_atlas
	_arrow_fill.stretch_mode = TextureRect.STRETCH_SCALE
	_arrow_fill.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_arrow_fill.position = Vector2(_ARROW_POS.x * SCALE, _ARROW_POS.y * SCALE)
	_arrow_fill.size = Vector2(0, _ARROW_SIZE.y * SCALE)
	_arrow_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_arrow_fill)

	_flame_atlas = AtlasTexture.new()
	_flame_atlas.atlas = sheet
	# Default region — overwritten per-frame; height grows from the bottom
	# as fuel depletes (0 burn → empty; full burn → full 14×14 sliver).
	_flame_atlas.region = Rect2(176, _FLAME_SIZE.y, _FLAME_SIZE.x, 0)
	_flame_fill = TextureRect.new()
	_flame_fill.texture = _flame_atlas
	_flame_fill.stretch_mode = TextureRect.STRETCH_SCALE
	_flame_fill.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_flame_fill.position = Vector2(_FLAME_POS.x * SCALE, (_FLAME_POS.y + _FLAME_SIZE.y) * SCALE)
	_flame_fill.size = Vector2(_FLAME_SIZE.x * SCALE, 0)
	_flame_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_flame_fill)


func _place_local_slot_overlay(
	parent: Control, local_idx: int, native_x: int, native_y: int
) -> void:
	var panel: Panel = _make_slot_panel(parent, native_x, native_y)
	_local_node_for[local_idx] = panel


func _place_inv_slot_overlay(parent: Control, inv_idx: int, native_x: int, native_y: int) -> void:
	var panel: Panel = _make_slot_panel(parent, native_x, native_y)
	while _slot_nodes.size() <= inv_idx:
		_slot_nodes.append(null)
	_slot_nodes[inv_idx] = panel


func _make_slot_panel(parent: Control, native_x: int, native_y: int) -> Panel:
	var panel := Panel.new()
	panel.position = Vector2((native_x - 1) * SCALE, (native_y - 1) * SCALE)
	panel.size = Vector2(SLOT_PX, SLOT_PX)
	var style := StyleBoxEmpty.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(panel)

	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.position = Vector2(1 * SCALE, 1 * SCALE)
	icon.size = Vector2(16 * SCALE, 16 * SCALE)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(icon)

	var count := Label.new()
	count.name = "Count"
	count.position = Vector2(0, 0)
	count.size = Vector2(SLOT_PX, SLOT_PX)
	count.add_theme_font_override("font", _font)
	count.add_theme_font_size_override("font_size", 8 * SCALE)
	count.add_theme_color_override("font_color", Color(1, 1, 1))
	count.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	count.add_theme_constant_override("outline_size", 2)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(count)
	return panel


func _build_tooltip() -> void:
	_tooltip = Label.new()
	_tooltip.add_theme_font_override("font", _font)
	_tooltip.add_theme_font_size_override("font_size", 7 * SCALE)
	_tooltip.add_theme_color_override("font_color", Color(1, 1, 1))
	_tooltip.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_tooltip.add_theme_constant_override("outline_size", 3)
	var tip_style := StyleBoxFlat.new()
	tip_style.bg_color = Color(0.06, 0.04, 0.10, 0.92)
	tip_style.border_color = Color(0.30, 0.18, 0.50, 0.95)
	tip_style.border_width_left = 1
	tip_style.border_width_right = 1
	tip_style.border_width_top = 1
	tip_style.border_width_bottom = 1
	tip_style.content_margin_left = 6
	tip_style.content_margin_right = 6
	tip_style.content_margin_top = 3
	tip_style.content_margin_bottom = 3
	_tooltip.add_theme_stylebox_override("normal", tip_style)
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.visible = false
	add_child(_tooltip)


func _build_cursor_overlay() -> void:
	_cursor_icon = TextureRect.new()
	_cursor_icon.size = Vector2(16 * SCALE, 16 * SCALE)
	_cursor_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cursor_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_cursor_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_cursor_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_icon.visible = false
	add_child(_cursor_icon)
	_cursor_count_label = Label.new()
	_cursor_count_label.add_theme_font_override("font", _font)
	_cursor_count_label.add_theme_font_size_override("font_size", 8 * SCALE)
	_cursor_count_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_cursor_count_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_cursor_count_label.add_theme_constant_override("outline_size", 2)
	_cursor_count_label.size = Vector2(16 * SCALE, 16 * SCALE)
	_cursor_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_cursor_count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_cursor_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_count_label.visible = false
	add_child(_cursor_count_label)


# --- Process / refresh loop ---


func _process(_delta: float) -> void:
	if not visible:
		return
	# Furnace state mutates from the ticker autoload independently of our
	# `changed` signal; refresh every frame so progress bars + slot icons
	# stay current.
	_refresh()
	_track_cursor_with_mouse()
	_update_tooltip()


func _update_tooltip() -> void:
	if _tooltip == null:
		return
	var slot: int = _slot_under_mouse()
	var stack: ItemStack = _slot_at(slot) if slot != -100 else null
	if stack == null or stack.is_empty():
		_tooltip.visible = false
		return
	_tooltip.text = Items.display_name(stack.item_id)
	_tooltip.visible = true
	# Position just below + right of the cursor; nudge left/up if it would
	# spill off-screen.
	var mouse: Vector2 = get_global_mouse_position()
	var pos: Vector2 = mouse + Vector2(12, 12)
	var ts: Vector2 = _tooltip.get_minimum_size()
	var vp_size: Vector2 = get_viewport_rect().size
	if pos.x + ts.x > vp_size.x:
		pos.x = mouse.x - ts.x - 4
	if pos.y + ts.y > vp_size.y:
		pos.y = mouse.y - ts.y - 4
	_tooltip.position = pos


func _refresh() -> void:
	if inventory == null:
		return
	# Inventory slots
	for i in range(_slot_nodes.size()):
		var panel: Panel = _slot_nodes[i]
		if panel == null:
			continue
		_paint_slot(panel, inventory.slots[i])
	# Local (furnace) slots
	if _has_furnace and FurnaceManager.has_furnace(_furnace_pos):
		var state: Dictionary = FurnaceManager.get_or_create(_furnace_pos)
		_paint_slot(_local_node_for[SLOT_INPUT] as Panel, state.input)
		_paint_slot(_local_node_for[SLOT_FUEL] as Panel, state.fuel)
		_paint_slot(_local_node_for[SLOT_OUTPUT] as Panel, state.output)
		_update_progress_bars(state)
	else:
		_paint_slot(_local_node_for[SLOT_INPUT] as Panel, ItemStack.new())
		_paint_slot(_local_node_for[SLOT_FUEL] as Panel, ItemStack.new())
		_paint_slot(_local_node_for[SLOT_OUTPUT] as Panel, ItemStack.new())
	_refresh_cursor_overlay()


func _paint_slot(panel: Panel, stack: ItemStack) -> void:
	var icon: TextureRect = panel.get_node("Icon")
	var count_label: Label = panel.get_node("Count")
	if stack.is_empty():
		icon.texture = null
		count_label.text = ""
	else:
		icon.texture = ItemIcons.icon_for(stack.item_id)
		count_label.text = str(stack.count) if stack.count > 1 else ""


func _update_progress_bars(state: Dictionary) -> void:
	# Arrow grows left → right. Crop both the AtlasTexture region's width
	# and the Control's display width to the same ratio so the texture
	# scales 1:1 with the visible bar.
	var cook: int = state.cook_time
	var arrow_ratio: float = clampf(float(cook) / float(Smelting.SMELT_TICKS), 0.0, 1.0)
	var arrow_native_w: float = arrow_ratio * _ARROW_SIZE.x
	_arrow_atlas.region = Rect2(176, 14, arrow_native_w, _ARROW_SIZE.y)
	_arrow_fill.size.x = arrow_native_w * SCALE

	# Flame grows bottom → top. Crop the region from the bottom (origin
	# Y stays at FLAME_SIZE.y inset, height shrinks toward 0) so the
	# remaining flame sliver always represents the bottom of the icon.
	var burn_total: int = state.burn_total
	var burn_now: int = state.burn_time
	var flame_ratio: float = (
		clampf(float(burn_now) / float(burn_total), 0.0, 1.0) if burn_total > 0 else 0.0
	)
	var flame_native_h: float = flame_ratio * _FLAME_SIZE.y
	_flame_atlas.region = Rect2(176, _FLAME_SIZE.y - flame_native_h, _FLAME_SIZE.x, flame_native_h)
	var flame_px: float = flame_native_h * SCALE
	_flame_fill.size.y = flame_px
	_flame_fill.position.y = (_FLAME_POS.y + _FLAME_SIZE.y) * SCALE - flame_px


func _refresh_cursor_overlay() -> void:
	if _cursor.is_empty():
		_cursor_icon.visible = false
		_cursor_count_label.visible = false
		return
	_cursor_icon.texture = ItemIcons.icon_for(_cursor.item_id)
	_cursor_icon.visible = true
	_cursor_count_label.text = str(_cursor.count) if _cursor.count > 1 else ""
	_cursor_count_label.visible = _cursor.count > 1


func _track_cursor_with_mouse() -> void:
	if not _cursor_icon.visible:
		return
	var mouse: Vector2 = get_global_mouse_position()
	_cursor_icon.position = mouse - Vector2(8 * SCALE, 8 * SCALE)
	_cursor_count_label.position = _cursor_icon.position


# --- Input ---


func _input(event: InputEvent) -> void:
	if not visible or inventory == null:
		return
	if event is InputEventMouseButton and event.pressed:
		var slot: int = _slot_under_mouse()
		if slot == -100:
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			_handle_left_click(slot)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_handle_right_click(slot)


# Returns positive int for inventory slots, -(local_idx + 1) for local
# furnace slots, -100 for none.
func _slot_under_mouse() -> int:
	if not is_inside_tree():
		return -100
	var mouse: Vector2 = get_global_mouse_position()
	for li in _local_node_for.keys():
		var p: Panel = _local_node_for[li]
		if p != null and Rect2(p.global_position, p.size).has_point(mouse):
			return -(li + 1)
	for i in range(_slot_nodes.size()):
		var panel: Panel = _slot_nodes[i]
		if panel != null and Rect2(panel.global_position, panel.size).has_point(mouse):
			return i
	return -100


# Returns the ItemStack reference for either a local furnace slot or a
# player inventory slot. Null for the no-slot case.
func _slot_at(slot_id: int) -> ItemStack:
	if slot_id == -100:
		return null
	if slot_id >= 0:
		return inventory.slots[slot_id]
	if not _has_furnace:
		return null
	var state: Dictionary = FurnaceManager.get_or_create(_furnace_pos)
	var local_idx: int = -slot_id - 1
	var key: String = ["input", "fuel", "output"][local_idx] if local_idx < 3 else ""
	return state.get(key, null) as ItemStack


func _is_output_slot(slot_id: int) -> bool:
	return slot_id == -(SLOT_OUTPUT + 1)


# Vanilla left-click semantics:
#   • cursor empty + slot non-empty → pick up the whole stack
#   • cursor non-empty + slot empty → drop entire cursor stack
#   • cursor non-empty + slot has same id → merge up to MAX_SIZE
#   • cursor non-empty + slot has different id → swap
#   • output slot is take-only (cursor must accept the result type)
func _handle_left_click(slot_id: int) -> void:
	var slot: ItemStack = _slot_at(slot_id)
	if slot == null:
		return
	if _is_output_slot(slot_id):
		_take_output(slot)
		return
	if _cursor.is_empty():
		if slot.is_empty():
			return
		_cursor.item_id = slot.item_id
		_cursor.count = slot.count
		slot.item_id = Blocks.AIR
		slot.count = 0
	elif slot.is_empty():
		slot.item_id = _cursor.item_id
		slot.count = _cursor.count
		_cursor.item_id = Blocks.AIR
		_cursor.count = 0
	elif slot.item_id == _cursor.item_id:
		var space: int = ItemStack.MAX_SIZE - slot.count
		var moved: int = mini(space, _cursor.count)
		slot.count += moved
		_cursor.count -= moved
		if _cursor.count <= 0:
			_cursor.item_id = Blocks.AIR
			_cursor.count = 0
	else:
		var tmp_id: int = slot.item_id
		var tmp_n: int = slot.count
		slot.item_id = _cursor.item_id
		slot.count = _cursor.count
		_cursor.item_id = tmp_id
		_cursor.count = tmp_n
	_refresh()


# Right-click: place 1 from cursor, or pick up half a stack from a slot.
func _handle_right_click(slot_id: int) -> void:
	var slot: ItemStack = _slot_at(slot_id)
	if slot == null:
		return
	if _is_output_slot(slot_id):
		# Vanilla actually still gives the full output on right-click;
		# treat right and left as equivalent for the take-only output.
		_take_output(slot)
		return
	if _cursor.is_empty():
		if slot.is_empty():
			return
		var half: int = (slot.count + 1) / 2  # vanilla rounds UP
		_cursor.item_id = slot.item_id
		_cursor.count = half
		slot.count -= half
		if slot.count <= 0:
			slot.item_id = Blocks.AIR
			slot.count = 0
	elif slot.is_empty() or slot.item_id == _cursor.item_id:
		if slot.is_empty():
			slot.item_id = _cursor.item_id
			slot.count = 0
		if slot.count < ItemStack.MAX_SIZE:
			slot.count += 1
			_cursor.count -= 1
			if _cursor.count <= 0:
				_cursor.item_id = Blocks.AIR
				_cursor.count = 0
	_refresh()


# Vanilla output-slot takes: cursor must be empty OR same item id with room.
# Pulls the whole output stack (or as much as fits).
func _take_output(output: ItemStack) -> void:
	if output.is_empty():
		return
	if _cursor.is_empty():
		_cursor.item_id = output.item_id
		_cursor.count = output.count
		output.item_id = Blocks.AIR
		output.count = 0
	elif _cursor.item_id == output.item_id:
		var room: int = ItemStack.MAX_SIZE - _cursor.count
		var taken: int = mini(room, output.count)
		_cursor.count += taken
		output.count -= taken
		if output.count <= 0:
			output.item_id = Blocks.AIR
			output.count = 0
	_refresh()
