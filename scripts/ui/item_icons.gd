class_name ItemIcons
extends RefCounted

# Maps item IDs to a representative texture for the inventory UI. Block IDs
# pull from the active block-texture pack; non-block items (sticks, tools)
# fall through to a procedural solid-color placeholder until proper sprites
# are added.

const _BLOCK_ICON_NAMES: Dictionary = {
	Blocks.STONE: "stone",
	Blocks.COBBLESTONE: "cobblestone",
	Blocks.DIRT: "dirt",
	Blocks.GRASS: "grass_side",
	Blocks.LOG: "log_side",
	Blocks.PLANKS: "planks",
	Blocks.LEAVES: "leaves",
	Blocks.SAND: "sand",
	Blocks.GRAVEL: "gravel",
	Blocks.BEDROCK: "bedrock",
	Blocks.BRICK: "brick",
	Blocks.OBSIDIAN: "obsidian",
	Blocks.COAL_ORE: "coal_ore",
	Blocks.IRON_ORE: "iron_ore",
	Blocks.GOLD_ORE: "gold_ore",
	Blocks.DIAMOND_ORE: "diamond_ore",
	Blocks.CRAFTING_TABLE: "crafting_table_side",
	Blocks.FURNACE: "furnace_front",
	Blocks.GLASS: "glass",
	Blocks.SAPLING: "sapling",
	Blocks.TORCH: "torch",
	Blocks.LADDER: "ladder",
	Blocks.FLOWER_RED: "flower_red",
	Blocks.FLOWER_YELLOW: "flower_yellow",
	Blocks.MUSHROOM_BROWN: "mushroom_brown",
	Blocks.MUSHROOM_RED: "mushroom_red",
	Blocks.SUGAR_CANE: "sugar_cane",
	Blocks.ICE: "ice",
	Blocks.SNOW_BLOCK: "snow",
	Blocks.CACTUS: "cactus_side",
	Blocks.SNOW_LAYER: "snow",
	# TNT — flat-sprite fallback before BlockIconRenderer's iso-cube bake
	# lands. Uses the side face (lettering) which is the most recognizable.
	Blocks.TNT: "tnt_side",
	# Pumpkin / Jack O'Lantern fallback. Side face (carved) is the most
	# recognizable. BlockIconRenderer's 3D iso bake replaces this once
	# baking finishes.
	Blocks.PUMPKIN: "pumpkin_face",
	Blocks.JACK_O_LANTERN: "jack_o_lantern_face",
	# CROPS uses its mature stage tile as the inventory placeholder
	# (consistent with how SUGAR_CANE shows the plant sprite). In
	# practice the inventory shows WHEAT_SEEDS instead — players never
	# carry a CROPS block directly — but the entry guards against the
	# debug spawner spawning the block id.
	Blocks.CROPS: "crops_stage_7",
	# Classic-era solid blocks. Full cubes — 1-arg fallback is fine.
	# BlockIconRenderer's 3D iso bake replaces these once it iterates
	# through (see _ICONIFIED_BLOCKS).
	Blocks.SPONGE: "sponge",
	Blocks.IRON_BLOCK: "iron_block",
	Blocks.GOLD_BLOCK: "gold_block",
	Blocks.DIAMOND_BLOCK: "diamond_block",
	Blocks.WOOL_WHITE: "wool_white",
	Blocks.WOOL_ORANGE: "wool_orange",
	Blocks.WOOL_MAGENTA: "wool_magenta",
	Blocks.WOOL_LIGHT_BLUE: "wool_light_blue",
	Blocks.WOOL_YELLOW: "wool_yellow",
	Blocks.WOOL_LIME: "wool_lime",
	Blocks.WOOL_PINK: "wool_pink",
	Blocks.WOOL_GRAY: "wool_gray",
	Blocks.WOOL_LIGHT_GRAY: "wool_light_gray",
	Blocks.WOOL_CYAN: "wool_cyan",
	Blocks.WOOL_PURPLE: "wool_purple",
	Blocks.WOOL_BLUE: "wool_blue",
	Blocks.WOOL_BROWN: "wool_brown",
	Blocks.WOOL_GREEN: "wool_green",
	Blocks.WOOL_RED: "wool_red",
	Blocks.WOOL_BLACK: "wool_black",
	# Clay block — full cube; iso-bake handles the inventory icon
	# (block_icon_renderer entry below), but this fallback name is the
	# pre-bake sprite path.
	Blocks.CLAY: "clay",
	# Slabs — flat-sprite fallback uses the side texture (bevel
	# visible), iso bake handles the half-height vs full-height
	# rendering distinction.
	Blocks.HALF_SLAB: "stone_slab_side",
	Blocks.DOUBLE_SLAB: "stone_slab_side",
}

# Item sprite basenames. Resolved at load time: first try
# `packs/{active_pack}/items/{basename}.png`, then fall back to the shared
# `assets/textures/items/{basename}.png` directory. This lets packs ship
# their own item art (like blocks) while allowing any item to use a
# pack-agnostic default.
const _ITEM_TEXTURE_NAMES: Dictionary = {
	Items.STICK: "stick",
	Items.WOODEN_PICKAXE: "wooden_pickaxe",
	Items.WOODEN_AXE: "wooden_axe",
	Items.WOODEN_SHOVEL: "wooden_shovel",
	Items.WOODEN_SWORD: "wooden_sword",
	Items.WOODEN_HOE: "wooden_hoe",
	Items.STONE_PICKAXE: "stone_pickaxe",
	Items.STONE_AXE: "stone_axe",
	Items.STONE_SHOVEL: "stone_shovel",
	Items.STONE_SWORD: "stone_sword",
	Items.IRON_PICKAXE: "iron_pickaxe",
	Items.IRON_AXE: "iron_axe",
	Items.IRON_SHOVEL: "iron_shovel",
	Items.IRON_SWORD: "iron_sword",
	Items.DIAMOND_PICKAXE: "diamond_pickaxe",
	Items.DIAMOND_AXE: "diamond_axe",
	Items.DIAMOND_SHOVEL: "diamond_shovel",
	Items.DIAMOND_SWORD: "diamond_sword",
	Items.GOLD_PICKAXE: "gold_pickaxe",
	Items.GOLD_AXE: "gold_axe",
	Items.GOLD_SHOVEL: "gold_shovel",
	Items.GOLD_SWORD: "gold_sword",
	Items.FLINT: "flint",
	Items.IRON_HELMET: "iron_helmet",
	Items.IRON_CHESTPLATE: "iron_chestplate",
	Items.IRON_LEGGINGS: "iron_leggings",
	Items.IRON_BOOTS: "iron_boots",
	Items.GOLD_HELMET: "gold_helmet",
	Items.GOLD_CHESTPLATE: "gold_chestplate",
	Items.GOLD_LEGGINGS: "gold_leggings",
	Items.GOLD_BOOTS: "gold_boots",
	Items.DIAMOND_HELMET: "diamond_helmet",
	Items.DIAMOND_CHESTPLATE: "diamond_chestplate",
	Items.DIAMOND_LEGGINGS: "diamond_leggings",
	Items.DIAMOND_BOOTS: "diamond_boots",
	Items.LEATHER: "leather",
	Items.CHARCOAL: "charcoal",
	Items.COAL: "coal",
	Items.IRON_INGOT: "iron_ingot",
	Items.GOLD_INGOT: "gold_ingot",
	Items.DIAMOND: "diamond",
	# Bone meal — extracted from vanilla Beta 1.4's gui/items.png (the
	# version that introduced the dye system). Sprite is unchanged in
	# every later version, so this is the canonical look.
	Items.BONEMEAL: "bonemeal",
	# Gunpowder — canonical Alpha 1.2.6 sprite at items.png (8, 2) per
	# dx.K(33).a(40). An earlier extract had this at (7, 8) which is
	# actually the minecart sprite — fixed in extract_alpha_pack.py.
	# Used in the TNT recipe; sourced via debug spawner only until
	# creepers ship.
	Items.GUNPOWDER: "gunpowder",
	# Sugar cane (vanilla "reeds"). Sprite at items.png (11, 1). Held in
	# hand and placeable into a SUGAR_CANE block via interaction.gd.
	Items.SUGAR_CANE: "sugar_cane",
	# Flint and steel — canonical Alpha 1.2.6 sprite at items.png (5,0),
	# extracted by scripts/dev/extract_alpha_pack.py into the alpha_vanilla
	# pack. Other packs fall through to the placeholder color until they
	# ship their own sprite.
	Items.FLINT_AND_STEEL: "flint_and_steel",
	Items.WOODEN_DOOR: "wooden_door",
	Items.IRON_DOOR: "iron_door",
	# Compass + clock + redstone. Compass/clock have a STATIC sprite here
	# for held + dropped rendering (sprite_extruder voxelizes the 2D
	# sprite into a 3D mesh once at pickup). icon_for() short-circuits
	# above this map for COMPASS / CLOCK to render the dynamic dial
	# directly in inventory, so this entry only feeds the world-render
	# paths. Redstone has no special render path — straight sprite.
	Items.COMPASS: "compass",
	Items.CLOCK: "clock",
	Items.REDSTONE: "redstone",
	# Indev / Alpha food + materials added with the items-pre-mobs pass.
	# Sprites extracted from items.png by scripts/dev/extract_alpha_pack.py;
	# see that file for per-item tile coords + vanilla provenance.
	Items.APPLE: "apple",
	Items.BREAD: "bread",
	Items.WHEAT: "wheat",
	Items.WHEAT_SEEDS: "wheat_seeds",
	Items.STRING: "string",
	Items.FEATHER: "feather",
	Items.PAPER: "paper",
	Items.BOOK: "book",
	Items.BRICK: "brick_item",
	Items.SADDLE: "saddle",
	Items.BOWL: "bowl",
	Items.MUSHROOM_STEW: "mushroom_stew",
	Items.LEATHER_HELMET: "leather_helmet",
	Items.LEATHER_CHESTPLATE: "leather_chestplate",
	Items.LEATHER_LEGGINGS: "leather_leggings",
	Items.LEATHER_BOOTS: "leather_boots",
	Items.RAW_PORKCHOP: "raw_porkchop",
	Items.COOKED_PORKCHOP: "cooked_porkchop",
	Items.GOLDEN_APPLE: "golden_apple",
	Items.FISHING_ROD: "fishing_rod",
	Items.RAW_FISH: "raw_fish",
	Items.COOKED_FISH: "cooked_fish",
	Items.EGG: "egg",
	Items.MILK_BUCKET: "milk_bucket",
	Items.SUGAR: "sugar",
	Items.CLAY_BALL: "clay_ball",
	Items.SIGN: "sign",
	Items.SHEARS: "shears",
	Items.BOAT: "boat",
	Items.RAIL: "rail",
	Items.MINECART: "minecart",
	Items.MINECART_CHEST: "minecart_chest",
	Items.MINECART_FURNACE: "minecart_furnace",
	# Bow inventory icon is the relaxed (un-drawn) sprite; the held-bow
	# render in player.gd swaps to bow_pulling_{0,1,2} based on draw
	# progress.
	Items.BOW: "bow",
	Items.ARROW: "arrow",
	# Painting item — small framed-canvas sprite. Right-click on a
	# wall to spawn a `Painting` entity.
	Items.PAINTING: "painting",
	# Bed item — vanilla Beta 1.3+ small-bed sprite. Right-click on
	# the top face of a block to place TWO bed half-blocks (foot + head).
	Items.BED: "bed",
	# Music discs — vanilla Beta 1.4 record_13 / record_cat sprites
	# (the green and tan disc icons). Right-click on a placed jukebox
	# to insert; the disc plays our matching custom music track. Disc
	# stays in the jukebox until ejected.
	Items.MUSIC_DISC_FIRST_LIGHT: "music_disc_first_light",
	Items.MUSIC_DISC_GREEN_DISTANCE: "music_disc_green_distance",
	# Buckets — placeholder colors picked up by the fallback-color path
	# below. Leave them OUT of this table so the icon renderer uses the
	# solid-color fallback; real sprites can be dropped in later.
}

# Placeholder colors for items that don't have real sprites yet. Renders
# as a solid square with a dark border (see _build_solid_icon).
const _ITEM_PLACEHOLDER_COLORS: Dictionary = {
	Items.BUCKET_EMPTY: Color(0.75, 0.75, 0.78),  # steel grey
	Items.BUCKET_WATER: Color(0.25, 0.45, 0.9),  # water blue
	Items.BUCKET_LAVA: Color(0.98, 0.63, 0.0),  # lava orange
}

static var _cache: Dictionary = {}

# Dynamic compass + clock icons — reused across calls via .update() so we
# don't churn ImageTexture instances at 60 fps. Created lazily on first
# render so headless tests that never touch the icon pay no setup cost.
static var _compass_texture: ImageTexture
static var _clock_texture: ImageTexture
# Base sprite buffers (16×16 RGBA) loaded once from disk. Vanilla
# ae.java / gp.java pull these from items.png + misc/dial.png at
# construction time; we extract them at boot.
static var _compass_base: Image = null
static var _clock_base: Image = null
static var _clock_dial: Image = null
# Smoothed angle + angular velocity for the spring-damped needle motion.
# Mirrors vanilla ae.java's `this.i` (angle) + `this.j` (velocity) and
# gp.java's same pair for the clock. Persisted across frames so the
# needle eases into changes rather than snapping.
static var _compass_smoothed: float = 0.0
static var _compass_velocity: float = 0.0
static var _clock_smoothed: float = 0.0
static var _clock_velocity: float = 0.0
# Player + spawn caches. find_child is O(tree); cache the result and
# re-resolve only when the cached node has been freed (scene transition).
# `_cached_spawn` is what the compass needle points at — wired by
# loading_screen.gd after WorldMeta.load_meta returns, and by the
# new-world flows in pause_menu.gd / select_world_screen.gd. Default
# (0, 70, 0) is the pre-world / main-menu fallback only.
static var _cached_player: Node3D = null
static var _cached_spawn: Vector3 = Vector3(0, 70, 0)


# Update the world spawn the compass tracks. Call once per world load
# (and again if /setworldspawn-equivalent commands ever exist). The Y
# component is ignored — the compass is horizontal-only.
static func set_world_spawn(spawn: Vector3) -> void:
	_cached_spawn = spawn


# Per-frame tick called from Game._process so the compass needle + clock
# dial advance in realtime instead of only when the inventory UI fires
# its `changed` signal. Vanilla MC drives TextureFX subclasses from the
# render loop the same way (ae.java::a(), gp.java::a() — called once per
# frame). Each tick is ~10-15 µs (one 16×16 in-place ImageTexture.update
# + ~256 pixel scan for the clock dial substitution); the gate below
# skips entirely when the player has no compass / clock at all so the
# vast majority of inventories pay zero per-frame cost.
static func tick_dynamic_icons() -> void:
	# Don't bother ticking if neither texture has been rendered yet — saves
	# the inventory-scan check below for fresh worlds / players who've
	# never crafted a compass or clock.
	if _compass_texture == null and _clock_texture == null:
		return
	# Skip the actual render when the player isn't carrying one of the
	# dynamic-icon items. The TextureRect already shows the last rendered
	# frame; the player can't see a stale needle if there's no needle
	# being displayed anywhere. Cuts per-frame cost to one inventory walk
	# when nothing's active.
	var has_compass: bool = false
	var has_clock: bool = false
	var player: Node3D = _get_player()
	if player != null:
		var inv: Inventory = player.get("inventory") as Inventory
		if inv != null:
			for slot: ItemStack in inv.slots:
				if slot != null and not slot.is_empty():
					if slot.item_id == Items.COMPASS:
						has_compass = true
					elif slot.item_id == Items.CLOCK:
						has_clock = true
					if has_compass and has_clock:
						break
	if has_compass and _compass_texture != null:
		_render_compass_icon(_compass_target_angle())
	if has_clock and _clock_texture != null:
		_render_clock_icon(_clock_target_angle())


static func icon_for(item_id: int) -> Texture2D:
	# Compass / clock — render dynamic icon every call. Both bypass the
	# cache because the needle / dial angle changes per frame: the
	# compass needle tracks atan2(spawn - player), the clock dial tracks
	# WorldTime.current_tick(). The renderers mutate a single ImageTexture per
	# item (not new allocations per call), so the per-frame cost is one
	# 16×16 RGBA8 buffer rebuild + a GPU upload.
	if item_id == Items.COMPASS:
		return _render_compass_icon(_compass_target_angle())
	if item_id == Items.CLOCK:
		return _render_clock_icon(_clock_target_angle())
	# Buckets — canonical Alpha 1.2.6 sprites (gui/items.png tiles 74/75/76,
	# extracted directly from the vendor jar). Short-circuit above the
	# cache: a prior call before the bucket branch existed could cache
	# null here, and `_cache.has()` returns true on a null value — so
	# going through the cache would keep serving stale nulls forever.
	if item_id == Items.BUCKET_EMPTY:
		return _load_item_sprite("bucket")
	if item_id == Items.BUCKET_WATER:
		return _load_item_sprite("water_bucket")
	if item_id == Items.BUCKET_LAVA:
		return _load_item_sprite("lava_bucket")
	# Vanilla MC renders block icons as live 3D isometric cubes — we match
	# that via BlockIconRenderer's pre-baked viewport snapshots. Falls back
	# to the flat side-face PNG until baking finishes (briefly at startup),
	# then to a solid color square for non-block items.
	var baked: Texture2D = BlockIconRenderer.get_icon(item_id)
	if baked != null:
		return baked
	if _cache.has(item_id):
		return _cache[item_id]
	var tex: Texture2D = null
	if _BLOCK_ICON_NAMES.has(item_id):
		var path := (
			"%s%s/%s.png"
			% [BlockAtlas.PACK_BASE, BlockAtlas.active_pack, _BLOCK_ICON_NAMES[item_id]]
		)
		tex = load(path) as Texture2D
	elif _ITEM_TEXTURE_NAMES.has(item_id):
		tex = _load_item_sprite(_ITEM_TEXTURE_NAMES[item_id])
	elif _ITEM_PLACEHOLDER_COLORS.has(item_id):
		tex = _build_solid_icon(_ITEM_PLACEHOLDER_COLORS[item_id])
	# Last-ditch procedural fallbacks for items whose pixel-art sprite
	# isn't on disk yet. Keeps the debug spawner + inventory readable
	# during development; the asset file wins once dropped in place.
	if tex == null and item_id == Items.BONEMEAL:
		tex = _build_bonemeal_icon()
	# Buckets — explicit branch instead of going through
	# _ITEM_PLACEHOLDER_COLORS. The const-dict lookup turned up empty
	# in practice (either a class-load ordering quirk or a stale _cache
	# entry written before the dict was populated); an explicit branch
	# has no such dependency. Colors match the placeholder table.
	if tex == null and item_id == Items.BUCKET_EMPTY:
		tex = _build_bucket_icon(Color(0.78, 0.78, 0.80), Color(0, 0, 0, 0))
	if tex == null and item_id == Items.BUCKET_WATER:
		tex = _build_bucket_icon(Color(0.78, 0.78, 0.80), Color(0.25, 0.45, 0.9, 1.0))
	if tex == null and item_id == Items.BUCKET_LAVA:
		tex = _build_bucket_icon(Color(0.78, 0.78, 0.80), Color(0.98, 0.63, 0.0, 1.0))
	_cache[item_id] = tex
	return tex


static func clear_cache() -> void:
	_cache.clear()


# Resolves an item sprite to a Texture2D, preferring the active pack's
# `items/` subdirectory and falling back to the shared `assets/textures/items/`
# directory when the pack doesn't override.
static func _load_item_sprite(basename: String) -> Texture2D:
	var pack_path := "%s%s/items/%s.png" % [BlockAtlas.PACK_BASE, BlockAtlas.active_pack, basename]
	if ResourceLoader.exists(pack_path):
		return load(pack_path) as Texture2D
	return load("res://assets/textures/items/%s.png" % basename) as Texture2D


# Procedural 16×16 pile-of-powder sprite — visually matches vanilla's
# bone-meal dye icon well enough to be recognizable. Pile tapers from a
# 1-px top to a ~12-px base; cream body with right-edge shadow and a few
# lighter/darker specks for grain. Transparent background so the slot /
# cell styling shows through.
static func _build_bonemeal_icon() -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var body := Color(0.96, 0.93, 0.78, 1.0)
	var shadow := Color(0.74, 0.70, 0.52, 1.0)
	var highlight := Color(1.0, 0.99, 0.90, 1.0)
	# Per-row [xmin, xmax]; empty row = skip.
	var rows: Array = [
		[],
		[],
		[],
		[7, 8],
		[6, 9],
		[5, 10],
		[5, 11],
		[4, 11],
		[4, 12],
		[3, 12],
		[3, 13],
		[2, 13],
		[2, 14],
		[2, 14],
		[3, 13],
		[],
	]
	for y in range(rows.size()):
		var row: Array = rows[y]
		if row.is_empty():
			continue
		for x in range(int(row[0]), int(row[1]) + 1):
			img.set_pixel(x, y, body)
		# Shadow along the right edge + base for a bit of volume.
		img.set_pixel(int(row[1]), y, shadow)
	# Grain specks.
	img.set_pixel(6, 6, highlight)
	img.set_pixel(9, 9, highlight)
	img.set_pixel(4, 11, highlight)
	img.set_pixel(8, 8, shadow)
	img.set_pixel(5, 13, shadow)
	img.set_pixel(11, 12, shadow)
	return ImageTexture.create_from_image(img)


# Generates a 32x32 solid-color icon with a thin dark border. Cheap stand-in
# for non-block items until proper pixel art is added.
# 16×16 pixel-art bucket sprite. `metal` = pail color, `fluid` = contents
# (alpha=0 for an empty bucket). Rough silhouette: trapezoidal body
# narrowing to the bottom, a 1-px handle over the top, an inner lip so
# the inside shows a hint of fluid. Visually matches vanilla's bucket
# item better than a solid square and — critically — actually renders,
# which the const-dict fallback didn't.
static func _build_bucket_icon(metal: Color, fluid: Color) -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var shadow := Color(metal.r * 0.55, metal.g * 0.55, metal.b * 0.55, 1.0)
	# Handle: thin arc across the top of the bucket, y=2 row only.
	for x in range(5, 11):
		img.set_pixel(x, 2, shadow)
	img.set_pixel(4, 3, shadow)
	img.set_pixel(11, 3, shadow)
	# Body — outer walls (metal) and inner fill (fluid if set, else metal).
	# Rows 4..13 form the pail, tapering from x=[3..12] at top to x=[5..10] at bottom.
	var rows: Array = [
		[3, 12], [3, 12], [4, 11], [4, 11], [4, 11], [5, 10], [5, 10], [5, 10], [5, 10], [5, 10]
	]
	for i in range(rows.size()):
		var y: int = 4 + i
		var row: Array = rows[i]
		var xmin: int = int(row[0])
		var xmax: int = int(row[1])
		for x in range(xmin, xmax + 1):
			img.set_pixel(x, y, metal)
		# Right-edge shadow for a bit of volume.
		img.set_pixel(xmax, y, shadow)
	# Inner fluid — inset one pixel from the outer metal. Only if fluid alpha>0.
	if fluid.a > 0.0:
		var fluid_rows: Array = [
			[4, 11], [4, 11], [5, 10], [5, 10], [5, 10], [6, 9], [6, 9], [6, 9]
		]
		for i in range(fluid_rows.size()):
			var y: int = 4 + i
			var row: Array = fluid_rows[i]
			for x in range(int(row[0]), int(row[1]) + 1):
				img.set_pixel(x, y, fluid)
	return ImageTexture.create_from_image(img)


static func _build_solid_icon(color: Color) -> Texture2D:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.fill(color)
	var border := Color(color.r * 0.4, color.g * 0.4, color.b * 0.4, 1.0)
	for x in range(32):
		img.set_pixel(x, 0, border)
		img.set_pixel(x, 31, border)
		img.set_pixel(0, x, border)
		img.set_pixel(31, x, border)
	return ImageTexture.create_from_image(img)


# --- Dynamic compass + clock icons ---


static func _get_player() -> Node3D:
	if _cached_player != null and is_instance_valid(_cached_player):
		return _cached_player
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	_cached_player = tree.root.find_child("Player", true, false) as Node3D
	return _cached_player


# Target compass needle angle in icon-space. Mirrors ae.java:62-69:
#   d3 = (player_yaw - 90°) * PI/180 - atan2(spawn_z - player_z, spawn_x - player_x)
# Player yaw is already radians in Godot, so the deg→rad conversion
# collapses to (yaw - PI/2). Main menu / no-player fallback returns 0.
static func _compass_target_angle() -> float:
	var player: Node3D = _get_player()
	if player == null:
		return 0.0
	var dx: float = _cached_spawn.x - player.global_position.x
	var dz: float = _cached_spawn.z - player.global_position.z
	return player.rotation.y - PI / 2.0 - atan2(dz, dx)


# Target clock angle. Vanilla gp.java:38-39 reads world.b(1.0)
# (getCelestialAngle, 0=noon, 0.25=sunset, 0.5=midnight, 0.75=sunrise)
# and computes d3 = -f * 2 * PI. Our WorldTime.phase() uses a DIFFERENT
# zero (0=sunrise, 0.25=noon, 0.5=sunset, 0.75=midnight), so we apply
# a -0.25 offset to align with vanilla's celestial-angle convention.
# Without this, the dial reads about 6 hours behind reality (e.g.
# shows midnight when the world clock is at sunrise).
static func _clock_target_angle() -> float:
	return -(WorldTime.phase() - 0.25) * TAU


# Ensure base sprites are loaded into Image buffers. The set_pixelv calls
# below need direct Image access, not Texture2D. Loaded lazily on first
# compass/clock render so headless tests + main menu pay nothing.
static func _ensure_compass_base() -> void:
	if _compass_base != null:
		return
	var tex: Texture2D = _load_item_sprite("compass")
	if tex == null:
		return
	_compass_base = tex.get_image()
	if _compass_base != null and _compass_base.get_format() != Image.FORMAT_RGBA8:
		_compass_base.convert(Image.FORMAT_RGBA8)


static func _ensure_clock_base() -> void:
	if _clock_base == null:
		var tex: Texture2D = _load_item_sprite("clock")
		if tex != null:
			_clock_base = tex.get_image()
			if _clock_base != null and _clock_base.get_format() != Image.FORMAT_RGBA8:
				_clock_base.convert(Image.FORMAT_RGBA8)
	if _clock_dial == null:
		var dial_tex: Texture2D = load("res://assets/textures/gui/dial.png") as Texture2D
		if dial_tex != null:
			_clock_dial = dial_tex.get_image()
			if _clock_dial != null and _clock_dial.get_format() != Image.FORMAT_RGBA8:
				_clock_dial.convert(Image.FORMAT_RGBA8)


# Vanilla ae.java:31-129 port. Spring-damped angle update + needle draw
# on top of the loaded compass.png base sprite. Two needle loops:
#   1. n12 ∈ [-4, 4]:  gray hub crossbar perpendicular to the needle
#   2. n12 ∈ [-8, 16]: needle itself; red for forward half, gray for back
# Compress the y-step by 0.5 — vanilla's perspective trick that makes
# the needle look like it's tilted into the bezel rather than flat-on.
static func _render_compass_icon(target_angle: float) -> Texture2D:
	_ensure_compass_base()
	# Spring-damped update toward target. Wrap delta to [-PI, PI] then
	# clamp velocity-step input to ±1 so a 180° flip doesn't blow up.
	var d2: float = target_angle - _compass_smoothed
	while d2 < -PI:
		d2 += TAU
	while d2 >= PI:
		d2 -= TAU
	d2 = clampf(d2, -1.0, 1.0)
	_compass_velocity += d2 * 0.1
	_compass_velocity *= 0.8
	_compass_smoothed += _compass_velocity
	var d6: float = sin(_compass_smoothed)
	var d7: float = cos(_compass_smoothed)
	# Start from base sprite (gives us the navy bezel + cardinal marks).
	var img: Image
	if _compass_base != null:
		img = _compass_base.duplicate()
	else:
		img = Image.create(16, 16, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.1, 0.12, 0.2))
	# Needle hub crossbar — gray, perpendicular to needle axis.
	var hub := Color8(100, 100, 100)
	for n12 in range(-4, 5):
		var nx: int = int(8.5 + d7 * float(n12) * 0.3)
		var ny: int = int(7.5 - d6 * float(n12) * 0.3 * 0.5)
		if nx >= 0 and nx < 16 and ny >= 0 and ny < 16:
			img.set_pixel(nx, ny, hub)
	# Needle pointer — red front (n12 >= 0), gray back.
	var fwd := Color8(255, 20, 20)
	for n12 in range(-8, 17):
		var nx: int = int(8.5 + d6 * float(n12) * 0.3)
		var ny: int = int(7.5 + d7 * float(n12) * 0.3 * 0.5)
		if nx >= 0 and nx < 16 and ny >= 0 and ny < 16:
			img.set_pixel(nx, ny, fwd if n12 >= 0 else hub)
	if _compass_texture == null:
		_compass_texture = ImageTexture.create_from_image(img)
	else:
		_compass_texture.update(img)
	return _compass_texture


# Vanilla gp.java:34-89 port. Spring-damped angle update + per-pixel
# substitution: for every pixel in the clock base that's a "marker"
# (red-magenta, i.e. R == B and G == 0 and R > 0), sample the dial
# sprite at the rotated UV and blit it through the marker's intensity.
# Non-marker pixels copy from the base unchanged.
static func _render_clock_icon(target_angle: float) -> Texture2D:
	_ensure_clock_base()
	# Spring damping (same as compass).
	var d2: float = target_angle - _clock_smoothed
	while d2 < -PI:
		d2 += TAU
	while d2 >= PI:
		d2 -= TAU
	d2 = clampf(d2, -1.0, 1.0)
	_clock_velocity += d2 * 0.1
	_clock_velocity *= 0.8
	_clock_smoothed += _clock_velocity
	var d4: float = sin(_clock_smoothed)
	var d5: float = cos(_clock_smoothed)
	# Fallback if base sprites missing (shouldn't normally happen).
	if _clock_base == null or _clock_dial == null:
		var fallback := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		fallback.fill(Color(0.92, 0.88, 0.78))
		if _clock_texture == null:
			_clock_texture = ImageTexture.create_from_image(fallback)
		else:
			_clock_texture.update(fallback)
		return _clock_texture
	var img: Image = _clock_base.duplicate()
	for y in range(16):
		for x in range(16):
			var base_color: Color = _clock_base.get_pixel(x, y)
			var r: int = int(base_color.r * 255.0)
			var g: int = int(base_color.g * 255.0)
			var b: int = int(base_color.b * 255.0)
			# Vanilla marker test: r == b AND g == 0 AND r > 0.
			# Those pixels get replaced by the rotated dial sample,
			# modulated by the marker's red intensity.
			if r == b and g == 0 and r > 0:
				var d6: float = -(float(x) / 15.0 - 0.5)
				var d7: float = float(y) / 15.0 - 0.5
				var n7: int = int((d6 * d5 + d7 * d4 + 0.5) * 16.0)
				var n8: int = int((d7 * d5 - d6 * d4 + 0.5) * 16.0)
				var dx_i: int = n7 & 0xF
				var dy_i: int = n8 & 0xF
				var dial_color: Color = _clock_dial.get_pixel(dx_i, dy_i)
				var modulated := Color(
					dial_color.r * base_color.r,
					dial_color.g * base_color.r,
					dial_color.b * base_color.r,
					dial_color.a
				)
				img.set_pixel(x, y, modulated)
	if _clock_texture == null:
		_clock_texture = ImageTexture.create_from_image(img)
	else:
		_clock_texture.update(img)
	return _clock_texture
