extends Control

# Vanilla MC HUD armor row — 10 chest-plate icons stacked above the
# heart row when the player has any armor equipped. Each icon = 2
# defense points (matching the heart-stride convention). Sources
# sprites from gui/icons.png at the canonical Alpha-era atlas coords:
#   (16, 9) empty armor outline (dark)
#   (25, 9) half silver armor
#   (34, 9) full silver armor
#
# Hidden completely when total defense == 0 — matches vanilla which
# only paints the row once you equip your first piece.

const ICONS_PATH: String = "res://assets/textures/gui/icons.png"
const ARMOR_PX: int = 9
const ARMOR_STRIDE: int = 8
const SCALE: int = 4
const ICONS: int = 10  # 10 icons × 2 defense = 20 (full diamond set)

const _ATLAS_EMPTY: Rect2 = Rect2(16, 9, ARMOR_PX, ARMOR_PX)
const _ATLAS_HALF: Rect2 = Rect2(25, 9, ARMOR_PX, ARMOR_PX)
const _ATLAS_FULL: Rect2 = Rect2(34, 9, ARMOR_PX, ARMOR_PX)

var _bg_rects: Array = []  # Array[TextureRect] — outline / empty backdrop
var _fill_rects: Array = []  # Array[TextureRect] — full/half overlay
var _player: Node


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_icons()
	_player = get_tree().root.get_node_or_null("Main/Player")
	if _player != null:
		# Godot fires `_ready` bottom-up, so this HUD's `_ready` runs BEFORE
		# Player._ready — at this moment `_player.inventory` is still null
		# because Player creates it in its own _ready. Without the await,
		# the changed.connect below silently no-ops and the bar never
		# updates when armor is equipped.
		if not _player.is_node_ready():
			await _player.ready
		# Inventory changes drive armor updates — same signal the held-item
		# overlay listens to. Cheap (only walks 4 slots when it fires).
		var inv: Inventory = _player.get("inventory") as Inventory
		if inv != null:
			inv.changed.connect(_on_inventory_changed)
	_refresh()


func _build_icons() -> void:
	var sheet: Texture2D = load(ICONS_PATH) as Texture2D
	for i in range(ICONS):
		var x: int = i * ARMOR_STRIDE * SCALE
		var bg: TextureRect = _make_icon(sheet, _ATLAS_EMPTY)
		bg.position = Vector2(x, 0)
		add_child(bg)
		_bg_rects.append(bg)
		var fill: TextureRect = _make_icon(sheet, _ATLAS_FULL)
		fill.position = Vector2(x, 0)
		fill.visible = false
		add_child(fill)
		_fill_rects.append(fill)
	custom_minimum_size = Vector2(ICONS * ARMOR_STRIDE * SCALE, ARMOR_PX * SCALE)


func _make_icon(sheet: Texture2D, region: Rect2) -> TextureRect:
	var atlas := AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = region
	var tr := TextureRect.new()
	tr.texture = atlas
	tr.size = Vector2(ARMOR_PX * SCALE, ARMOR_PX * SCALE)
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


func _on_inventory_changed() -> void:
	_refresh()


# Total armor = sum of armor_defense for whatever's equipped in the 4
# armor slots (36..39 in the flat inventory array). Hides the whole
# row when sum is 0 — vanilla parity. Fills each icon as full / half /
# empty based on the 2-points-per-icon stride.
func _refresh() -> void:
	var total: int = _total_defense()
	visible = total > 0
	if not visible:
		return
	for i in range(ICONS):
		var pts_for_this: int = clampi(total - i * 2, 0, 2)
		var fill: TextureRect = _fill_rects[i]
		if pts_for_this == 2:
			(fill.texture as AtlasTexture).region = _ATLAS_FULL
			fill.visible = true
		elif pts_for_this == 1:
			(fill.texture as AtlasTexture).region = _ATLAS_HALF
			fill.visible = true
		else:
			fill.visible = false


func _total_defense() -> int:
	if _player == null:
		return 0
	var inv: Inventory = _player.get("inventory") as Inventory
	if inv == null:
		return 0
	# Armor slots are 36..39 in Inventory (helmet, chest, legs, boots).
	var total: int = 0
	for slot_idx: int in [36, 37, 38, 39]:
		if slot_idx >= inv.slots.size():
			continue
		var stack: ItemStack = inv.slots[slot_idx]
		if stack == null or stack.is_empty():
			continue
		total += Items.armor_defense(stack.item_id)
	return total
