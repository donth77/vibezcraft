extends Control

# Vanilla MC crafting table UI: 3x3 input grid + arrow + result slot at top,
# player's main inventory (3x9) and hotbar (1x9) at the bottom.
#
# Architecture mirrors InventoryScreen — same texture-overlay approach
# (crafting_table.png as background, click-target panels at canonical
# pixel coords), same click model (click pick/drop/swap/merge, drag
# distribution, tooltips, true drag-to-move). The differences:
#   • 3x3 craft grid + result instead of 2x2 + result
#   • No armor / character preview (table screen is craft-only in vanilla)
#   • Craft slots are LOCAL to this screen (not part of player.inventory).
#     Vanilla MC drops them on close — we transfer back to inventory and
#     drop overflow on the floor.

const TABLE_TEXTURE_PATH: String = "res://assets/textures/gui/crafting_table.png"
const FONT_PATH: String = "res://assets/fonts/Minecraft.otf"

const SCALE: int = 5
const PANEL_W: int = 176 * SCALE
const PANEL_H: int = 166 * SCALE
const SLOT_PX: int = 18 * SCALE

# Vanilla mc-dev ContainerWorkbench slot coords (item-render positions).
const _CRAFT_GRID_TL: Vector2i = Vector2i(30, 17)  # 3x3 starts here, stride 18
const _CRAFT_RESULT_POS: Vector2i = Vector2i(124, 35)
const _MAIN_TL: Vector2i = Vector2i(8, 84)
const _HOTBAR_TL: Vector2i = Vector2i(8, 142)
const _TITLE_POS: Vector2i = Vector2i(28, 6)

const _COLOR_TITLE: Color = Color8(64, 64, 64)

# 9 grid slots + 1 result = 10. Indices 0..8 are the 3x3 (row-major),
# index 9 is the result slot.
const CRAFT_GRID_SIZE: int = 9
const CRAFT_RESULT: int = 9
const TOTAL_LOCAL_SLOTS: int = 10

var inventory: Inventory  # bound to player's inventory for the bottom rows
var _local_slots: Array  # 10 ItemStacks owned by this screen
var _cursor: ItemStack
var _slot_nodes: Array = []  # Array[Panel]; -1..-1 = local, then global to inventory
var _local_node_for: Dictionary = {}  # local_index -> Panel (separate map)
var _cursor_icon: TextureRect
var _cursor_count_label: Label
var _font: FontFile
var _tooltip: Label

# Drag state — same model as InventoryScreen
var _drag_active: bool = false
var _drag_button: int = -1
var _drag_slots: Array = []  # mixed: positive = inventory slot, negative = -(local_idx + 1)
var _drag_starting_count: int = 0
var _drag_starting_id: int = 0


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cursor = ItemStack.new()
	_local_slots = []
	for i in range(TOTAL_LOCAL_SLOTS):
		_local_slots.append(ItemStack.new())
	_font = load(FONT_PATH) as FontFile
	_build_dim_background()
	_build_panel()
	_build_cursor_overlay()


func bind(inv: Inventory) -> void:
	inventory = inv
	inv.changed.connect(_refresh)
	_refresh()


func toggle() -> void:
	if visible:
		_close()
	else:
		_open()


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

	var root := Control.new()
	root.custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	center.add_child(root)

	# Background — crop the 176×166 panel out of the 256² atlas.
	var bg := TextureRect.new()
	bg.size = Vector2(PANEL_W, PANEL_H)
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var atlas := AtlasTexture.new()
	atlas.atlas = load(TABLE_TEXTURE_PATH) as Texture2D
	atlas.region = Rect2(0, 0, 176, 166)
	bg.texture = atlas
	root.add_child(bg)

	var title := Label.new()
	title.text = "Crafting"
	title.add_theme_color_override("font_color", _COLOR_TITLE)
	title.add_theme_font_override("font", _font)
	title.add_theme_font_size_override("font_size", 8 * SCALE)
	title.position = Vector2(_TITLE_POS.x * SCALE, _TITLE_POS.y * SCALE)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(title)

	# 3x3 craft grid (LOCAL slots, indexed 0..8 in _local_slots).
	for r in range(3):
		for c in range(3):
			var idx: int = r * 3 + c
			_place_local_slot_overlay(
				root, idx, _CRAFT_GRID_TL.x + c * 18, _CRAFT_GRID_TL.y + r * 18
			)
	# Result slot (LOCAL index 9).
	_place_local_slot_overlay(root, CRAFT_RESULT, _CRAFT_RESULT_POS.x, _CRAFT_RESULT_POS.y)

	# Player's main 3x9 inventory + hotbar (GLOBAL slots in player.inventory).
	for r in range(3):
		for c in range(9):
			_place_inv_slot_overlay(
				root, Inventory.MAIN_START + r * 9 + c, _MAIN_TL.x + c * 18, _MAIN_TL.y + r * 18
			)
	for c in range(9):
		_place_inv_slot_overlay(
			root, Inventory.HOTBAR_START + c, _HOTBAR_TL.x + c * 18, _HOTBAR_TL.y
		)


# Local slots use a parallel _local_node_for dict; their "drag id" is the
# negative-encoded value -(local_idx + 1) so they don't collide with
# positive inventory slot indices.
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


# --- Open / close ---


func _open() -> void:
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_recompute_result()
	_refresh()


func _close() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Vanilla drops table-grid items on the floor when closed. We try to
	# return them to inventory first; whatever doesn't fit goes nowhere
	# (silent drop — proper world-drop wiring can land later).
	for i in range(CRAFT_GRID_SIZE):
		var stack: ItemStack = _local_slots[i]
		if not stack.is_empty():
			inventory.add_item(stack.item_id, stack.count)
			stack.item_id = Blocks.AIR
			stack.count = 0
	# Result slot is purely virtual; just clear it.
	_local_slots[CRAFT_RESULT].item_id = Blocks.AIR
	_local_slots[CRAFT_RESULT].count = 0
	# Cursor stack also returns to inventory.
	if not _cursor.is_empty():
		inventory.add_item(_cursor.item_id, _cursor.count)
		_cursor.item_id = Blocks.AIR
		_cursor.count = 0
	_refresh_cursor_overlay()


# --- Input + drag ---


func _input(event: InputEvent) -> void:
	if not visible or inventory == null:
		return
	if event is InputEventMouseButton:
		var slot: int = _slot_under_mouse()
		if event.pressed:
			_on_mouse_down(event.button_index, slot)
		else:
			_on_mouse_up(event.button_index, slot)
	elif event is InputEventMouseMotion and _drag_active:
		_track_drag_motion()


# Slot resolver: returns positive int for inventory slots, -(local_idx + 1)
# for local craft slots, -100 for none.
func _slot_under_mouse() -> int:
	if not is_inside_tree():
		return -100
	var mouse: Vector2 = get_global_mouse_position()
	# Local slots first
	for li in _local_node_for.keys():
		var p: Panel = _local_node_for[li]
		if p == null:
			continue
		if Rect2(p.global_position, p.size).has_point(mouse):
			return -(li + 1)
	# Inventory slots
	for i in range(_slot_nodes.size()):
		var panel: Panel = _slot_nodes[i]
		if panel == null:
			continue
		if Rect2(panel.global_position, panel.size).has_point(mouse):
			return i
	return -100


# Helpers to read/write a slot regardless of zone.
func _slot_at(slot_id: int) -> ItemStack:
	if slot_id == -100:
		return null
	if slot_id < 0:
		return _local_slots[-slot_id - 1]
	return inventory.slots[slot_id]


func _is_result_slot(slot_id: int) -> bool:
	return slot_id == -(CRAFT_RESULT + 1)


func _is_craft_grid_slot(slot_id: int) -> bool:
	if slot_id >= 0:
		return false
	var local_idx: int = -slot_id - 1
	return local_idx >= 0 and local_idx < CRAFT_GRID_SIZE


func _on_mouse_down(button: int, slot: int) -> void:
	if button != MOUSE_BUTTON_LEFT and button != MOUSE_BUTTON_RIGHT:
		return
	if slot == -100:
		return
	if not _cursor.is_empty() and not _is_result_slot(slot):
		_drag_active = true
		_drag_button = button
		_drag_slots = [slot]
		_drag_starting_count = _cursor.count
		_drag_starting_id = _cursor.item_id
		return
	if (
		button == MOUSE_BUTTON_LEFT
		and _cursor.is_empty()
		and not _is_result_slot(slot)
		and not _slot_at(slot).is_empty()
	):
		_handle_left_click(slot)
		_drag_active = false
		_drag_button = button
		_drag_slots = [slot]
		return
	_drag_active = false
	_drag_button = button
	_drag_slots = [slot]


func _on_mouse_up(button: int, slot: int) -> void:
	if button != _drag_button:
		return
	if _drag_active and _drag_slots.size() > 1:
		_apply_drag_distribution()
	else:
		var click_slot: int = slot if slot != -100 else _drag_slots[0]
		if click_slot != -100 and click_slot != _drag_slots[0]:
			if button == MOUSE_BUTTON_LEFT:
				_handle_left_click(click_slot)
			elif button == MOUSE_BUTTON_RIGHT:
				_handle_right_click(click_slot)
		elif click_slot != -100 and not _was_press_pickup():
			if button == MOUSE_BUTTON_LEFT:
				_handle_left_click(click_slot)
			elif button == MOUSE_BUTTON_RIGHT:
				_handle_right_click(click_slot)
	_drag_active = false
	_drag_button = -1
	_drag_slots.clear()


func _was_press_pickup() -> bool:
	return (
		_drag_button == MOUSE_BUTTON_LEFT
		and not _drag_active
		and _drag_slots.size() == 1
		and not _cursor.is_empty()
		and _slot_at(_drag_slots[0]) != null
		and _slot_at(_drag_slots[0]).is_empty()
	)


func _track_drag_motion() -> void:
	var hovered: int = _slot_under_mouse()
	if hovered == -100 or _drag_slots.has(hovered):
		return
	if _is_result_slot(hovered):
		return
	var slot: ItemStack = _slot_at(hovered)
	if slot == null:
		return
	if not slot.is_empty():
		if slot.item_id != _drag_starting_id:
			return
		if slot.count >= ItemStack.MAX_SIZE:
			return
	_drag_slots.append(hovered)


func _apply_drag_distribution() -> void:
	var n: int = _drag_slots.size()
	var per_slot: int = 0
	if _drag_button == MOUSE_BUTTON_LEFT:
		per_slot = _drag_starting_count / n
	elif _drag_button == MOUSE_BUTTON_RIGHT:
		per_slot = 1
	if per_slot <= 0:
		return
	var distributed: int = 0
	var craft_touched: bool = false
	for slot_id: int in _drag_slots:
		var slot: ItemStack = _slot_at(slot_id)
		if slot == null:
			continue
		if slot.is_empty():
			slot.item_id = _drag_starting_id
		var room: int = ItemStack.MAX_SIZE - slot.count
		var added: int = mini(per_slot, room)
		slot.count += added
		distributed += added
		if _is_craft_grid_slot(slot_id):
			craft_touched = true
	_cursor.count -= distributed
	if _cursor.count <= 0:
		_cursor.item_id = Blocks.AIR
		_cursor.count = 0
	if craft_touched:
		_recompute_result()
	_refresh()


# --- Click handlers ---


func _handle_left_click(slot_id: int) -> void:
	if _is_result_slot(slot_id):
		_take_craft_result()
		return
	var slot: ItemStack = _slot_at(slot_id)
	if _cursor.is_empty() and slot.is_empty():
		return
	if _cursor.is_empty():
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
		_cursor.count = slot.add(_cursor.count)
		if _cursor.count == 0:
			_cursor.item_id = Blocks.AIR
	else:
		var tmp_id: int = slot.item_id
		var tmp_count: int = slot.count
		slot.item_id = _cursor.item_id
		slot.count = _cursor.count
		_cursor.item_id = tmp_id
		_cursor.count = tmp_count
	_after_slot_change(slot_id)


func _handle_right_click(slot_id: int) -> void:
	if _is_result_slot(slot_id):
		_take_craft_result()
		return
	var slot: ItemStack = _slot_at(slot_id)
	if _cursor.is_empty():
		if slot.is_empty():
			return
		var half: int = (slot.count + 1) / 2
		_cursor.item_id = slot.item_id
		_cursor.count = half
		slot.remove(half)
	elif slot.is_empty() or slot.item_id == _cursor.item_id:
		if slot.is_empty():
			slot.item_id = _cursor.item_id
		var space: int = ItemStack.MAX_SIZE - slot.count
		if space > 0:
			slot.count += 1
			_cursor.count -= 1
			if _cursor.count == 0:
				_cursor.item_id = Blocks.AIR
	_after_slot_change(slot_id)


func _take_craft_result() -> void:
	var result: ItemStack = _local_slots[CRAFT_RESULT]
	if result.is_empty():
		return
	if _cursor.is_empty():
		_cursor.item_id = result.item_id
		_cursor.count = result.count
	elif _cursor.item_id == result.item_id:
		var space: int = ItemStack.MAX_SIZE - _cursor.count
		if space < result.count:
			return
		_cursor.count += result.count
	else:
		return
	# Consume one of each input
	for i in range(CRAFT_GRID_SIZE):
		_local_slots[i].remove(1)
	_recompute_result()
	_refresh()


func _after_slot_change(slot_id: int) -> void:
	if _is_craft_grid_slot(slot_id):
		_recompute_result()
	# Emit inventory.changed so player.gd's _update_held_item picks up
	# items moved into the hotbar (e.g., dragging a freshly-crafted
	# pickaxe to the active slot — without this, the held visual stays
	# blank until the player selects a different slot and back).
	inventory.changed.emit()
	_refresh()


# --- Crafting result (3x3 matcher) ---


func _recompute_result() -> void:
	var grid: Array = []
	for i in range(CRAFT_GRID_SIZE):
		grid.append(_local_slots[i].item_id)
	var matched: Dictionary = Recipes.match_grid(grid, 3, 3)
	var result: ItemStack = _local_slots[CRAFT_RESULT]
	if matched.is_empty():
		result.item_id = Blocks.AIR
		result.count = 0
	else:
		result.item_id = matched["item_id"]
		result.count = matched["count"]


# --- Render ---


func _process(_delta: float) -> void:
	if not visible:
		return
	var mouse: Vector2 = get_global_mouse_position()
	if _cursor_icon.visible:
		_cursor_icon.position = mouse - _cursor_icon.size * 0.5
		_cursor_count_label.position = _cursor_icon.position
	_update_tooltip(mouse)


func _update_tooltip(mouse: Vector2) -> void:
	if not _cursor.is_empty():
		_tooltip.visible = false
		return
	var slot_id: int = _slot_under_mouse()
	if slot_id == -100:
		_tooltip.visible = false
		return
	var stack: ItemStack = _slot_at(slot_id)
	if stack == null or stack.is_empty():
		_tooltip.visible = false
		return
	_tooltip.text = Items.display_name(stack.item_id)
	_tooltip.visible = true
	var ts: Vector2 = _tooltip.get_combined_minimum_size()
	var pos: Vector2 = mouse + Vector2(12, 8)
	var vp_size: Vector2 = get_viewport_rect().size
	if pos.x + ts.x > vp_size.x:
		pos.x = mouse.x - ts.x - 4
	if pos.y + ts.y > vp_size.y:
		pos.y = mouse.y - ts.y - 4
	_tooltip.position = pos


func _refresh() -> void:
	if inventory == null:
		return
	# Local craft slots
	for li in _local_node_for.keys():
		var panel: Panel = _local_node_for[li]
		if panel == null:
			continue
		_paint_slot(panel, _local_slots[li])
	# Inventory slots
	for i in range(_slot_nodes.size()):
		var panel: Panel = _slot_nodes[i]
		if panel == null:
			continue
		_paint_slot(panel, inventory.slots[i])
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


func _refresh_cursor_overlay() -> void:
	if _cursor.is_empty():
		_cursor_icon.visible = false
		_cursor_count_label.visible = false
		return
	_cursor_icon.texture = ItemIcons.icon_for(_cursor.item_id)
	_cursor_icon.visible = true
	_cursor_count_label.text = str(_cursor.count) if _cursor.count > 1 else ""
	_cursor_count_label.visible = _cursor.count > 1
