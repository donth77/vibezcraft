extends Control

# Renders a 9-slot hotbar at the bottom of the screen and reflects the
# bound Inventory's state. Re-renders whenever the inventory emits `changed`.

const SLOT_SIZE: int = 56
const SLOT_PAD: int = 4

var inventory: Inventory
var _slot_nodes: Array = []  # Array[Panel]


func _ready() -> void:
	var hbox: HBoxContainer = $HBox
	for i in range(Inventory.HOTBAR_SIZE):
		var slot: Panel = _build_slot()
		hbox.add_child(slot)
		_slot_nodes.append(slot)


func bind(inv: Inventory) -> void:
	inventory = inv
	inv.changed.connect(_refresh)
	_refresh()


func _build_slot() -> Panel:
	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.08, 0.6)
	style.border_color = Color(0.4, 0.4, 0.4, 0.9)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	panel.add_theme_stylebox_override("panel", style)
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = SLOT_PAD
	icon.offset_top = SLOT_PAD
	icon.offset_right = -SLOT_PAD
	icon.offset_bottom = -SLOT_PAD
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(icon)
	var count := Label.new()
	count.name = "Count"
	count.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	count.offset_left = -22
	count.offset_top = -22
	count.offset_right = -3
	count.offset_bottom = -3
	count.add_theme_font_size_override("font_size", 13)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(count)
	return panel


func _refresh() -> void:
	if inventory == null:
		return
	for i in range(Inventory.HOTBAR_SIZE):
		var stack: ItemStack = inventory.slots[i]
		var panel: Panel = _slot_nodes[i]
		var icon: TextureRect = panel.get_node("Icon")
		var count_label: Label = panel.get_node("Count")
		if stack.is_empty():
			icon.texture = null
			count_label.text = ""
		else:
			icon.texture = ItemIcons.icon_for(stack.item_id)
			count_label.text = str(stack.count) if stack.count > 1 else ""
		var style: StyleBoxFlat = panel.get_theme_stylebox("panel") as StyleBoxFlat
		if i == inventory.selected_slot:
			style.border_color = Color(1, 1, 1, 0.95)
			style.border_width_left = 3
			style.border_width_right = 3
			style.border_width_top = 3
			style.border_width_bottom = 3
		else:
			style.border_color = Color(0.4, 0.4, 0.4, 0.9)
			style.border_width_left = 2
			style.border_width_right = 2
			style.border_width_top = 2
			style.border_width_bottom = 2
