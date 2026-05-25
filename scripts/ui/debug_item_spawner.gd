extends Control

# Preloaded so the `TestMob.new()` call below doesn't depend on the
# class_name registry (headless tests don't trigger the editor scan
# that populates it).
const _TEST_MOB_SCRIPT := preload("res://scripts/entities/test_mob.gd")

# Debug item spawner — grid of every implemented block and item, with a
# quantity selector, that dumps stacks into the player's inventory on
# click. Replaces the earlier one-key-per-set debug hotkeys
# (debug_fill_hotbar / _tools / _smelt) since those were getting crowded
# as more items came online. Only active when Game.debug_enabled; toggled
# via the debug_item_spawner action (F4).

const _ICON_SIZE: int = 48
const _COLUMNS: int = 12
const _DEFAULT_QTY: int = 64
const _QTY_MIN: int = 1
const _QTY_MAX: int = 999

# Inventory-placeable blocks. Skipped on purpose:
#   AIR — empty-slot sentinel, can't be held.
#   LIT_FURNACE — tile-entity state, swapped at runtime from FURNACE.
#   FARMLAND — placed-only (reverts to dirt when mined).
#   WATER_FLOWING / WATER_STILL / LAVA_FLOWING / LAVA_STILL — fluid blocks
#     aren't directly holdable; spawn them via BUCKET_WATER / BUCKET_LAVA
#     in the items list below (vanilla parity).
#   FIRE — no flint_and_steel item yet to ignite it.
const _BLOCKS: Array = [
	Blocks.STONE,
	Blocks.COBBLESTONE,
	Blocks.DIRT,
	Blocks.GRASS,
	Blocks.SAND,
	Blocks.GRAVEL,
	Blocks.LOG,
	Blocks.PLANKS,
	Blocks.LEAVES,
	Blocks.SAPLING,
	Blocks.BRICK,
	Blocks.OBSIDIAN,
	Blocks.GLASS,
	Blocks.BEDROCK,
	Blocks.COAL_ORE,
	Blocks.IRON_ORE,
	Blocks.GOLD_ORE,
	Blocks.DIAMOND_ORE,
	Blocks.CRAFTING_TABLE,
	Blocks.FURNACE,
	Blocks.TORCH,
	Blocks.CHEST,
	Blocks.FENCE,
	Blocks.FENCE_GATE,
	Blocks.WOOD_STAIRS,
	Blocks.COBBLESTONE_STAIRS,
	Blocks.LADDER,
	Blocks.FLOWER_RED,
	Blocks.FLOWER_YELLOW,
	Blocks.MUSHROOM_BROWN,
	Blocks.MUSHROOM_RED,
	Blocks.SUGAR_CANE,
	Blocks.ICE,
	Blocks.SNOW_BLOCK,
	Blocks.CACTUS,
	Blocks.SNOW_LAYER,
	Blocks.TNT,
	Blocks.PUMPKIN,
	Blocks.JACK_O_LANTERN,
	Blocks.BOOKSHELF,
	# Classic-era solid blocks (all from Alpha 1.2.6 nq.java).
	Blocks.SPONGE,
	Blocks.IRON_BLOCK,
	Blocks.GOLD_BLOCK,
	Blocks.DIAMOND_BLOCK,
	# Wool family — 16 colors. White had a texture in Alpha terrain.png;
	# the other 15 are procedurally tinted at extract time (Alpha had
	# the meta values but only Beta 1.2 added the dye system + tile art).
	Blocks.WOOL_WHITE,
	Blocks.WOOL_ORANGE,
	Blocks.WOOL_MAGENTA,
	Blocks.WOOL_LIGHT_BLUE,
	Blocks.WOOL_YELLOW,
	Blocks.WOOL_LIME,
	Blocks.WOOL_PINK,
	Blocks.WOOL_GRAY,
	Blocks.WOOL_LIGHT_GRAY,
	Blocks.WOOL_CYAN,
	Blocks.WOOL_PURPLE,
	Blocks.WOOL_BLUE,
	Blocks.WOOL_BROWN,
	Blocks.WOOL_GREEN,
	Blocks.WOOL_RED,
	Blocks.WOOL_BLACK,
	# Clay block — also worldgen-placed in lakes; spawnable here for
	# convenience.
	Blocks.CLAY,
	# Stone / wood / cobblestone slabs — half-slab is the placeable form;
	# double-slab is normally only formed by stacking two halves but
	# exposed here so testers can place it directly.
	Blocks.HALF_SLAB,
	Blocks.DOUBLE_SLAB,
	Blocks.WOOD_HALF_SLAB,
	Blocks.WOOD_DOUBLE_SLAB,
	Blocks.COBBLESTONE_HALF_SLAB,
	Blocks.COBBLESTONE_DOUBLE_SLAB,
]
# Sign item — separate from block list since the item-place handler
# decides standing vs wall sign at right-click time.

const _ITEMS: Array = [
	Items.STICK,
	Items.COAL,
	Items.CHARCOAL,
	Items.IRON_INGOT,
	Items.GOLD_INGOT,
	Items.DIAMOND,
	Items.FLINT,
	Items.LEATHER,
	Items.BONEMEAL,
	Items.GUNPOWDER,
	Items.REDSTONE,
	Items.COMPASS,
	Items.CLOCK,
	Items.BUCKET_EMPTY,
	Items.BUCKET_WATER,
	Items.BUCKET_LAVA,
	Items.FLINT_AND_STEEL,
	Items.WOODEN_DOOR,
	Items.IRON_DOOR,
	Items.SUGAR_CANE,
	Items.WOODEN_PICKAXE,
	Items.WOODEN_AXE,
	Items.WOODEN_SHOVEL,
	Items.WOODEN_SWORD,
	Items.WOODEN_HOE,
	Items.STONE_PICKAXE,
	Items.STONE_AXE,
	Items.STONE_SHOVEL,
	Items.STONE_SWORD,
	Items.IRON_PICKAXE,
	Items.IRON_AXE,
	Items.IRON_SHOVEL,
	Items.IRON_SWORD,
	Items.GOLD_PICKAXE,
	Items.GOLD_AXE,
	Items.GOLD_SHOVEL,
	Items.GOLD_SWORD,
	Items.DIAMOND_PICKAXE,
	Items.DIAMOND_AXE,
	Items.DIAMOND_SHOVEL,
	Items.DIAMOND_SWORD,
	Items.IRON_HELMET,
	Items.IRON_CHESTPLATE,
	Items.IRON_LEGGINGS,
	Items.IRON_BOOTS,
	Items.GOLD_HELMET,
	Items.GOLD_CHESTPLATE,
	Items.GOLD_LEGGINGS,
	Items.GOLD_BOOTS,
	Items.DIAMOND_HELMET,
	Items.DIAMOND_CHESTPLATE,
	Items.DIAMOND_LEGGINGS,
	Items.DIAMOND_BOOTS,
	# Leather armor — lowest defense tier, but recipe-craftable from
	# leather (debug-spawnable). Vanilla T..W (ItemArmor multi-piece).
	Items.LEATHER_HELMET,
	Items.LEATHER_CHESTPLATE,
	Items.LEATHER_LEGGINGS,
	Items.LEATHER_BOOTS,
	# Food + crafting materials shipped with the pre-mob items pass.
	# Apple/bread/etc. have no eating mechanic yet — they're inventory-
	# only until food-eating lands with the hunger system.
	Items.APPLE,
	Items.BREAD,
	Items.WHEAT,
	Items.WHEAT_SEEDS,
	Items.STRING,
	Items.FEATHER,
	Items.PAPER,
	Items.BOOK,
	Items.BRICK,
	Items.SADDLE,
	Items.BOWL,
	Items.MUSHROOM_STEW,
	Items.RAW_PORKCHOP,
	Items.COOKED_PORKCHOP,
	Items.GOLDEN_APPLE,
	# Fishing items — rod is durability-1; cast/reel mechanic follows in
	# a separate commit. Raw + cooked fish exist so the smelting path is
	# debug-testable today (drop raw_fish into furnace input).
	Items.FISHING_ROD,
	Items.RAW_FISH,
	Items.COOKED_FISH,
	# Mob drops + Beta sugar — debug-spawn only until chickens, cows,
	# and cake mechanic land.
	Items.EGG,
	Items.MILK_BUCKET,
	Items.SUGAR,
	Items.CLAY_BALL,
	# Sign item — right-click on a cube to place SIGN_STANDING (top
	# face) or SIGN_WALL (side face). Stage 1: empty text. Stage 2:
	# opens the edit GUI on placement.
	Items.SIGN,
	# Beta Shears — right-click sheep to shear without damage, also
	# clean-breaks leaves / web / vines (latter follows).
	Items.SHEARS,
	# Boat — right-click water to spawn an EntityBoat, right-click an
	# empty boat to mount. Vanilla nv.java (id 333).
	Items.BOAT,
	# Rail — right-click the top face of a solid block to place a rail.
	# Minecart rides on rails. Crafted 6 iron + 1 stick → 16 rails.
	Items.RAIL,
	# Minecart — right-click on a placed rail to spawn an EntityMinecart.
	# Recipe is 5 iron in a U pattern.
	Items.MINECART,
	# Chest minecart — variant of the cart that carries a 27-slot
	# inventory in place of a rider seat. Recipe: 1 minecart + 1 chest.
	Items.MINECART_CHEST,
	# Furnace minecart — variant that takes coal/charcoal as fuel and
	# self-propels. Recipe: 1 minecart + 1 furnace.
	Items.MINECART_FURNACE,
	# Bow + arrow — first projectile + ranged damage system. Bow has 384
	# durability (vanilla ItemBow); arrow stacks to 64 and is consumed
	# per shot (or re-picked from stuck arrows).
	Items.BOW,
	Items.ARROW,
	# Painting — wall-mounted decoration. Right-click a wall face to
	# spawn a randomly-chosen variant whose size fits the open space.
	Items.PAINTING,
	# Bed — multi-cell block. Right-click on the top face of a block to
	# place foot + head. Right-click placed bed at night to skip to dawn
	# + set spawn point.
	Items.BED,
	# Jukebox + first 2 music discs. Right-click jukebox with a disc to
	# insert + start playback; right-click with empty hand to eject.
	Blocks.JUKEBOX,
	Items.MUSIC_DISC_FIRST_LIGHT,
	Items.MUSIC_DISC_GREEN_DISTANCE,
	Items.MUSIC_DISC_LONG_SHADOW,
	Items.MUSIC_DISC_HOLLOW_EARTH,
	Items.MUSIC_DISC_BEDROCK,
	Items.MUSIC_DISC_OPEN_SKY,
	Items.MUSIC_DISC_HEARTHSTONE,
	Items.MUSIC_DISC_STILL_WATER,
]

var _player: Node
var _qty_spin: SpinBox
var _grid: GridContainer
var _prev_mouse_mode: int = Input.MOUSE_MODE_CAPTURED


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_PASS
	visible = false
	_player = get_tree().root.get_node_or_null("Main/Player")
	# Full-screen dim scrim so the world behind reads as background.
	var scrim := ColorRect.new()
	scrim.anchor_right = 1.0
	scrim.anchor_bottom = 1.0
	scrim.color = Color(0, 0, 0, 0.6)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scrim)
	# Centered panel.
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -460
	panel.offset_top = -340
	panel.offset_right = 460
	panel.offset_bottom = 340
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.10, 0.97)
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = Color(0.45, 0.45, 0.48)
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)
	_build_header(vbox)
	_build_grid(vbox)


# Header row: title + quantity spinner + close button.
func _build_header(vbox: VBoxContainer) -> void:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	vbox.add_child(header)
	var title := Label.new()
	title.text = "Item Spawner  (F4 / Esc to close)"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var qty_label := Label.new()
	qty_label.text = "Qty:"
	qty_label.add_theme_font_size_override("font_size", 18)
	header.add_child(qty_label)
	_qty_spin = SpinBox.new()
	_qty_spin.min_value = _QTY_MIN
	_qty_spin.max_value = _QTY_MAX
	_qty_spin.step = 1
	_qty_spin.value = _DEFAULT_QTY
	_qty_spin.custom_minimum_size = Vector2(96, 0)
	header.add_child(_qty_spin)
	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.custom_minimum_size = Vector2(36, 36)
	close_btn.pressed.connect(_hide_spawner)
	header.add_child(close_btn)


# Scrollable grid of clickable item buttons.
func _build_grid(vbox: VBoxContainer) -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = _COLUMNS
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)
	for id: int in _BLOCKS:
		_grid.add_child(_make_cell(id))
	for id: int in _ITEMS:
		_grid.add_child(_make_cell(id))


func _make_cell(item_id: int) -> Button:
	# Mirror the inventory slot layout: Button-as-slot for hover/click and
	# tooltip, with a TextureRect child configured exactly like the real
	# inventory's icon (EXPAND_IGNORE_SIZE, KEEP_ASPECT_CENTERED, NEAREST
	# filter). The Button's own `icon` property would use linear filtering
	# and blur the 16-px pixel-art, so we suppress it and draw via the
	# TextureRect instead.
	var btn := Button.new()
	var outer: int = _ICON_SIZE + 10
	btn.custom_minimum_size = Vector2(outer, outer)
	btn.tooltip_text = _display_name(item_id)
	btn.pressed.connect(_on_cell_pressed.bind(item_id))
	var tex: Texture2D = ItemIcons.icon_for(item_id)
	if tex != null:
		var icon := TextureRect.new()
		icon.texture = tex
		icon.anchor_right = 1.0
		icon.anchor_bottom = 1.0
		icon.offset_left = 5.0
		icon.offset_top = 5.0
		icon.offset_right = -5.0
		icon.offset_bottom = -5.0
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(icon)
	else:
		# Missing texture — fall back to a numeric id so dev can see what
		# the spawner tried to render.
		btn.text = str(item_id)
	return btn


# Per-click quantity — clamp to the item's max stack size so tools/armor
# (max_stack_size == 1) give exactly one instead of a pile of overflows
# that can't stack, regardless of what the spinner reads.
func _on_cell_pressed(item_id: int) -> void:
	if _player == null:
		return
	var inv = _player.get("inventory")
	if inv == null:
		return
	var requested: int = int(_qty_spin.value)
	var cap: int = Items.max_stack_size(item_id)
	var qty: int = mini(requested, cap)
	inv.add_item(item_id, qty)


func _display_name(item_id: int) -> String:
	# Items.display_name covers both blocks and items; fall back to
	# Blocks.name_of for block-ids below 100 when Items doesn't match.
	var pretty: String = Items.display_name(item_id)
	if pretty == "" and item_id < 100:
		pretty = Blocks.name_of(item_id).capitalize()
	return pretty


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("open_item_spawner") and _spawner_available():
		if visible:
			_hide_spawner()
		else:
			_show_spawner()
		get_viewport().set_input_as_handled()
	elif visible and event.is_action_pressed("pause"):
		_hide_spawner()
		get_viewport().set_input_as_handled()


# Spawner is user-facing now: open in either creative or debug. Either
# mode is a valid context for "I'm building / experimenting and want
# unrestricted item access." Survival-mode players still get the gate.
func _spawner_available() -> bool:
	if Game.debug_enabled:
		return true
	if _player != null and "creative_mode" in _player and _player.creative_mode:
		return true
	return false


func _show_spawner() -> void:
	_prev_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	visible = true


func _hide_spawner() -> void:
	visible = false
	Input.mouse_mode = _prev_mouse_mode
