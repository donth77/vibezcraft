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


func test_every_redstone_block_has_a_baked_icon() -> void:
	var iconified: Array = _iconified_blocks()
	for id: int in _redstone_ids():
		assert_true(
			iconified.has(id),
			(
				"Blocks.%s (id %d) missing from _ICONIFIED_BLOCKS — renders blank"
				% [Blocks.name_of(id), id]
			)
		)


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
