class_name BlockIconRenderer
extends Node

# Pre-bakes 3D isometric block icons once at startup using an offscreen
# SubViewport. Vanilla MC renders inventory blocks live in 3D — same fixed
# camera angle (30° pitch + 45° yaw) showing top + two side faces. We do
# the same once and cache the resulting Texture2Ds so the inventory UI
# can use them as flat sprites at zero per-frame cost.
#
# Usage: call setup_renderer(parent_node) then render_all() once after
# BlockAtlas has loaded. Then ItemIcons.icon_for(block_id) returns the
# pre-baked texture.

const ICON_PX: int = 64  # output texture size — chunky enough to look crisp at 54px slot scale

# IMPORTANT: this list is BLOCKS ONLY. Non-block items (sticks, tools,
# ingots) must NOT be added here — vanilla MC renders those as flat 2D
# sprites, not 3D cubes. Items go through the placeholder/sprite path in
# ItemIcons.icon_for instead.
const _ICONIFIED_BLOCKS: Array = [
	Blocks.STONE,
	Blocks.COBBLESTONE,
	Blocks.DIRT,
	Blocks.GRASS,
	Blocks.LOG,
	Blocks.PLANKS,
	Blocks.LEAVES,
	Blocks.SAND,
	Blocks.BEDROCK,
	Blocks.BRICK,
	Blocks.OBSIDIAN,
	Blocks.COAL_ORE,
	Blocks.IRON_ORE,
	Blocks.GOLD_ORE,
	Blocks.DIAMOND_ORE,
	Blocks.CRAFTING_TABLE,
	Blocks.FARMLAND,
	Blocks.GRAVEL,
	Blocks.FURNACE,
	Blocks.GLASS,
	# CHEST renders as an external ChestNode entity in-world, but for the
	# inventory icon we still bake it as a regular cube using its
	# chest_top / chest_side textures via Blocks.get_face_texture. The
	# 3D iso bake reads as a recognizable wooden chest cube — close
	# enough to vanilla, no separate icon asset needed.
	Blocks.CHEST,
	# Fence renders as a post + neighbor-aware rails in-world, but for the
	# inventory icon we bake it as a planks cube (fence shares the planks
	# texture per nq.aZ.bg=4). Same precedent as CHEST: simple cube icon.
	Blocks.FENCE,
	Blocks.WOOD_STAIRS,
	Blocks.COBBLESTONE_STAIRS,
	# SAPLING is intentionally NOT iconified — it renders as a cross-quad
	# in-world (not a cube), so the iso-cube bake reads as an oversized
	# blocky sprite. Falls through to ItemIcons' flat sprite path which
	# loads packs/{active}/sapling.png directly, matching how vanilla MC
	# inventory shows non-cube items.
	# Biome blocks added 2026-05-11. Ice + snow_block render as full
	# cubes so iso bakes cleanly. Cactus is approximated as a cube
	# (vanilla 14/16 width gaps are visual only — bake as full cube
	# for the icon, matches vanilla inventory representation).
	# Sugar cane + snow_layer are NOT iconified — non-cube in-world
	# (cross-quad, thin slab) so iso bake would look wrong; fall
	# through to flat sprite path.
	Blocks.ICE,
	Blocks.SNOW_BLOCK,
	Blocks.CACTUS,
	# TNT renders as a full cube with 3 distinct faces (top fuse plate, side
	# lettering, plain red bottom). Iso bake shows the top + 2 sides cleanly.
	Blocks.TNT,
	# Pumpkin + Jack O'Lantern — both full cubes with distinct top vs side
	# textures (carved face + plain panel + stem-up top). Iso bake gives a
	# recognizable inventory icon.
	Blocks.PUMPKIN,
	Blocks.JACK_O_LANTERN,
	# Bookshelf [BETA 1.3 exception] — full cube with planks top/bottom
	# and bookshelf_side on the 4 sides. Iso bake reads as wooden cube
	# with a book strip, recognizable in inventory.
	Blocks.BOOKSHELF,
	# Classic-era solid blocks — same uniform-face story as STONE etc.
	Blocks.SPONGE,
	Blocks.IRON_BLOCK,
	Blocks.GOLD_BLOCK,
	Blocks.DIAMOND_BLOCK,
	# Wool family — 16 ids; each gets its own iso bake. Cheap one-time
	# cost at boot.
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
	# Clay block — gray-blue full cube.
	Blocks.CLAY,
	# Double-slab is a regular cube, bakes cleanly with the slab textures.
	# HALF_SLAB has a custom half-height mesh in BlockMesh._build_slab so
	# the bake reads as half-height with the top face visible, matching
	# vanilla's inventory icon (the old fall-through to the flat side
	# sprite showed a full-square cobblestone-looking face — wrong).
	Blocks.DOUBLE_SLAB,
	Blocks.HALF_SLAB,
	# Wood + cobblestone slab variants (Beta 1.3) — same half-height
	# mesh as the stone slab, planks / cobblestone textures from
	# blocks.gd::get_face_texture.
	Blocks.WOOD_HALF_SLAB,
	Blocks.WOOD_DOUBLE_SLAB,
	Blocks.COBBLESTONE_HALF_SLAB,
	Blocks.COBBLESTONE_DOUBLE_SLAB,
	# Fence gate — non-cube (2 posts + 2 rails); the bake uses the
	# dedicated closed-state mesh in BlockMesh._build_fence_gate so the
	# inventory icon shows the recognizable gate silhouette rather than
	# a flat planks square.
	Blocks.FENCE_GATE,
	# Jukebox — full cube with the inlay-groove top + noteblock-style
	# sides. Needs to be iconified so the inventory slot shows the
	# proper 3-quarter view instead of a "missing icon" fallback.
	Blocks.JUKEBOX,
]

static var _viewport: SubViewport
static var _camera: Camera3D
static var _holder: Node3D
static var _cache: Dictionary = {}  # block_id → Texture2D


# Builds the offscreen viewport. Must be called once with a Node already in
# the scene tree (BlockIconRenderer adds the viewport as its child).
static func setup_renderer(parent: Node) -> void:
	if _viewport != null:
		return
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(ICON_PX, ICON_PX)
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_DISABLED  # crisper pixel-art look
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(_viewport)
	_viewport.world_3d = World3D.new()

	# Orthographic camera at vanilla MC's iconic block angle: yaw 45°, pitch
	# 30° down. The combination shows the +Y top face plus two side faces in
	# equal proportion, all axis-aligned in screen space.
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 1.45  # tighter zoom = bigger cube; ~1 unit cube fills most of frame
	_camera.near = 0.05
	_camera.far = 10.0
	_viewport.add_child(_camera)
	# Position the camera at vanilla MC's iconic angle: yaw 45° + pitch 30°
	# down. Distance 4 (placeholder for ortho — projection is parallel so
	# distance only matters for near/far culling). look_at handles the
	# basis math so the cube stays centered in the viewport.
	_camera.position = Vector3(2.449, 2.0, 2.449)  # 4 * (sin45*cos30, sin30, cos45*cos30)
	_camera.look_at(Vector3.ZERO, Vector3.UP)

	# Sun-style directional light + ambient fill — matches vanilla's bright
	# top + slightly darker sides shading. We don't enable shadows.
	var sun := DirectionalLight3D.new()
	sun.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-45.0)), Vector3.ZERO)
	sun.light_energy = 1.2
	_viewport.add_child(sun)

	_holder = Node3D.new()
	_viewport.add_child(_holder)


# Bakes one texture per block in _ICONIFIED_BLOCKS. Yields between blocks so
# the renderer has a frame to draw + capture each one. Call from a Node's
# _ready (so we can `await get_tree().process_frame`).
static func render_all(host: Node) -> void:
	if _viewport == null:
		push_error("[BlockIconRenderer] setup_renderer must be called first")
		return
	for block_id: int in _ICONIFIED_BLOCKS:
		await _render_one(host, block_id)
	# Bakes are captured as static ImageTextures; the live viewport has no
	# more work to do, so disable per-frame rendering to save GPU cycles.
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


static func get_icon(block_id: int) -> Texture2D:
	return _cache.get(block_id, null) as Texture2D


static func _render_one(host: Node, block_id: int) -> void:
	# Swap in the new block mesh.
	for child: Node in _holder.get_children():
		_holder.remove_child(child)
		child.queue_free()
	var mi := MeshInstance3D.new()
	mi.mesh = BlockMesh.get_cube_mesh(block_id, 1.0)
	# CHEST + FURNACE store their "front" texture on the -Z face (vanilla
	# convention — front faces the player on placement). The icon camera
	# sits in the +X+Y+Z octant and sees the +Z face, so without a flip
	# the inventory icon shows the BACK of the chest / furnace instead
	# of the latch / firebox. Rotate 180° around Y so the front face
	# swings around to the camera-facing side.
	if block_id == Blocks.CHEST or block_id == Blocks.FURNACE:
		mi.rotation.y = PI
	_holder.add_child(mi)
	# Wait two frames: one for the new mesh to register, one for the viewport
	# to render it. RenderingServer.frame_post_draw fires after the GPU has
	# finished, so the texture data is valid by then.
	await host.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = _viewport.get_texture().get_image()
	if img == null:
		push_error("[BlockIconRenderer] failed to capture image for block %d" % block_id)
		return
	_cache[block_id] = ImageTexture.create_from_image(img)
