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
	# Gunpowder — canonical Alpha 1.2.6 sprite at items.png (7,8). Used in
	# the TNT recipe; sourced via debug spawner only until creepers ship.
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
# Player + spawn caches. find_child is O(tree); cache the result and
# re-resolve only when the cached node has been freed (scene transition).
static var _cached_player: Node3D = null
static var _cached_spawn: Vector3 = Vector3(0, 70, 0)


static func icon_for(item_id: int) -> Texture2D:
	# Compass / clock — render dynamic icon every call. Both bypass the
	# cache because the needle / dial angle changes per frame: the
	# compass needle tracks atan2(spawn - player), the clock dial tracks
	# WorldTime.current_tick(). The renderers mutate a single ImageTexture per
	# item (not new allocations per call), so the per-frame cost is one
	# 16×16 RGBA8 buffer rebuild + a GPU upload.
	if item_id == Items.COMPASS:
		return _render_compass_icon(_compass_angle())
	if item_id == Items.CLOCK:
		return _render_clock_icon(_clock_angle())
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


# atan2(spawn - player) in icon-space. Inventory open on the main menu (no
# player in tree) returns 0.0 — the needle just points right; harmless.
static func _compass_angle() -> float:
	var player: Node3D = _get_player()
	if player == null:
		return 0.0
	var dx: float = _cached_spawn.x - player.global_position.x
	var dz: float = _cached_spawn.z - player.global_position.z
	# atan2(z, x) so dx=1 yields angle 0 and the needle points east at +X.
	return atan2(dz, dx)


# Full rotation per in-game day (24000 ticks). Subtract PI/2 in the
# renderer so tick 6000 (noon) lands at the top of the dial.
static func _clock_angle() -> float:
	return float(WorldTime.current_tick()) / 24000.0 * TAU


# Render a 16×16 compass face with a needle pointing along `angle` rad.
# Mutates _compass_texture in place so the GPU upload is one .update()
# instead of an allocation. Color palette is solid-Alpha rather than the
# vanilla 16-frame strip (gui/items.png column 6) because procedural is
# cheaper to ship than a 16-step rotation atlas.
static func _render_compass_icon(angle: float) -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	# Face: dark blue-gray. Mirrors the navy disc on vanilla's sprite.
	img.fill(Color(0.15, 0.18, 0.25, 1.0))
	# Outer ring
	var ring := Color(0.45, 0.5, 0.6, 1.0)
	for i in range(16):
		img.set_pixel(i, 0, ring)
		img.set_pixel(i, 15, ring)
		img.set_pixel(0, i, ring)
		img.set_pixel(15, i, ring)
	# Needle: 6-pixel red line from center. Pixel-walk uses round() per
	# step which gives a thick-enough line for 16×16 without antialiasing.
	var cx: float = 7.5
	var cy: float = 7.5
	var needle := Color(0.95, 0.2, 0.2, 1.0)
	for t in range(7):
		var fx: float = cx + cos(angle) * float(t)
		var fy: float = cy + sin(angle) * float(t)
		var x: int = int(round(fx))
		var y: int = int(round(fy))
		if x >= 1 and x < 15 and y >= 1 and y < 15:
			img.set_pixel(x, y, needle)
	# Center hub — slightly brighter so the needle origin reads cleanly.
	img.set_pixel(7, 7, Color(1, 1, 1))
	img.set_pixel(8, 7, Color(1, 1, 1))
	img.set_pixel(7, 8, Color(1, 1, 1))
	img.set_pixel(8, 8, Color(1, 1, 1))
	if _compass_texture == null:
		_compass_texture = ImageTexture.create_from_image(img)
	else:
		_compass_texture.update(img)
	return _compass_texture


# Render a 16×16 clock face with a single hand at `angle` rad. Same
# in-place .update() pattern as the compass.
static func _render_clock_icon(angle: float) -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	# Face: cream / off-white, mimicking vanilla's bone-colored sprite.
	img.fill(Color(0.92, 0.88, 0.78, 1.0))
	# Outer ring — darker bronze.
	var ring := Color(0.45, 0.35, 0.18, 1.0)
	for i in range(16):
		img.set_pixel(i, 0, ring)
		img.set_pixel(i, 15, ring)
		img.set_pixel(0, i, ring)
		img.set_pixel(15, i, ring)
	# Hand: -PI/2 puts angle=0 (tick 0 = midnight) at the top.
	var cx: float = 7.5
	var cy: float = 7.5
	var hand := Color(0.1, 0.1, 0.1, 1.0)
	var draw_angle: float = angle - PI / 2.0
	for t in range(7):
		var fx: float = cx + cos(draw_angle) * float(t)
		var fy: float = cy + sin(draw_angle) * float(t)
		var x: int = int(round(fx))
		var y: int = int(round(fy))
		if x >= 1 and x < 15 and y >= 1 and y < 15:
			img.set_pixel(x, y, hand)
	# Pivot dot.
	img.set_pixel(7, 7, ring)
	img.set_pixel(8, 7, ring)
	img.set_pixel(7, 8, ring)
	img.set_pixel(8, 8, ring)
	if _clock_texture == null:
		_clock_texture = ImageTexture.create_from_image(img)
	else:
		_clock_texture.update(img)
	return _clock_texture
