extends TextureRect

# Vanilla Alpha 1.2.0+ "wearing a pumpkin as a hat" vignette. When the
# helmet slot contains a PUMPKIN block item, the screen gets framed by
# misc/pumpkinblur.png — a 256×256 vignette with carved-eye cutouts
# centered on the camera. Renders over the 3D viewport but under the
# HUD (hotbar, hearts, crosshair) so the player can still see + interact.
#
# Mirrors water_overlay.gd's pattern: gated on a one-shot signal from
# the player so we don't poll the inventory every frame. Player's
# Inventory emits `armor_changed` whenever any armor slot mutates.

const PUMPKIN_ID_BLOCK: int = 46  # Blocks.PUMPKIN — duplicated here to avoid
# preloading the Blocks class just for one int. Bump if the const moves.


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Stretch the 256×256 source over the whole viewport. EXPAND_FIT_WIDTH
	# preserves the central cutout area's aspect more cleanly than KEEP_*
	# alternatives — the cutout stays roughly circular at any window AR.
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	# Hidden until we see a PUMPKIN in the helmet slot.
	visible = false
	# Wire up to player. Inventory exposes armor_changed; we filter to
	# the helmet slot (index ARMOR_SLOT_HEAD = 1 inside the armor array,
	# or Inventory.ARMOR_START + 0 in the flat 45-slot layout).
	var player: Node = get_tree().root.get_node_or_null("Main/Player")
	if player == null:
		return
	var inv: Inventory = player.get("inventory") as Inventory
	if inv == null:
		return
	if inv.has_signal("changed"):
		inv.changed.connect(_refresh)
	_refresh()


# Refresh visibility based on the current head-slot contents. Cheap
# (one stack inspection); safe to call on every inventory change.
func _refresh() -> void:
	var player: Node = get_tree().root.get_node_or_null("Main/Player")
	if player == null:
		visible = false
		return
	var inv: Inventory = player.get("inventory") as Inventory
	if inv == null:
		visible = false
		return
	# Head armor lives at Inventory.ARMOR_START in the flat slot layout.
	var head: ItemStack = inv.slots[Inventory.ARMOR_START] as ItemStack
	visible = (head != null and not head.is_empty() and head.item_id == PUMPKIN_ID_BLOCK)
