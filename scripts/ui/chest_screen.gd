extends Control

# Vanilla MC chest UI: 9x3 chest grid at top + player main inventory +
# hotbar at bottom. Backed by ChestStorage's per-position 27-slot array
# — local_slots are direct references into that array so mutations
# persist when the screen closes.
#
# Architecture mirrors CraftingTableScreen, with the craft grid + result
# replaced by a 27-slot chest grid. No close-time recovery (chest items
# stay in the chest), no recipe matcher, no result slot.

const CONTAINER_TEXTURE_PATH: String = "res://assets/textures/gui/container.png"
const FONT_PATH: String = "res://assets/fonts/Minecraft.otf"

const SCALE: int = 5
const PANEL_W: int = 176 * SCALE
const PANEL_H: int = 222 * SCALE
const SLOT_PX: int = 18 * SCALE

# Vanilla mc-dev ContainerChest slot coords (item-render positions).
const _CHEST_GRID_TL: Vector2i = Vector2i(8, 18)  # 9x3 starts here, stride 18
const _MAIN_TL: Vector2i = Vector2i(8, 140)
const _HOTBAR_TL: Vector2i = Vector2i(8, 198)
const _TITLE_POS: Vector2i = Vector2i(8, 6)

const _COLOR_TITLE: Color = Color8(64, 64, 64)

const CHEST_GRID_SIZE: int = 27

var inventory: Inventory  # bound to player's inventory for the bottom rows
var _local_slots: Array  # 27 ItemStack refs into ChestStorage's array
var _chest_pos: Vector3i  # world cell of the open chest (entity mode: ignored)
var _open_callback: Callable  # invoked when screen closes (drives lid anim)
var _title_label: Label = null  # rebound per-open to swap "Chest" vs cart title
var _title_text: String = "Chest"
var _cursor: ItemStack
var _slot_nodes: Array = []  # Array[Panel]; -1..-1 = local, then global to inventory
var _local_node_for: Dictionary = {}  # local_index -> Panel
var _cursor_icon: TextureRect
var _cursor_count_label: Label
var _font: FontFile
var _tooltip: Label

# Drag state — same model as CraftingTableScreen
var _drag_active: bool = false
var _drag_button: int = -1
var _drag_slots: Array = []
var _drag_starting_count: int = 0
var _drag_starting_id: int = 0

# Lazy-init shared empty stack used as a paint stand-in when _refresh
# fires before the chest has been bound to a position (e.g. inventory
# pickups while the screen is closed).
var _empty_stack: ItemStack


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cursor = ItemStack.new()
	_font = MinecraftFont.get_font()
	_build_dim_background()
	_build_panel()
	_build_cursor_overlay()


# Bind player inventory once at startup. Per-chest binding happens in open().
func bind(inv: Inventory) -> void:
	inventory = inv
	inv.changed.connect(_refresh)


# Open this screen against a specific chest. Caller (interaction.gd)
# passes the close-callback so the lid animation closes when the UI does.
func open_for(pos: Vector3i, close_cb: Callable) -> void:
	_chest_pos = pos
	_open_callback = close_cb
	_local_slots = ChestStorage.get_or_create(pos)
	_title_text = "Chest"
	if _title_label != null:
		_title_label.text = _title_text
	_open()


# Entity-attached variant — chest minecart (and any future entity that
# carries an inventory). Caller passes the cart's 27-slot ItemStack
# array by reference; mutations are visible to the cart immediately
# because chest_screen reads/writes _local_slots in place. Optional
# close_cb drives the entity's lid animation (cart's chest_node).
func open_entity(items: Array, title: String = "Chest", close_cb: Callable = Callable()) -> void:
	_chest_pos = Vector3i.ZERO
	_open_callback = close_cb
	_local_slots = items
	_title_text = title
	if _title_label != null:
		_title_label.text = _title_text
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

	# Background — 176×222 chest panel cropped from container.png.
	var bg := TextureRect.new()
	bg.size = Vector2(PANEL_W, PANEL_H)
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var atlas := AtlasTexture.new()
	atlas.atlas = load(CONTAINER_TEXTURE_PATH) as Texture2D
	atlas.region = Rect2(0, 0, 176, 222)
	bg.texture = atlas
	root.add_child(bg)

	var title := Label.new()
	title.text = _title_text
	title.add_theme_color_override("font_color", _COLOR_TITLE)
	title.add_theme_font_override("font", _font)
	title.add_theme_font_size_override("font_size", 8 * SCALE)
	title.position = Vector2(_TITLE_POS.x * SCALE, _TITLE_POS.y * SCALE)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(title)
	_title_label = title

	# 9x3 chest grid (LOCAL slots 0..26).
	for r in range(3):
		for c in range(9):
			var idx: int = r * 9 + c
			_place_local_slot_overlay(
				root, idx, _CHEST_GRID_TL.x + c * 18, _CHEST_GRID_TL.y + r * 18
			)
	# Player main inventory + hotbar (GLOBAL slots).
	for r in range(3):
		for c in range(9):
			_place_inv_slot_overlay(
				root, Inventory.MAIN_START + r * 9 + c, _MAIN_TL.x + c * 18, _MAIN_TL.y + r * 18
			)
	for c in range(9):
		_place_inv_slot_overlay(
			root, Inventory.HOTBAR_START + c, _HOTBAR_TL.x + c * 18, _HOTBAR_TL.y
		)


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
	count.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
	count.add_theme_constant_override("shadow_offset_x", SCALE)
	count.add_theme_constant_override("shadow_offset_y", SCALE)
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
	_cursor_count_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
	_cursor_count_label.add_theme_constant_override("shadow_offset_x", SCALE)
	_cursor_count_label.add_theme_constant_override("shadow_offset_y", SCALE)
	# Match slot count rect dims so cursor text lines up with the slot
	# convention (see inventory_screen for the rationale).
	_cursor_count_label.size = Vector2(18 * SCALE, 18 * SCALE)
	_cursor_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_cursor_count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_cursor_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_count_label.visible = false
	add_child(_cursor_count_label)
	_tooltip = Label.new()
	_tooltip.add_theme_font_override("font", _font)
	_tooltip.add_theme_font_size_override("font_size", 7 * SCALE)
	_tooltip.add_theme_color_override("font_color", Color(1, 1, 1))
	_tooltip.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
	_tooltip.add_theme_constant_override("shadow_offset_x", SCALE)
	_tooltip.add_theme_constant_override("shadow_offset_y", SCALE)
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
	_refresh()


func close() -> void:
	if not visible:
		return
	_close()


func _close() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Cursor stack returns to inventory (vanilla drops on the floor; we're
	# generous and try to refit, mirroring crafting table close behavior).
	if not _cursor.is_empty():
		inventory.add_item(_cursor.item_id, _cursor.count)
		_cursor.item_id = Blocks.AIR
		_cursor.count = 0
	_refresh_cursor_overlay()
	if _open_callback.is_valid():
		_open_callback.call()
		_open_callback = Callable()


# --- Input + drag ---


func _input(event: InputEvent) -> void:
	if not visible or inventory == null:
		return
	if event is InputEventMouseButton:
		var slot: int = _slot_under_mouse()
		# Vanilla MC ContainerChest::transferStackInSlot: shift+left-click
		# moves the entire stack to the "other" zone — chest slot → first
		# matching/empty inventory slot, or inventory slot → first
		# matching/empty chest slot. Bypasses the cursor entirely.
		# Mirrors inventory_screen's shift-click handler.
		if (
			event.pressed
			and event.button_index == MOUSE_BUTTON_LEFT
			and event.shift_pressed
			and slot != -100
		):
			_handle_shift_click(slot)
			return
		if event.pressed:
			_on_mouse_down(event.button_index, slot)
		else:
			_on_mouse_up(event.button_index, slot)
	elif event is InputEventMouseMotion and _drag_active:
		_track_drag_motion()


func _slot_under_mouse() -> int:
	if not is_inside_tree():
		return -100
	var mouse: Vector2 = get_global_mouse_position()
	for li in _local_node_for.keys():
		var p: Panel = _local_node_for[li]
		if p == null:
			continue
		if Rect2(p.global_position, p.size).has_point(mouse):
			return -(li + 1)
	for i in range(_slot_nodes.size()):
		var panel: Panel = _slot_nodes[i]
		if panel == null:
			continue
		if Rect2(panel.global_position, panel.size).has_point(mouse):
			return i
	return -100


func _slot_at(slot_id: int) -> ItemStack:
	if slot_id == -100:
		return null
	if slot_id < 0:
		return _local_slots[-slot_id - 1]
	return inventory.slots[slot_id]


func _on_mouse_down(button: int, slot: int) -> void:
	if button != MOUSE_BUTTON_LEFT and button != MOUSE_BUTTON_RIGHT:
		return
	if slot == -100:
		return
	if not _cursor.is_empty():
		_drag_active = true
		_drag_button = button
		_drag_slots = [slot]
		_drag_starting_count = _cursor.count
		_drag_starting_id = _cursor.item_id
		return
	if button == MOUSE_BUTTON_LEFT and _cursor.is_empty() and not _slot_at(slot).is_empty():
		_handle_left_click(slot)
		_drag_active = false
		_drag_button = button
		_drag_slots = [slot]
		return
	# Cursor-empty fallthrough — covers RMB-on-stack (will split-half on
	# release) and clicks on empty slots (which then no-op in the click
	# handler). MUST set _drag_button to the real button so mouse_up's
	# `button != _drag_button` gate doesn't reject the release event.
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
	_cursor.count -= distributed
	if _cursor.count <= 0:
		_cursor.item_id = Blocks.AIR
		_cursor.count = 0
	_refresh()


# --- Click handlers ---


func _handle_left_click(slot_id: int) -> void:
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


func _after_slot_change(_slot_id: int) -> void:
	# Same hotbar-refresh trigger as crafting_table_screen — without this,
	# a freshly-deposited tool might not show in the held visual until the
	# player flips slots and back.
	inventory.changed.emit()
	_refresh()


# Shift-click transfer. Vanilla MC's `transferStackInSlot` rule:
#   chest slot  → first inventory slot that can absorb the stack
#                  (matching item_id with room first, then first empty)
#   inv slot    → first chest slot that can absorb the stack
# Bypasses cursor; called directly from `_input`. The `slot` arg is the
# same negative-encoded value the rest of the screen uses
# (chest slots = -(local_idx + 1); inv slots = positive global index).
func _handle_shift_click(slot: int) -> void:
	if _local_slots.is_empty():
		return
	if slot < 0:
		var local_idx: int = -slot - 1
		var src: ItemStack = _local_slots[local_idx]
		if src.is_empty():
			return
		_transfer_to_inventory(src)
	else:
		var src: ItemStack = inventory.slots[slot]
		if src.is_empty():
			return
		_transfer_to_chest(src)
	_after_slot_change(slot)


func _transfer_to_inventory(src: ItemStack) -> void:
	var leftover: int = inventory.add_item(src.item_id, src.count)
	src.count = leftover
	if leftover == 0:
		src.item_id = Blocks.AIR


# Drop into the first chest slot that already holds the same item with
# room left, then any empty chest slot. Mirrors vanilla's left-to-right
# scan in InventoryLargeChest::mergeItemStack.
func _transfer_to_chest(src: ItemStack) -> void:
	var cap: int = ItemStack.MAX_SIZE
	# First pass: matching item with room.
	for stack: ItemStack in _local_slots:
		if src.count <= 0:
			return
		if stack.item_id == src.item_id and stack.count < cap:
			var space: int = cap - stack.count
			var moved: int = mini(space, src.count)
			stack.count += moved
			src.count -= moved
			if src.count == 0:
				src.item_id = Blocks.AIR
				return
	# Second pass: first empty slot.
	for stack: ItemStack in _local_slots:
		if src.count <= 0:
			return
		if stack.is_empty():
			stack.item_id = src.item_id
			stack.count = src.count
			src.item_id = Blocks.AIR
			src.count = 0
			return


# --- Render ---


func _process(_delta: float) -> void:
	if not visible:
		return
	var mouse: Vector2 = get_global_mouse_position()
	if _cursor_icon.visible:
		_cursor_icon.position = mouse - _cursor_icon.size * 0.5
		_cursor_count_label.position = _cursor_icon.position - Vector2(SCALE, SCALE)
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
	# `_local_slots` is bound on open_for(); it's an empty Array (not null)
	# until then, so we MUST check is_empty() rather than `== null`.
	# Without this, inventory.changed fires from debug spawners / block
	# pickups while the chest screen is closed, _refresh runs, and we
	# index into the empty local-slot array → crash. The chest grid
	# panels harmlessly skip when the local-slot binding isn't ready.
	var have_local: bool = not _local_slots.is_empty()
	for li in _local_node_for.keys():
		var panel: Panel = _local_node_for[li]
		if panel == null:
			continue
		if not have_local:
			_paint_slot(panel, _empty_stack_singleton())
			continue
		_paint_slot(panel, _local_slots[li])
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


# Lazy-init reusable empty-stack singleton — used by _refresh when the
# chest hasn't been bound yet, so painting still clears any stale icon
# without indexing into an empty _local_slots array.
func _empty_stack_singleton() -> ItemStack:
	if _empty_stack == null:
		_empty_stack = ItemStack.new()
	return _empty_stack


func _refresh_cursor_overlay() -> void:
	if _cursor.is_empty():
		_cursor_icon.visible = false
		_cursor_count_label.visible = false
		return
	_cursor_icon.texture = ItemIcons.icon_for(_cursor.item_id)
	_cursor_icon.visible = true
	_cursor_count_label.text = str(_cursor.count) if _cursor.count > 1 else ""
	_cursor_count_label.visible = _cursor.count > 1
