class_name BlockAtlas
extends RefCounted

# Packs the per-block textures from assets/textures/blocks/packs/{active}/
# into a single atlas. Cell size is auto-detected from the first texture, so
# 16×16 / 32×32 / any-square packs all work without code changes. Active
# pack is configured in the Game autoload.

const GRID_SIZE := 8  # 8x8 = 64 slots; plenty of room for new blocks
const PACK_BASE := "res://assets/textures/blocks/packs/"
const DEFAULT_PACK := "pixellab"

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
}

static var active_pack: String = DEFAULT_PACK
static var _texture: ImageTexture
static var _uv_rects: Dictionary = {}
# Precomputed face-UV lookup indexed by (block_id * 3 + face_kind).
# Populated in build(); read-only afterwards so workers (mesher) can read
# lock-free. Saves a string match + dict lookup per face.
static var _block_face_uvs: Array[Rect2] = []
static var _material: ShaderMaterial
static var _overlay_material: ShaderMaterial  # depth-test-disabled variant for FP held items
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
		_uv_rects[tex_name] = Rect2(col * slot_uv, row * slot_uv, slot_uv, slot_uv)
	_texture = ImageTexture.create_from_image(atlas_image)
	_build_block_face_uvs()


# Walks every possible block id × {top, bottom, side} and resolves it
# through Blocks.get_face_texture → _uv_rects. Runs once at build(); the
# resulting array is read-only so mesher workers can index it directly.
static func _build_block_face_uvs() -> void:
	_block_face_uvs.resize(_MAX_BLOCK_IDS * 3)
	var face_names: Array[String] = ["top", "bottom", "side"]
	var default_rect := Rect2(0, 0, 0, 0)
	for bid in range(_MAX_BLOCK_IDS):
		for fk in range(3):
			var tex_name: String = Blocks.get_face_texture(bid, face_names[fk])
			_block_face_uvs[bid * 3 + fk] = _uv_rects.get(tex_name, default_rect)


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


# Single ShaderMaterial shared across every chunk. Called from the main thread
# only (chunk_node._ready); materials are RefCounted so sharing is safe.
static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = load("res://shaders/chunk.gdshader") as Shader
		_material.set_shader_parameter("atlas_texture", texture())
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


static func reset() -> void:
	_texture = null
	_uv_rects = {}
	_block_face_uvs = []
	_material = null
	_overlay_material = null
