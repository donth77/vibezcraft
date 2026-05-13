class_name BlockAtlas
extends RefCounted

# Packs the per-block textures from assets/textures/blocks/packs/{active}/
# into a single atlas. Cell size is auto-detected from the first texture, so
# 16×16 / 32×32 / any-square packs all work without code changes. Active
# pack is configured in the Game autoload.

const GRID_SIZE := 8  # 8x8 = 64 slots; plenty of room for new blocks
const PACK_BASE := "res://assets/textures/blocks/packs/"
const DEFAULT_PACK := "alpha_vanilla"

# Face kinds for the precomputed UV lookup. Mapped from mesher's face_idx
# (0-5) via Mesher._FACE_KIND so the fast indexed path and the old string
# path resolve to the same atlas rect.
const FACE_TOP: int = 0
const FACE_BOTTOM: int = 1
const FACE_SIDE: int = 2

const _MAX_BLOCK_IDS: int = 256

const _LAYOUT := {
	"stone": 0,
	"cobblestone": 1,
	"dirt": 2,
	"grass_top": 3,
	"grass_side": 4,
	"bedrock": 5,
	"sand": 6,
	"log_top": 7,
	"log_side": 8,
	"planks": 9,
	"leaves": 10,
	"coal_ore": 11,
	"iron_ore": 12,
	"gold_ore": 13,
	"diamond_ore": 14,
	"crafting_table_top": 15,
	"crafting_table_side": 16,
	"crafting_table_front": 17,
	"farmland": 18,
	"gravel": 19,
	"furnace_top": 20,
	"furnace_front": 21,
	"furnace_front_lit": 22,
	"glass": 23,
	"sapling": 24,
	"lava_still": 25,
	"lava_flowing": 26,
	"torch": 27,
	"fire": 28,
	# Append-only — slot indices are persisted via mesher UV bakes / native
	# extension marshalling, so don't renumber existing entries. Both have
	# matching PNGs in every pack (extracted by extract_alpha_pack.py for
	# alpha_vanilla; hand-authored for the others) — without these LAYOUT
	# entries `Blocks.get_face_texture` returns the right name but
	# `BlockAtlas._uv_rects.get(name)` falls through to Rect2(0,0,0,0),
	# baking grey-pixel-only UVs into the cube mesh and the icon renderer.
	"brick": 29,
	"obsidian": 30,
	# Chest tiles. Vanilla c.java references `bg = 26` for chest_top,
	# `bg + 1 = 27` for chest_front, but those terrain.png positions are
	# vanilla-internal — our atlas indices are independent. Slot order
	# below is append-only same as brick/obsidian above.
	"chest_top": 31,
	"chest_side": 32,
	"chest_front": 33,
	"door_wood_lower": 34,
	"door_wood_upper": 35,
	"door_iron_lower": 36,
	"door_iron_upper": 37,
	"ladder": 38,
	"tnt_top": 39,
	"tnt_side": 40,
	"tnt_bottom": 41,
	# Decoration slice 1 — flowers + mushrooms. Cross-quad blocks like
	# sapling. Vanilla terrain.png positions: flower_red (12,0),
	# flower_yellow (13,0), mushroom_red (12,1), mushroom_brown (13,1).
	"flower_red": 42,
	"flower_yellow": 43,
	"mushroom_brown": 44,
	"mushroom_red": 45,
	# Sugar cane (vanilla "reeds"). Cross-quad like flowers. Vanilla
	# terrain.png cell (9, 4).
	"sugar_cane": 46,
	# Ice (vanilla terrain.png cell (3, 4)). Semi-transparent cube.
	"ice": 47,
	# Snow block (vanilla terrain.png cell (2, 4)). Same texture as
	# snow layer; opaque white.
	"snow": 48,
	# Cactus — three faces (top, side, bottom) at vanilla terrain.png
	# cells (5..7, 4).
	"cactus_top": 49,
	"cactus_side": 50,
	"cactus_bottom": 51,
}

static var active_pack: String = DEFAULT_PACK
static var _texture: ImageTexture
static var _uv_rects: Dictionary = {}
# Precomputed face-UV lookup indexed by (block_id * 3 + face_kind).
# Populated in build(); read-only afterwards so workers (mesher) can read
# lock-free. Saves a string match + dict lookup per face.
static var _block_face_uvs: Array[Rect2] = []
# Flat float view of _block_face_uvs for native-extension marshalling.
# 4 floats per entry: (x, y, w, h). Read-only after build().
static var _uv_table_flat: PackedFloat32Array = PackedFloat32Array()
static var _material: ShaderMaterial
static var _overlay_material: ShaderMaterial  # depth-test-disabled variant for FP held items
# Entity variant — same chunk shader + atlas, but a SEPARATE ShaderMaterial
# instance so debug uniforms (the F8 heatmap's `debug_view`) pushed onto the
# main `_material` don't bleed onto dropped items / falling blocks / the
# held block on the third-person model. Without this, every entity mesh
# rendered green in heatmap mode because its mesh ships with no per-vertex
# COLOR and Godot defaults missing COLOR to white = sky_light=15.
static var _entity_material: ShaderMaterial
# Translucent, scrolling-noise water material shared by every chunk's water
# mesh. Owns no state — the shader is self-contained (see shaders/water.gdshader).
static var _water_material: ShaderMaterial
static var _lava_material: ShaderMaterial
static var _slot_size: int = 32  # auto-detected on build()


static func build() -> void:
	# Auto-detect slot size from the first available texture in this pack
	var first_tex: Texture2D = _load_first_texture()
	if first_tex != null:
		_slot_size = first_tex.get_width()
	print("[BlockAtlas] pack=%s slot_size=%d" % [active_pack, _slot_size])

	var atlas_image := Image.create(
		_slot_size * GRID_SIZE, _slot_size * GRID_SIZE, false, Image.FORMAT_RGBA8
	)
	var slot_uv: float = 1.0 / float(GRID_SIZE)
	# Half-texel UV inset to kill atlas bleed at tile borders. Without
	# this, a face whose UV vertex lands exactly on the slot boundary
	# (e.g. 0.125 = end of slot 0) can sample the FIRST texel of the
	# adjacent slot — visible as the thin white seams between blocks.
	# Vanilla MC's terrain.png leaves a 1-px gutter; we shrink the rect
	# in UV space instead so we don't have to repack textures, and we
	# still get pixel-perfect Alpha look (sub-pixel inset is invisible).
	# Texel size in UV = 1 / (slot_size × GRID_SIZE); half-texel inset
	# is half that on each side.
	var inset: float = 0.5 / float(_slot_size * GRID_SIZE)
	for tex_name: String in _LAYOUT:
		var idx: int = _LAYOUT[tex_name]
		var col: int = idx % GRID_SIZE
		var row: int = idx / GRID_SIZE
		var path := "%s%s/%s.png" % [PACK_BASE, active_pack, tex_name]
		var tex := load(path) as Texture2D
		if tex == null:
			push_error("BlockAtlas: failed to load %s" % path)
			continue
		var img := tex.get_image()
		if img == null:
			push_error("BlockAtlas: %s has no image data" % path)
			continue
		if img.is_compressed():
			img.decompress()
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		if img.get_width() != _slot_size or img.get_height() != _slot_size:
			# Resize mismatched textures to slot size with nearest-neighbor
			img.resize(_slot_size, _slot_size, Image.INTERPOLATE_NEAREST)
		atlas_image.blit_rect(
			img, Rect2i(0, 0, _slot_size, _slot_size), Vector2i(col * _slot_size, row * _slot_size)
		)
		_uv_rects[tex_name] = Rect2(
			col * slot_uv + inset,
			row * slot_uv + inset,
			slot_uv - 2.0 * inset,
			slot_uv - 2.0 * inset,
		)
	_texture = ImageTexture.create_from_image(atlas_image)
	_build_block_face_uvs()


# Walks every possible block id × {top, bottom, side} and resolves it
# through Blocks.get_face_texture → _uv_rects. Runs once at build(); the
# resulting array is read-only so mesher workers can index it directly.
static func _build_block_face_uvs() -> void:
	_block_face_uvs.resize(_MAX_BLOCK_IDS * 3)
	_uv_table_flat.resize(_MAX_BLOCK_IDS * 3 * 4)
	var face_names: Array[String] = ["top", "bottom", "side"]
	var default_rect := Rect2(0, 0, 0, 0)
	for bid in range(_MAX_BLOCK_IDS):
		for fk in range(3):
			var tex_name: String = Blocks.get_face_texture(bid, face_names[fk])
			var rect: Rect2 = _uv_rects.get(tex_name, default_rect)
			_block_face_uvs[bid * 3 + fk] = rect
			var base: int = (bid * 3 + fk) * 4
			_uv_table_flat[base + 0] = rect.position.x
			_uv_table_flat[base + 1] = rect.position.y
			_uv_table_flat[base + 2] = rect.size.x
			_uv_table_flat[base + 3] = rect.size.y


# Tries each layout texture in turn and returns the first one that loads,
# so we can detect slot size before the main atlas-build loop.
static func _load_first_texture() -> Texture2D:
	for tex_name: String in _LAYOUT:
		var path := "%s%s/%s.png" % [PACK_BASE, active_pack, tex_name]
		var tex := load(path) as Texture2D
		if tex != null:
			return tex
	return null


static func texture() -> ImageTexture:
	if _texture == null:
		build()
	return _texture


static func uv_rect(tex_name: String) -> Rect2:
	if _uv_rects.is_empty():
		build()
	return _uv_rects.get(tex_name, Rect2(0, 0, 0, 0))


# Fast per-face UV lookup for the mesher inner loop. Returns the same
# Rect2 as uv_rect(Blocks.get_face_texture(block_id, face_name)), but as
# a single array index — no string match, no dict lookup.
static func uv_rect_for(block_id: int, face_kind: int) -> Rect2:
	if _block_face_uvs.is_empty():
		build()
	return _block_face_uvs[block_id * 3 + face_kind]


# Returns a STANDALONE Image of just this block's face tile — copied out
# of the packed atlas with no AtlasTexture region indirection. Used by
# BlockFx to bake per-block-id particle textures without the half-texel
# inset / region remapping that was causing neighboring atlas tiles to
# bleed into break particles. Returns null if the block has no texture
# for the given face (AIR, unknown ids).
#
# Resolves directly via _LAYOUT to avoid round-tripping through the UV
# rect (which carries a half-texel inset for shader bleed prevention,
# producing fragile float-to-int math when extracting pixel bounds).
static func tile_image(block_id: int, face_kind: int) -> Image:
	if _texture == null:
		build()
	if _texture == null:
		return null
	var face_names: Array[String] = ["top", "bottom", "side"]
	var tex_name: String = Blocks.get_face_texture(block_id, face_names[face_kind])
	if not _LAYOUT.has(tex_name):
		return null
	var idx: int = _LAYOUT[tex_name]
	var col: int = idx % GRID_SIZE
	var row: int = idx / GRID_SIZE
	var atlas_img: Image = _texture.get_image()
	if atlas_img == null:
		return null
	return atlas_img.get_region(Rect2i(col * _slot_size, row * _slot_size, _slot_size, _slot_size))


# Flat float array (4 floats per Rect2) for native-extension consumers.
# Indexed the same way as uv_rect_for: (block_id * 3 + face_kind) * 4.
static func uv_table_flat() -> PackedFloat32Array:
	if _uv_table_flat.is_empty():
		build()
	return _uv_table_flat


# Single ShaderMaterial shared across every chunk. Called from the main thread
# only (chunk_node._ready); materials are RefCounted so sharing is safe.
static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = load("res://shaders/chunk.gdshader") as Shader
		_material.set_shader_parameter("atlas_texture", texture())
		# Tell the shader where the grass-top atlas slot lives so it can
		# gate per-instance biome tinting (Savanna yellow) to grass faces
		# only. Vec4 = (x, y, w, h) in UV space.
		var grass_rect: Rect2 = uv_rect("grass_top")
		_material.set_shader_parameter(
			"grass_top_uv",
			Vector4(
				grass_rect.position.x, grass_rect.position.y, grass_rect.size.x, grass_rect.size.y
			)
		)
	return _material


# Variant of material() with depth_test_disabled — for first-person held
# items that must always draw on top of world geometry. Same atlas + shading.
static func overlay_material() -> ShaderMaterial:
	if _overlay_material == null:
		_overlay_material = ShaderMaterial.new()
		_overlay_material.shader = load("res://shaders/chunk_overlay.gdshader") as Shader
		_overlay_material.set_shader_parameter("atlas_texture", texture())
		_overlay_material.render_priority = 100
	return _overlay_material


# Variant for ENTITY block meshes — dropped items, falling blocks, the
# third-person held block. Same shader as chunks (same atlas, same Notch
# face shade, same brightness LUT) but a separate material instance so the
# F8 heatmap's `debug_view` uniform set on `_material` doesn't bleed into
# entity meshes (which carry no per-vertex sky_light info and would render
# as a flat heatmap value). Entities always run with `debug_view = 0`
# (its default) regardless of what the terrain heatmap is doing.
static func entity_material() -> ShaderMaterial:
	if _entity_material == null:
		_entity_material = ShaderMaterial.new()
		# gdlint: disable=duplicated-load
		_entity_material.shader = load("res://shaders/chunk.gdshader") as Shader
		_entity_material.set_shader_parameter("atlas_texture", texture())
	return _entity_material


# Shared translucent water ShaderMaterial, used by every chunk's water
# MeshInstance3D. Stateless — the shader animates from TIME so a single
# material works for every chunk without per-instance uniforms.
static func water_material() -> ShaderMaterial:
	if _water_material == null:
		_water_material = ShaderMaterial.new()
		_water_material.shader = load("res://shaders/water.gdshader") as Shader
	return _water_material


# Shared opaque lava ShaderMaterial. Procedural animation like water but
# slower + emissive so it reads as molten. One material instance for all
# chunks' lava meshes — TIME-driven, no per-chunk uniforms.
static func lava_material() -> ShaderMaterial:
	if _lava_material == null:
		_lava_material = ShaderMaterial.new()
		_lava_material.shader = load("res://shaders/lava.gdshader") as Shader
	return _lava_material


static func reset() -> void:
	_texture = null
	_uv_rects = {}
	_block_face_uvs = []
	_uv_table_flat = PackedFloat32Array()
	_material = null
	_overlay_material = null
	_entity_material = null
	_water_material = null
	_lava_material = null
