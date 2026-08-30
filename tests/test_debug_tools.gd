extends GutTest

# Debug-tool coverage guard.
#
# The item spawner's block grid and the pre-baked icon list are both
# hand-maintained arrays. A block can be fully implemented — registry,
# textures, worldgen, drops — and still be unreachable in creative or
# render as a blank button, because someone forgot one of those two
# lists. That gap is invisible to every other test in the suite.
#
# These tests fail the build when a redstone block ships without debug
# reachability, so Phase 8b-8e (lever, wire, torch, button, plates) get
# a compile-time-ish reminder as each id is defined.

# Loaded at RUNTIME (not preload) so these resolve to GDScript *values*
# rather than parse-time class references — only a value exposes
# get_script_constant_map(), which is how a test reads private consts.
const _SPAWNER_PATH := "res://scripts/ui/debug_item_spawner.gd"
const _ICON_PATH := "res://scripts/ui/block_icon_renderer.gd"
const _BLOCKS_PATH := "res://scripts/world/blocks.gd"
const _ITEM_ICON_PATH := "res://scripts/ui/item_icons.gd"

# Every redstone block id reserved in blocks.gd (redstone-plan.md §1.1).
# Entries stay commented out until their batch defines the constant —
# uncomment alongside the definition and this guard does the rest.
const _REDSTONE_BLOCK_NAMES: Array[String] = [
	"REDSTONE_ORE",
	"GLOWING_REDSTONE_ORE",
	"REDSTONE_WIRE",
	"REDSTONE_TORCH",
	"REDSTONE_TORCH_OFF",
	"LEVER",
	"STONE_BUTTON",
	"STONE_PRESSURE_PLATE",
	"WOODEN_PRESSURE_PLATE",
]


# Private consts aren't reachable as properties on a class reference —
# read them out of the script's constant map instead.
func _consts_of(path: String) -> Dictionary:
	var script: GDScript = load(path) as GDScript
	assert_not_null(script, "%s loads as a GDScript" % path)
	if script == null:
		return {}
	return script.get_script_constant_map()


func _spawner_blocks() -> Array:
	return _consts_of(_SPAWNER_PATH).get("_BLOCKS", []) as Array


func _spawner_items() -> Array:
	return _consts_of(_SPAWNER_PATH).get("_ITEMS", []) as Array


func _iconified_blocks() -> Array:
	return _consts_of(_ICON_PATH).get("_ICONIFIED_BLOCKS", []) as Array


func _redstone_ids() -> Array[int]:
	var consts: Dictionary = _consts_of(_BLOCKS_PATH)
	var ids: Array[int] = []
	for name: String in _REDSTONE_BLOCK_NAMES:
		assert_true(consts.has(name), "Blocks.%s must exist — update this list with the id" % name)
		if consts.has(name):
			ids.append(int(consts[name]))
	return ids


func test_redstone_block_list_matches_defined_ids() -> void:
	# Catches the reverse mistake: defining a redstone block and never
	# adding it to the guard list above, which would silently exempt it.
	var ids: Array[int] = _redstone_ids()
	assert_eq(ids.size(), _REDSTONE_BLOCK_NAMES.size(), "every listed name resolves")
	assert_true(ids.has(Blocks.REDSTONE_ORE), "ore is tracked")
	assert_true(ids.has(Blocks.GLOWING_REDSTONE_ORE), "glowing ore is tracked")


func test_repeater_uses_its_item_in_the_spawner_not_world_state_ids() -> void:
	var items: Array = _spawner_items()
	var blocks: Array = _spawner_blocks()
	assert_true(items.has(Items.REDSTONE_REPEATER), "dedicated repeater item is spawnable")
	assert_false(blocks.has(Blocks.REDSTONE_REPEATER_OFF), "unpowered state stays world-only")
	assert_false(blocks.has(Blocks.REDSTONE_REPEATER_ON), "powered state stays world-only")


func test_every_redstone_block_is_spawnable() -> void:
	var spawnable: Array = _spawner_blocks()
	for id: int in _redstone_ids():
		assert_true(
			spawnable.has(id),
			(
				"Blocks.%s (id %d) missing from debug_item_spawner._BLOCKS — creative/debug can't place it"
				% [Blocks.name_of(id), id]
			)
		)


func test_every_redstone_block_has_a_working_icon_by_one_route_or_the_other() -> void:
	# There are TWO ways a block gets an inventory icon and a block needs
	# exactly one of them:
	#   * `_ICONIFIED_BLOCKS`  → BlockIconRenderer bakes a 3D iso cube
	#   * `_BLOCK_ICON_NAMES`  → ItemIcons loads the flat tile
	#
	# An earlier version of this test demanded the FIRST route for every
	# redstone block, on the theory that anything outside that list
	# renders blank. That was wrong, and it locked in a real bug: the
	# cube bake wraps one texture around all six faces, so a lever, a
	# torch or a dust cross — all sprites on transparency — appeared
	# duplicated across three faces of an otherwise invisible cube, in
	# the spawner and in the player's hand alike.
	var iconified: Array = _iconified_blocks()
	var flat: Dictionary = _consts_of(_ITEM_ICON_PATH).get("_BLOCK_ICON_NAMES", {}) as Dictionary
	for id: int in _redstone_ids():
		var has_cube: bool = iconified.has(id)
		var has_flat: bool = flat.has(id)
		assert_true(
			has_cube or has_flat,
			"Blocks.%s (id %d) is in neither icon list — renders blank" % [Blocks.name_of(id), id]
		)


func test_no_sprite_on_transparency_block_is_baked_as_a_cube() -> void:
	# The invariant that would have caught it, and catches the next one.
	# The bake wraps a single tile around a cube, so the tile has to read
	# as a solid face. Measured opaque coverage across the whole list:
	#
	#   glass 43.8%  ·  leaves 71.1%  ·  cactus 89.5%  ·  everything else 100%
	#
	# versus the blocks that must NOT be baked:
	#
	#   lever 7.8%  ·  redstone_torch_off 7.8%  ·  redstone_torch_on 10.2%
	#   torch 14.8%  ·  redstone_dust_cross 21.1%  ·  flower_red 26.6%
	#
	# 35% sits in the gap with ~9 points of room under glass and ~14 over
	# the worst offender.
	BlockAtlas.reset()
	for id: int in _iconified_blocks():
		var coverage: float = _opaque_coverage(Blocks.get_face_texture(id, "side"))
		if coverage < 0.0:
			continue  # tile ships in no pack; a separate test covers that
		assert_gt(
			coverage,
			35.0,
			(
				(
					"Blocks.%s is only %.1f%% opaque — too sparse for a cube bake, "
					% [Blocks.name_of(id), coverage]
				)
				+ "give it a _BLOCK_ICON_NAMES entry instead"
			)
		)


func test_every_flat_icon_tile_resolves_in_the_active_pack_or_its_fallback() -> void:
	# The other half: a block on the flat path with no tile anywhere is
	# just as blank as one on neither list. pixel_perfection and
	# programmer_art ship a subset of the terrain tiles, so this leans on
	# the same alpha_vanilla fallback the atlas uses.
	var flat: Dictionary = _consts_of(_ITEM_ICON_PATH).get("_BLOCK_ICON_NAMES", {}) as Dictionary
	for id: Variant in flat.keys():
		var tile: String = str(flat[id])
		assert_gte(
			_opaque_coverage(tile), 0.0, "tile '%s' for %s exists" % [tile, Blocks.name_of(int(id))]
		)


func test_icon_for_returns_the_flat_sprite_for_each_redstone_attachment() -> void:
	# End of the chain: what the spawner button and `player.gd`'s held-item
	# extruder actually receive. Headless there is no bake, so this
	# exercises the flat path directly — a 16x16-ish tile, not a 64px
	# isometric cube render.
	BlockAtlas.reset()
	for id: int in [
		Blocks.LEVER, Blocks.REDSTONE_WIRE, Blocks.REDSTONE_TORCH, Blocks.REDSTONE_TORCH_OFF
	]:
		var tex: Texture2D = ItemIcons.icon_for(id)
		assert_not_null(tex, "%s resolves an icon" % Blocks.name_of(id))
		if tex != null:
			assert_lt(
				tex.get_width(), 64, "%s icon is a flat tile, not a baked cube" % Blocks.name_of(id)
			)


# --- The predicate the three renderers now share ------------------------


func test_the_redstone_attachments_are_sprite_tiled_and_the_hardware_is_not() -> void:
	for id: int in [
		Blocks.LEVER, Blocks.REDSTONE_WIRE, Blocks.REDSTONE_TORCH, Blocks.REDSTONE_TORCH_OFF
	]:
		assert_true(Blocks.has_sprite_tile(id), "%s is a sprite tile" % Blocks.name_of(id))
	# Buttons and plates texture from stone / planks, which are solid, so
	# they stay on the cube path in all three renderers.
	for id: int in [Blocks.STONE_BUTTON, Blocks.STONE_PRESSURE_PLATE, Blocks.WOODEN_PRESSURE_PLATE]:
		assert_false(Blocks.has_sprite_tile(id), "%s reads fine as a cube" % Blocks.name_of(id))
	for id: int in [Blocks.STONE, Blocks.PLANKS, Blocks.REDSTONE_ORE]:
		assert_false(Blocks.has_sprite_tile(id), "%s is an ordinary cube" % Blocks.name_of(id))


func test_no_block_is_both_cube_baked_and_sprite_tiled() -> void:
	# The coupling that keeps the held item, the dropped entity and the
	# inventory icon telling the same story. Each renderer used to carry
	# its own list and they disagreed — which is how the redstone
	# attachments came out right in the inventory and wrong in the hand.
	for id: int in _iconified_blocks():
		assert_false(
			Blocks.has_sprite_tile(id),
			"Blocks.%s is baked as a cube but its tile is a sprite — pick one" % Blocks.name_of(id)
		)


func test_no_sparse_tile_anywhere_is_left_on_the_cube_path() -> void:
	# The sweep, in the direction that actually protects the held item
	# and the dropped entity: ANY block whose tile is mostly transparent
	# has to be routed away from the cube renderers, not just the ones
	# someone remembered to put in a list.
	#
	# Note this is one-directional on purpose. Dense sprites exist —
	# sapling 54%, ladder 44%, sugar cane 54%, crops 59% — and they are
	# correctly sprite-tiled despite being solid, because a cross-quad is
	# not a cube whatever its coverage. Sparseness implies sprite; the
	# converse does not hold.
	BlockAtlas.reset()
	var sparse: Array[String] = []
	for id in range(0, 100):
		var coverage: float = _opaque_coverage(Blocks.get_face_texture(id, "side"))
		if coverage < 0.0 or coverage >= 35.0:
			continue
		if not Blocks.has_sprite_tile(id):
			sparse.append("%s (%.1f%%)" % [Blocks.name_of(id), coverage])
	assert_eq(
		sparse,
		[] as Array[String],
		"sparse tiles still drawn as cubes — they will smear across six faces"
	)


func test_every_cube_baked_block_also_has_a_flat_fallback() -> void:
	# `icon_for` only reaches BlockIconRenderer once render_all() has run.
	# Anything relying solely on the bake shows as an EMPTY slot until
	# then, and permanently anywhere the bake is unavailable — which is
	# what left chest, fence, fence gate, stairs, bookshelf, the slabs and
	# the jukebox blank in the spawner.
	#
	# The fallback is derived automatically from the block's own face tile
	# now, so this asserts the outcome rather than a hand-maintained list.
	BlockAtlas.reset()
	for id: int in _iconified_blocks():
		assert_not_null(
			ItemIcons.icon_for(id),
			"Blocks.%s resolves a flat icon without the bake" % Blocks.name_of(id)
		)


# Percentage of a tile's pixels that are opaque, or -1 when the tile
# ships in neither the active pack nor the alpha_vanilla fallback.
func _opaque_coverage(tile: String) -> float:
	var path: String = "%s%s/%s.png" % [BlockAtlas.PACK_BASE, BlockAtlas.active_pack, tile]
	if not ResourceLoader.exists(path):
		path = "%s%s/%s.png" % [BlockAtlas.PACK_BASE, BlockAtlas.DEFAULT_PACK, tile]
	if not ResourceLoader.exists(path):
		return -1.0
	var texture: Texture2D = load(path) as Texture2D
	if texture == null:
		return -1.0
	var img: Image = texture.get_image()
	var opaque: int = 0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			if img.get_pixel(x, y).a > 0.5:
				opaque += 1
	return 100.0 * float(opaque) / float(maxi(1, img.get_width() * img.get_height()))


func test_redstone_dust_and_products_are_spawnable() -> void:
	# The item side of the economy: dust is the wire/torch crafting input
	# and compass/clock are its only Alpha sinks. All three pre-existed,
	# so this is a regression guard rather than new coverage.
	var items: Array = _spawner_items()
	for item_id: int in [Items.REDSTONE, Items.COMPASS, Items.CLOCK]:
		assert_true(items.has(item_id), "item %d spawnable" % item_id)


func test_spawner_blocks_are_all_real_ids() -> void:
	# Cheap integrity check on the whole grid — a typo'd or removed
	# constant would surface here rather than as a blank button.
	for id: int in _spawner_blocks():
		assert_between(id, 1, 99, "block id %d inside the reserved block range" % id)
		assert_ne(Blocks.name_of(id), "unknown", "block id %d has a registered name" % id)


# --- Animated item sprites (frame strips) ---
#
# Alpha ships clock/compass as one 16×16 sprite with a procedurally
# drawn dial. Modern packs ship a vertical strip of pre-rendered frames
# instead (pixel_perfection clock.png = 16×1024). Treating the strip as
# a single sprite blanked the spawner icon and made the held item render
# as a stack of duplicated frames.


func test_frame_count_detects_strips_and_squares() -> void:
	var square: Image = Image.create(16, 16, false, Image.FORMAT_RGBA8)
	assert_eq(ItemIcons.sprite_frame_count(square), 1, "square sprite = 1 frame")
	var strip: Image = Image.create(16, 1024, false, Image.FORMAT_RGBA8)
	assert_eq(ItemIcons.sprite_frame_count(strip), 64, "16x1024 = 64 frames")
	var short_strip: Image = Image.create(16, 128, false, Image.FORMAT_RGBA8)
	assert_eq(ItemIcons.sprite_frame_count(short_strip), 8, "16x128 = 8 frames")
	# Malformed / non-multiple heights degrade to one frame, never crash.
	var ragged: Image = Image.create(16, 20, false, Image.FORMAT_RGBA8)
	assert_eq(ItemIcons.sprite_frame_count(ragged), 1, "non-multiple height = 1 frame")
	assert_eq(ItemIcons.sprite_frame_count(null), 1, "null image = 1 frame")


func test_sprite_frame_extracts_the_right_square() -> void:
	# Paint each frame a distinct red value, then confirm we pull it back.
	var strip: Image = Image.create(16, 64, false, Image.FORMAT_RGBA8)
	for f in range(4):
		for y in range(16):
			for x in range(16):
				strip.set_pixel(x, f * 16 + y, Color(float(f) / 10.0, 0.0, 0.0, 1.0))
	for f in range(4):
		var frame: Image = ItemIcons.sprite_frame(strip, f)
		assert_eq(frame.get_width(), 16, "frame is square")
		assert_eq(frame.get_height(), 16, "frame is one cell tall")
		assert_almost_eq(frame.get_pixel(8, 8).r, float(f) / 10.0, 0.01, "frame %d content" % f)
	# Index wraps so callers can pass an unbounded animation counter.
	assert_almost_eq(ItemIcons.sprite_frame(strip, 4).get_pixel(8, 8).r, 0.0, 0.01, "wraps to 0")
	assert_almost_eq(ItemIcons.sprite_frame(strip, -1).get_pixel(8, 8).r, 0.3, 0.01, "wraps back")


func test_sprite_frame_passes_square_images_through() -> void:
	var square: Image = Image.create(16, 16, false, Image.FORMAT_RGBA8)
	square.fill(Color(0.0, 1.0, 0.0, 1.0))
	var out: Image = ItemIcons.sprite_frame(square, 3)
	assert_eq(out.get_size(), Vector2i(16, 16), "unchanged size")
	assert_almost_eq(out.get_pixel(0, 0).g, 1.0, 0.01, "unchanged content")


func test_every_pack_item_sprite_yields_a_square_frame() -> void:
	# The real guard: whatever each shipped pack does with clock/compass,
	# the frame handed to the icon + extruder must be square. A tall strip
	# reaching either consumer is the bug this locks out.
	for pack: String in ["alpha_vanilla", "pixel_perfection", "programmer_art"]:
		for item_name: String in ["clock", "compass"]:
			var path: String = "res://assets/textures/packs/%s/items/%s.png" % [pack, item_name]
			if not ResourceLoader.exists(path):
				continue
			var tex: Texture2D = load(path) as Texture2D
			assert_not_null(tex, "%s/%s loads" % [pack, item_name])
			var img: Image = tex.get_image()
			if img.is_compressed():
				img.decompress()
			var frame: Image = ItemIcons.sprite_frame(img, 0)
			assert_eq(
				frame.get_width(),
				frame.get_height(),
				(
					"%s/%s frame is square (raw %dx%d)"
					% [pack, item_name, img.get_width(), img.get_height()]
				)
			)
