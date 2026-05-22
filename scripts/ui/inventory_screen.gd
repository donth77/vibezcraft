extends Control

# Vanilla MC Alpha inventory, rendered using the actual inventory.png texture
# (sourced from InventivetalentDev/minecraft-assets, layout has been stable
# since Alpha) and the Minecraftia OTF font (SIL OFL, IdreesInc).
#
# The inventory.png is the source of truth for visual style: panel bezel,
# slot recesses, the crafting arrow, and the empty-armor-slot silhouettes
# are all baked into the texture. We position invisible click-target Panels
# on top of the texture at the exact pixel coords MC uses, plus icon +
# count overlays per slot.
#
# Click model: see _on_mouse_down / _on_mouse_up. Supports left-click
# pick/drop/swap, right-click split-half/drop-one, drag distribution
# across multiple slots (LMB = even split, RMB = one per slot).

const INVENTORY_TEXTURE_PATH: String = "res://assets/textures/gui/inventory.png"
const FONT_PATH: String = "res://assets/fonts/Minecraft.otf"

# Empty-armor-slot silhouettes — modern MC ships them as separate files
# (Alpha had them baked into inventory.png, but our 1.7.10 source moved
# them out). Shown when the corresponding armor slot is empty.
const _ARMOR_SLOT_PLACEHOLDERS: Array = [
	"res://assets/textures/gui/armor_slots/empty_armor_slot_helmet.png",
	"res://assets/textures/gui/armor_slots/empty_armor_slot_chestplate.png",
	"res://assets/textures/gui/armor_slots/empty_armor_slot_leggings.png",
	"res://assets/textures/gui/armor_slots/empty_armor_slot_boots.png",
]

# Native inventory.png is 256×256 with the panel occupying upper-left 176×166.
# We render at 3× scale so a slot is ~54px on a 1080p display — comfortable
# click targets without making the panel huge.
const SCALE: int = 5  # 5x = 880×830 panel — chunky pixel-art look on 1080p
const PANEL_W: int = 176 * SCALE
const PANEL_H: int = 166 * SCALE
const SLOT_PX: int = 18 * SCALE  # 18 native = 16 inner + 1 border each side

# Slot coordinates in NATIVE inventory.png pixels — the *item-render* position
# (top-left of the inner 16×16 area). Verified by direct pixel-inspection of
# the bundled inventory.png; do not change without re-checking the texture.
const _ARMOR_X: int = 8
const _ARMOR_Y: Array = [8, 26, 44, 62]
const _CRAFT_GRID_TL: Vector2i = Vector2i(88, 26)  # 2x2 grid item-pos top-left
const _CRAFT_RESULT_POS: Vector2i = Vector2i(144, 36)  # result slot item-pos
const _MAIN_TL: Vector2i = Vector2i(8, 84)  # main inv 3x9 origin
const _HOTBAR_TL: Vector2i = Vector2i(8, 142)  # hotbar 1x9 origin
const _TITLE_POS: Vector2i = Vector2i(88, 17)  # "Crafting" — sits just above 2x2 grid

# Vanilla title color: 0x404040 dark grey.
const _COLOR_TITLE: Color = Color8(64, 64, 64)

var inventory: Inventory
var _cursor: ItemStack
var _slot_nodes: Array = []  # Array[Panel], indexed by inventory slot id
var _cursor_icon: TextureRect
var _cursor_count_label: Label
var _font: FontFile
var _tooltip: Label

# Drag state — see _on_mouse_down/up below.
var _drag_active: bool = false
var _drag_button: int = -1
var _drag_slots: Array = []
var _drag_starting_count: int = 0
var _drag_starting_id: int = 0


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cursor = ItemStack.new()
	_font = MinecraftFont.get_font()
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
	# CenterContainer keeps the panel centered regardless of viewport size.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(center)

	# Root for the panel + all overlays. Sized to PANEL_W × PANEL_H so
	# child positions can use the same coord system as inventory.png.
	var root := Control.new()
	root.custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	center.add_child(root)

	# The actual inventory.png drawn behind everything else. The texture is
	# 256×256 but only the upper-left 176×166 is the panel — clip to that.
	var bg := TextureRect.new()
	bg.texture = load(INVENTORY_TEXTURE_PATH) as Texture2D
	bg.size = Vector2(PANEL_W, PANEL_H)
	# Use REGION to crop the panel out of the 256×256 atlas.
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Crop the unused right/bottom of the 256×256 atlas via a clipping AtlasTexture.
	var atlas := AtlasTexture.new()
	atlas.atlas = bg.texture
	atlas.region = Rect2(0, 0, 176, 166)
	bg.texture = atlas
	root.add_child(bg)

	# "Crafting" title at native (86, 6).
	var title := Label.new()
	title.text = "Crafting"
	title.add_theme_color_override("font_color", _COLOR_TITLE)
	title.add_theme_font_override("font", _font)
	title.add_theme_font_size_override("font_size", 8 * SCALE)
	title.position = Vector2(_TITLE_POS.x * SCALE, _TITLE_POS.y * SCALE)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(title)

	# Character preview lives in the recessed dark rectangle baked into
	# inventory.png, between the armor column and the 2x2 craft grid.
	# Verified by pixel inspection: x=27..77, y=8..77 (50 wide × 70 tall).
	var preview := CharacterPreview.new()
	preview.position = Vector2(27 * SCALE, 8 * SCALE)
	preview.size = Vector2(50 * SCALE, 70 * SCALE)
	root.add_child(preview)

	# Click-target slots overlaid on the baked texture.
	_place_slot_overlay(root, Inventory.ARMOR_START + 0, _ARMOR_X, _ARMOR_Y[0])
	_place_slot_overlay(root, Inventory.ARMOR_START + 1, _ARMOR_X, _ARMOR_Y[1])
	_place_slot_overlay(root, Inventory.ARMOR_START + 2, _ARMOR_X, _ARMOR_Y[2])
	_place_slot_overlay(root, Inventory.ARMOR_START + 3, _ARMOR_X, _ARMOR_Y[3])

	# 2x2 craft grid (slots touch at 18px native = SLOT_PX scaled).
	for r in range(2):
		for c in range(2):
			_place_slot_overlay(
				root,
				Inventory.CRAFT_START + r * 2 + c,
				_CRAFT_GRID_TL.x + c * 18,
				_CRAFT_GRID_TL.y + r * 18,
			)

	_place_slot_overlay(root, Inventory.CRAFT_RESULT, _CRAFT_RESULT_POS.x, _CRAFT_RESULT_POS.y)

	# Main 3x9 inventory.
	for r in range(3):
		for c in range(9):
			_place_slot_overlay(
				root,
				Inventory.MAIN_START + r * 9 + c,
				_MAIN_TL.x + c * 18,
				_MAIN_TL.y + r * 18,
			)

	# Hotbar 1x9.
	for c in range(9):
		_place_slot_overlay(root, Inventory.HOTBAR_START + c, _HOTBAR_TL.x + c * 18, _HOTBAR_TL.y)


# Creates an invisible Panel covering one slot's bezel at (native_x, native_y),
# with Icon + Count children. native_x/y are MC's canonical slot coords —
# the position where the ITEM renders (top-left of the inner 16×16 area).
# The bezel is 1px out on each side, so the click target panel needs that -1
# offset to cover the visible bezel rectangle.
func _place_slot_overlay(parent: Control, slot_index: int, native_x: int, native_y: int) -> void:
	var panel := Panel.new()
	panel.position = Vector2((native_x - 1) * SCALE, (native_y - 1) * SCALE)
	panel.size = Vector2(SLOT_PX, SLOT_PX)  # 18×SCALE — covers bezel + inner area
	var style := StyleBoxEmpty.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(panel)

	# Icon at canonical (1, 1) inset within the bezel, sized 16×SCALE — the
	# exact rectangle MC uses to render the held item sprite.
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.position = Vector2(1 * SCALE, 1 * SCALE)
	icon.size = Vector2(16 * SCALE, 16 * SCALE)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(icon)

	# Count label fills the slot, right/bottom-aligned. Font sized so "64"
	# tucks into the bottom-right corner without overflowing the cell.
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

	# Durability bar — pinned 1 native pixel above the slot's bottom edge,
	# inside the bezel. Refresh wires the stack in `_refresh`.
	var bar := DurabilityBar.new()
	bar.name = "DurabilityBar"
	bar.scale_factor = SCALE
	bar.position = Vector2(1 * SCALE, (1 + 16 - 2) * SCALE)
	bar.size = Vector2(16 * SCALE, SCALE)
	panel.add_child(bar)

	while _slot_nodes.size() <= slot_index:
		_slot_nodes.append(null)
	_slot_nodes[slot_index] = panel


func _build_cursor_overlay() -> void:
	# Cursor icon mirrors a slot's icon size (16 native = 16×SCALE) so the
	# stack visually matches what a slot would show — no resize jump when
	# the cursor item lands in a slot.
	_cursor_icon = TextureRect.new()
	_cursor_icon.size = Vector2(16 * SCALE, 16 * SCALE)
	_cursor_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cursor_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_cursor_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_cursor_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_icon.visible = false
	add_child(_cursor_icon)
	# Count label uses the SAME geometry, font size and alignment as a
	# slot's count label so the "64" sits in the bottom-right of the icon
	# rect — no positional jump when the stack transitions cursor ↔ slot.
	_cursor_count_label = Label.new()
	_cursor_count_label.add_theme_font_override("font", _font)
	_cursor_count_label.add_theme_font_size_override("font_size", 8 * SCALE)
	_cursor_count_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_cursor_count_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0))
	_cursor_count_label.add_theme_constant_override("shadow_offset_x", SCALE)
	_cursor_count_label.add_theme_constant_override("shadow_offset_y", SCALE)
	# 18×SCALE rect (matches a slot panel's count label dims) so the
	# bottom-right text lands 1×SCALE below the 16×SCALE icon — same
	# spot a stack's count occupies in a slot. _process re-positions
	# the rect each frame at icon.pos - (SCALE, SCALE).
	_cursor_count_label.size = Vector2(18 * SCALE, 18 * SCALE)
	_cursor_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_cursor_count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_cursor_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_count_label.visible = false
	add_child(_cursor_count_label)

	# Tooltip label — appears next to the cursor when hovering a non-empty
	# slot with no stack on cursor. Vanilla MC look: dark semi-transparent
	# panel with the item's display name in white.
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
	# Tooltip should draw above EVERYTHING else, including the cursor.
	add_child(_tooltip)
	move_child(_tooltip, get_child_count() - 1)


# --- Open / close ---


func _open() -> void:
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if inventory != null:
		inventory.recompute_craft_result()
	_refresh()


func _close() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if not _cursor.is_empty() and inventory != null:
		var leftover: int = inventory.add_item(_cursor.item_id, _cursor.count)
		_cursor.item_id = Blocks.AIR
		_cursor.count = leftover
	_refresh_cursor_overlay()


# --- Input + drag ---


func _input(event: InputEvent) -> void:
	if not visible or inventory == null:
		return
	if event is InputEventMouseButton:
		var slot: int = _slot_under_mouse()
		# Vanilla Container.transferStackInSlot: shift+left-click sends
		# the clicked stack to the "other" zone — armor pieces go to
		# their matching armor slot, everything else hops between
		# main/hotbar. Bypasses cursor entirely.
		if (
			event.pressed
			and event.button_index == MOUSE_BUTTON_LEFT
			and event.shift_pressed
			and slot >= 0
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
		return -1
	var mouse: Vector2 = get_global_mouse_position()
	for i in range(_slot_nodes.size()):
		var panel: Panel = _slot_nodes[i]
		if panel == null:
			continue
		var rect := Rect2(panel.global_position, panel.size)
		if rect.has_point(mouse):
			return i
	return -1


func _on_mouse_down(button: int, slot: int) -> void:
	if button != MOUSE_BUTTON_LEFT and button != MOUSE_BUTTON_RIGHT:
		return
	if slot < 0:
		return
	# Three press-time modes:
	#   • Cursor non-empty + normal slot → DISTRIBUTE drag (sweep across slots
	#     to split-even on LMB or one-each on RMB) — vanilla MC.
	#   • Cursor empty + slot has items + LMB → MOVE drag: pick up the stack
	#     immediately so it follows the mouse, then drop wherever the user
	#     releases. Lets you literally click-and-drag stacks across slots.
	#   • Anything else → wait for release, treat as a click.
	if not _cursor.is_empty() and slot != Inventory.CRAFT_RESULT:
		_drag_active = true
		_drag_button = button
		_drag_slots = [slot]
		_drag_starting_count = _cursor.count
		_drag_starting_id = _cursor.item_id
		return
	if (
		button == MOUSE_BUTTON_LEFT
		and _cursor.is_empty()
		and slot != Inventory.CRAFT_RESULT
		and not inventory.slots[slot].is_empty()
	):
		# Pick up immediately on press → cursor follows mouse → release drops.
		_handle_left_click(slot)
		_drag_active = false  # no distribution on release; just a normal drop
		_drag_button = button
		_drag_slots = [slot]
		return
	# Click-only mode: actual handling fires on release.
	_drag_active = false
	_drag_button = button
	_drag_slots = [slot]


func _on_mouse_up(button: int, slot: int) -> void:
	if button != _drag_button:
		return
	if _drag_active and _drag_slots.size() > 1:
		_apply_drag_distribution()
	else:
		# Single-slot interaction or move-drag drop. The release slot wins
		# unless the cursor is hovering off a slot, in which case the press
		# slot is used as fallback.
		var click_slot: int = slot if slot >= 0 else _drag_slots[0]
		if click_slot >= 0 and click_slot != _drag_slots[0]:
			# Drag-moved to a different slot → drop on release target.
			if button == MOUSE_BUTTON_LEFT:
				_handle_left_click(click_slot)
			elif button == MOUSE_BUTTON_RIGHT:
				_handle_right_click(click_slot)
		elif click_slot >= 0 and not _was_press_pickup():
			# Same-slot click without an immediate pickup — fire normal handler.
			if button == MOUSE_BUTTON_LEFT:
				_handle_left_click(click_slot)
			elif button == MOUSE_BUTTON_RIGHT:
				_handle_right_click(click_slot)
	_drag_active = false
	_drag_button = -1
	_drag_slots.clear()


func _was_press_pickup() -> bool:
	# True if _on_mouse_down already picked up the stack (move-drag mode)
	# and we should NOT re-fire the click handler on release.
	return (
		_drag_button == MOUSE_BUTTON_LEFT
		and not _drag_active
		and _drag_slots.size() == 1
		and not _cursor.is_empty()
		and inventory.slots[_drag_slots[0]].is_empty()
	)


func _track_drag_motion() -> void:
	var hovered: int = _slot_under_mouse()
	if hovered < 0 or _drag_slots.has(hovered):
		return
	if hovered == Inventory.CRAFT_RESULT:
		return
	var slot: ItemStack = inventory.slots[hovered]
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
	for slot_index: int in _drag_slots:
		var slot: ItemStack = inventory.slots[slot_index]
		if slot.is_empty():
			slot.item_id = _drag_starting_id
		var room: int = ItemStack.MAX_SIZE - slot.count
		var added: int = mini(per_slot, room)
		slot.count += added
		distributed += added
		if slot_index >= Inventory.CRAFT_START and slot_index < Inventory.CRAFT_RESULT:
			craft_touched = true
	_cursor.count -= distributed
	if _cursor.count <= 0:
		_cursor.item_id = Blocks.AIR
		_cursor.count = 0
	if craft_touched:
		inventory.recompute_craft_result()
	inventory.changed.emit()


# --- Click handlers ---


func _handle_left_click(slot_index: int) -> void:
	if slot_index == Inventory.CRAFT_RESULT:
		_take_craft_result()
		return
	# Armor slots reject items that don't match the expected armor kind.
	# Clicking anyway is a no-op (cursor keeps its stack), matching vanilla.
	if _is_armor_slot(slot_index) and not _cursor.is_empty():
		var want: int = slot_index - Inventory.ARMOR_START + Items.ARMOR_SLOT_HEAD
		if Items.armor_slot_for(_cursor.item_id) != want:
			return
	var slot: ItemStack = inventory.slots[slot_index]
	if _cursor.is_empty() and slot.is_empty():
		return
	# Vanilla SlotArmor.getSlotStackLimit()=1 — armor slots only ever hold
	# one piece, regardless of how many are on the cursor. Move exactly 1
	# from the cursor into an empty armor slot; leave the rest on cursor.
	if _is_armor_slot(slot_index) and not _cursor.is_empty() and slot.is_empty():
		slot.item_id = _cursor.item_id
		slot.count = 1
		slot.damage = _cursor.damage
		_cursor.count -= 1
		if _cursor.count <= 0:
			_cursor.clear()
		_after_slot_change(slot_index)
		return
	if _cursor.is_empty():
		_cursor.copy_from(slot)
		slot.clear()
	elif slot.is_empty():
		slot.copy_from(_cursor)
		_cursor.clear()
	elif slot.item_id == _cursor.item_id:
		_cursor.count = slot.add(_cursor.count)
		if _cursor.count == 0:
			_cursor.item_id = Blocks.AIR
	else:
		# Full swap — needs a temp stack so the damage value doesn't get
		# clobbered mid-swap.
		var tmp := ItemStack.new(slot.item_id, slot.count)
		tmp.damage = slot.damage
		slot.copy_from(_cursor)
		_cursor.copy_from(tmp)
	_after_slot_change(slot_index)


func _handle_shift_click(slot_index: int) -> void:
	# Vanilla shift-click routing:
	#   • Armor item in main/hotbar → fly to matching armor slot if empty
	#   • Item in armor slot → fly back to main/hotbar
	#   • Crafting result → take whole result, distribute (consumes inputs)
	#   • Anything else: hop between hotbar (0-8) and main (9-35)
	# Cursor is untouched. Whole-stack transfer; partial split happens only
	# when the destination already has a partial stack of the same id.
	if slot_index == Inventory.CRAFT_RESULT:
		# Repeatedly take the result + add to inventory until inputs run out.
		while true:
			var result: ItemStack = inventory.slots[Inventory.CRAFT_RESULT]
			if result.is_empty():
				break
			var added_id: int = result.item_id
			var added_n: int = result.count
			var overflow: int = inventory.add_item(added_id, added_n)
			if overflow > 0:
				break  # no more room
			inventory.consume_craft_inputs()
		_after_slot_change(slot_index)
		return
	var src: ItemStack = inventory.slots[slot_index]
	if src.is_empty():
		return
	var armor_kind: int = Items.armor_slot_for(src.item_id)
	# Source is armor in main/hotbar → equip into matching armor slot if free.
	# Move exactly 1 piece (SlotArmor stack-limit=1); leave the rest in src.
	if armor_kind != Items.ARMOR_SLOT_NONE and not _is_armor_slot(slot_index):
		var dest: int = Inventory.ARMOR_START + armor_kind - Items.ARMOR_SLOT_HEAD
		var dest_slot: ItemStack = inventory.slots[dest]
		if dest_slot.is_empty():
			dest_slot.item_id = src.item_id
			dest_slot.count = 1
			dest_slot.damage = src.damage
			src.count -= 1
			if src.count <= 0:
				src.clear()
			_after_slot_change(slot_index)
			return
		# Slot taken — fall through to the generic main/hotbar hop below.
	# Source is in an armor slot → send to inventory.
	if _is_armor_slot(slot_index):
		var overflow_a: int = inventory.add_item(src.item_id, src.count)
		src.count = overflow_a
		if src.count <= 0:
			src.clear()
		_after_slot_change(slot_index)
		return
	# Generic hop: hotbar (0-8) ↔ main (9-35). Find the FIRST same-id partial
	# stack in the destination zone, else first empty.
	var to_hotbar: bool = slot_index >= Inventory.MAIN_START
	var range_start: int
	var range_end: int
	if to_hotbar:
		range_start = 0
		range_end = Inventory.HOTBAR_SIZE
	else:
		range_start = Inventory.MAIN_START
		range_end = Inventory.MAIN_START + Inventory.MAIN_SIZE
	# Pass 1 — merge into existing partials of the same id.
	var max_per_slot: int = Items.max_stack_size(src.item_id)
	for i in range(range_start, range_end):
		if src.is_empty():
			break
		var other: ItemStack = inventory.slots[i]
		if other.item_id == src.item_id and other.count < max_per_slot:
			var room: int = max_per_slot - other.count
			var moved: int = mini(room, src.count)
			other.count += moved
			src.count -= moved
			if src.count <= 0:
				src.clear()
	# Pass 2 — fill empty slots in the destination zone.
	for i in range(range_start, range_end):
		if src.is_empty():
			break
		var other2: ItemStack = inventory.slots[i]
		if other2.is_empty():
			other2.copy_from(src)
			src.clear()
	_after_slot_change(slot_index)


func _is_armor_slot(slot_index: int) -> bool:
	return (
		slot_index >= Inventory.ARMOR_START
		and slot_index < Inventory.ARMOR_START + Inventory.ARMOR_SIZE
	)


func _handle_right_click(slot_index: int) -> void:
	if slot_index == Inventory.CRAFT_RESULT:
		_take_craft_result()
		return
	var slot: ItemStack = inventory.slots[slot_index]
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
	_after_slot_change(slot_index)


func _take_craft_result() -> void:
	var result: ItemStack = inventory.slots[Inventory.CRAFT_RESULT]
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
	inventory.consume_craft_inputs()
	_refresh_cursor_overlay()


func _after_slot_change(slot_index: int) -> void:
	if slot_index >= Inventory.CRAFT_START and slot_index < Inventory.CRAFT_RESULT:
		inventory.recompute_craft_result()
	inventory.changed.emit()


# --- Render ---


func _process(_delta: float) -> void:
	if not visible:
		return
	var mouse: Vector2 = get_global_mouse_position()
	if _cursor_icon.visible:
		_cursor_icon.position = mouse - _cursor_icon.size * 0.5
		# A slot's count label sits in an SLOT_PX (18×SCALE) box positioned
		# at the panel's origin — so its bottom-aligned text lands 1×SCALE
		# *below* the 16×SCALE icon. To keep the count from jumping up by
		# 1×SCALE when an item leaves a slot for the cursor, mirror that
		# offset here: shift the cursor's count rect 1×SCALE up-left of the
		# icon and pad it by 2×SCALE in both dimensions.
		_cursor_count_label.position = _cursor_icon.position - Vector2(SCALE, SCALE)
	_update_tooltip(mouse)


func _update_tooltip(mouse: Vector2) -> void:
	# Hide while a stack is on the cursor (matches vanilla — tooltips only
	# appear when the cursor is empty).
	if not _cursor.is_empty():
		_tooltip.visible = false
		return
	var slot: int = _slot_under_mouse()
	if slot < 0 or inventory == null:
		_tooltip.visible = false
		return
	var stack: ItemStack = inventory.slots[slot]
	if stack.is_empty():
		_tooltip.visible = false
		return
	_tooltip.text = Items.display_name(stack.item_id)
	_tooltip.visible = true
	# Position to the lower-right of the cursor, MC-style. Auto-clamp to
	# screen so tooltips on right-edge slots don't get cut off.
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
	for i in range(_slot_nodes.size()):
		var panel: Panel = _slot_nodes[i]
		if panel == null:
			continue
		var stack: ItemStack = inventory.slots[i]
		var icon: TextureRect = panel.get_node("Icon")
		var count_label: Label = panel.get_node("Count")
		var bar: DurabilityBar = panel.get_node("DurabilityBar") as DurabilityBar
		if stack.is_empty():
			icon.texture = _placeholder_for_empty_slot(i)
			# Empty placeholders render dimmer so they read as "ghost" hints.
			icon.modulate = Color(1, 1, 1, 0.45) if icon.texture != null else Color(1, 1, 1, 1)
			count_label.text = ""
		else:
			icon.texture = ItemIcons.icon_for(stack.item_id)
			icon.modulate = Color(1, 1, 1, 1)
			count_label.text = str(stack.count) if stack.count > 1 else ""
		bar.bind(stack, 16 * SCALE)
	_refresh_cursor_overlay()


func _placeholder_for_empty_slot(slot_index: int) -> Texture2D:
	if (
		slot_index >= Inventory.ARMOR_START
		and slot_index < Inventory.ARMOR_START + Inventory.ARMOR_SIZE
	):
		var path: String = _ARMOR_SLOT_PLACEHOLDERS[slot_index - Inventory.ARMOR_START]
		return load(path) as Texture2D
	return null


func _refresh_cursor_overlay() -> void:
	if _cursor.is_empty():
		_cursor_icon.visible = false
		_cursor_count_label.visible = false
		return
	_cursor_icon.texture = ItemIcons.icon_for(_cursor.item_id)
	_cursor_icon.visible = true
	_cursor_count_label.text = str(_cursor.count) if _cursor.count > 1 else ""
	_cursor_count_label.visible = _cursor.count > 1
