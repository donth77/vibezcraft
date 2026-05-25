class_name Painting
extends StaticBody3D

# Beta-era EntityPainting port. Wall-mounted decoration with 26
# canonical Kristoffer Zetterstrand art variants packed into a single
# 256×256 atlas (`painting_atlas.png`, vendored from MC 1.6.4 — the
# atlas didn't change between Alpha-era and Beta 1.8).
#
# Variant table coords are from vanilla `EnumArt.java`: name, width
# (blocks), height (blocks), atlas X, atlas Y (top-left pixel of the
# 16-px-per-block cell). Sizes: 1×1 (7 variants), 2×1 (5), 1×2 (2),
# 2×2 (6), 4×2 (1), 4×3 (2), 4×4 (3) — 26 total.
#
# Mounting model. The painting is parented to a `Main` child node and
# positioned at the center of its rectangular wall extent, oriented so
# its visible front (+local Z) faces AWAY from the support wall (= in
# the direction of the face normal the player clicked on). Visual mesh
# is a `QuadMesh` sized in blocks; collision is a thin BoxShape3D so
# the player can LMB it to break.
#
# `support_pos` is the cell BEHIND the painting (the wall block the
# painting hangs on). If that cell becomes AIR, the painting breaks
# and drops a `Items.PAINTING` to the player.

# Each variant: [name, width_blocks, height_blocks, atlas_x_px, atlas_y_px]
const VARIANTS: Array = [
	["kebab", 1, 1, 0, 0],
	["aztec", 1, 1, 16, 0],
	["alban", 1, 1, 32, 0],
	["aztec2", 1, 1, 48, 0],
	["bomb", 1, 1, 64, 0],
	["plant", 1, 1, 80, 0],
	["wasteland", 1, 1, 96, 0],
	["pool", 2, 1, 0, 32],
	["courbet", 2, 1, 32, 32],
	["sea", 2, 1, 64, 32],
	["sunset", 2, 1, 96, 32],
	["creebet", 2, 1, 128, 32],
	["wanderer", 1, 2, 0, 64],
	["graham", 1, 2, 16, 64],
	["match", 2, 2, 0, 128],
	["bust", 2, 2, 32, 128],
	["stage", 2, 2, 64, 128],
	["void", 2, 2, 96, 128],
	["skull_and_roses", 2, 2, 128, 128],
	["wither", 2, 2, 160, 128],
	["fighters", 4, 2, 0, 96],
	["skeleton", 4, 3, 192, 64],
	["donkey_kong", 4, 3, 192, 112],
	["pointer", 4, 4, 0, 192],
	["pigscene", 4, 4, 64, 192],
	["burning_skull", 4, 4, 128, 192],
]

const ATLAS_SIZE_PX: int = 256
# Fallback path — the active-pack lookup in `_load_atlas` tries the
# current pack first. Currently only alpha_vanilla ships a painting
# atlas; other packs fall back to this canonical Mojang asset.
const _ATLAS_DIR: String = "res://assets/textures/blocks/packs"
const _ATLAS_FALLBACK_PATH: String = _ATLAS_DIR + "/alpha_vanilla/painting_atlas.png"
# Vanilla EntityPainting hangs 1/16 block in front of its support
# wall — matches the `BackWallOffsetPx = 1` (see vanilla
# `EntityHanging.updateFacingWithBoundingBox()`).
const _SURFACE_OFFSET: float = 1.0 / 16.0
# Render thickness — 1/16 block. Front face shows the variant art,
# sides + back are unshaded planks-brown so the painting reads as a
# real object from any angle (vanilla draws a wooden frame; we
# approximate with a single solid color).
const _THICKNESS: float = 1.0 / 16.0

# Set by the spawner BEFORE add_child. `variant` indexes VARIANTS;
# `facing` is one of 0=south(+Z) / 1=west(-X) / 2=north(-Z) / 3=east(+X)
# — same BlockDirectional convention as fence-gate / chest.
@export var variant: int = 0
@export var facing: int = 0
# World coord of the wall block the painting hangs on. Tracked so we
# can self-break if the wall is removed. The painting's own visual
# position is OFFSET from this in the facing direction.
@export var support_pos: Vector3i = Vector3i.ZERO
# World coord of the painting's RECTANGLE center cell — used so save /
# load can re-spawn the same painting at the same position. Computed
# at spawn time from `support_pos` + offset + size.
@export var center_pos: Vector3 = Vector3.ZERO

var _chunk_manager: Node = null
var _wall_check_accum: float = 0.0


# Called by the spawner before adding the painting to the tree.
func setup(p_variant: int, p_facing: int, p_support_pos: Vector3i) -> void:
	variant = p_variant
	facing = p_facing
	support_pos = p_support_pos


func _ready() -> void:
	_chunk_manager = get_tree().root.get_node_or_null("Main/ChunkManager")
	_build_mesh()
	_build_collision()
	# Selection-only collision layer (== 2 across the project — same as
	# `plant_faces` / sapling cross-quads). The player's CharacterBody3D
	# moves on layer 1 only, so they walk THROUGH the painting (vanilla
	# `EntityHanging.isCollidable() = false` — paintings never block
	# entities). The cursor raycast still hits because interaction.gd
	# uses mask 0b11 for both block-cube + selection-only colliders.
	collision_layer = 2
	collision_mask = 0
	# Center-pos is set by the spawner via global_position; cache it
	# so save/load can persist exactly the same spawn coords.
	center_pos = global_position


func _process(delta: float) -> void:
	# Cheap wall-support poll. Every 0.5 s, check the support cell —
	# if it became AIR while the chunk is LOADED, drop the painting.
	# Skipped when the support chunk is unloaded: `get_world_block`
	# returns AIR for any unloaded cell, so without this gate every
	# painting would self-destruct the moment the player walked far
	# enough away to unload its chunk.
	_wall_check_accum += delta
	if _wall_check_accum < 0.5:
		return
	_wall_check_accum = 0.0
	if _chunk_manager == null:
		return
	var chunk_x: int = int(floor(float(support_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(support_pos.z) / float(Chunk.SIZE_Z)))
	if _chunk_manager.get_chunk_at_coord(Vector2i(chunk_x, chunk_z)) == null:
		return
	var id: int = _chunk_manager.get_world_block(support_pos)
	if id == Blocks.AIR:
		break_painting()


# Build the visible mesh — a single rectangle facing +local Z with
# UV mapped to the variant's atlas cell. Width × height in blocks
# matches the variant's size; the local origin sits at the painting's
# CENTER so rotating the StaticBody3D 0/90/180/270° around Y aligns
# the front with the chosen facing direction.
func _build_mesh() -> void:
	var v: Array = VARIANTS[variant]
	var w_blocks: int = v[1]
	var h_blocks: int = v[2]
	var atlas_x: int = v[3]
	var atlas_y: int = v[4]
	var w: float = float(w_blocks)
	var h: float = float(h_blocks)
	# Front face: textured quad. Local +Z is the visible front; back
	# trails by `_THICKNESS` along -Z.
	var front_mi := MeshInstance3D.new()
	var front_quad := QuadMesh.new()
	front_quad.size = Vector2(w, h)
	front_mi.mesh = front_quad
	# Slight forward push so the front sits flush with the cell face
	# the painting was placed against (avoids z-fight with the wall).
	front_mi.position = Vector3(0.0, 0.0, _THICKNESS * 0.5)
	# UV rect into the canonical atlas — w_blocks × h_blocks cells of
	# 16 px each.
	var u0: float = float(atlas_x) / float(ATLAS_SIZE_PX)
	var v0: float = float(atlas_y) / float(ATLAS_SIZE_PX)
	var u1: float = float(atlas_x + w_blocks * 16) / float(ATLAS_SIZE_PX)
	var v1: float = float(atlas_y + h_blocks * 16) / float(ATLAS_SIZE_PX)
	front_mi.material_override = _make_atlas_material(u0, v0, u1, v1)
	add_child(front_mi)
	# Back + sides as a slim BoxMesh in the planks-brown wood tone so
	# the painting reads as a 3D object from the side (vanilla has a
	# proper frame mesh; this is the readable approximation).
	var frame_mi := MeshInstance3D.new()
	var frame_box := BoxMesh.new()
	frame_box.size = Vector3(w, h, _THICKNESS)
	frame_mi.mesh = frame_box
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = Color(0.45, 0.32, 0.22)
	frame_mat.roughness = 1.0
	frame_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	frame_mi.material_override = frame_mat
	add_child(frame_mi)


# Pack-aware atlas lookup. Tries the active texture pack's directory
# first (e.g. `packs/programmer_art/painting_atlas.png`); falls back
# to the canonical alpha_vanilla atlas if the active pack doesn't
# ship its own. Mirrors the same per-pack-first / fallback-default
# pattern that ItemIcons._load_item_sprite uses for item textures.
func _load_atlas() -> Texture2D:
	var pack_path: String = "%s/%s/painting_atlas.png" % [_ATLAS_DIR, BlockAtlas.active_pack]
	if ResourceLoader.exists(pack_path):
		return load(pack_path) as Texture2D
	return load(_ATLAS_FALLBACK_PATH) as Texture2D


# Build a UV-cropped material that samples a sub-rect of the canonical
# atlas. Uses TEXTURE_FILTER_NEAREST so the 16-px-per-block art stays
# crisp at any view distance — vanilla MC's painting render is also
# nearest-filtered (no mipmaps for blocky pixel art).
func _make_atlas_material(u0: float, v0: float, u1: float, v1: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var tex: Texture2D = _load_atlas()
	if tex == null:
		mat.albedo_color = Color(0.5, 0.5, 0.5)
		return mat
	# Wrap the texture in an AtlasTexture so the QuadMesh's default
	# (0..1) UVs sample the variant's sub-rect instead of the whole
	# atlas. Pixel coords because AtlasTexture takes a Rect2 in pixels.
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2(
		u0 * ATLAS_SIZE_PX, v0 * ATLAS_SIZE_PX, (u1 - u0) * ATLAS_SIZE_PX, (v1 - v0) * ATLAS_SIZE_PX
	)
	mat.albedo_texture = atlas
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


# Build the LMB-pick collision — a thin box matching the painting's
# rectangle, sized in blocks. Sits centered on the painting node.
func _build_collision() -> void:
	var v: Array = VARIANTS[variant]
	var w_blocks: int = v[1]
	var h_blocks: int = v[2]
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(float(w_blocks), float(h_blocks), _THICKNESS)
	col.shape = box
	add_child(col)


# Drop the painting item and despawn. Called by both the LMB attack
# path and the wall-removed self-break tick. Spawns the DroppedItem
# directly (chunk_manager._spawn_dropped_item is keyed on Vector3i
# cell coords; we want a precise Vector3 drop at the painting center).
# Plays the planks-break SFX — vanilla EntityPainting uses the wood
# material break sound the same way breaking a plank does. Emits
# canvas-fragment particles using the painting's own atlas region so
# the chunks visually match the variant that was broken (vanilla MC's
# `EntityHanging` spawns variant-textured particles via the same path).
func break_painting() -> void:
	SFX.play_break(Blocks.PLANKS)
	var main: Node = get_tree().root.get_node_or_null("Main")
	if main != null:
		_spawn_break_particles(main)
		var item := DroppedItem.new()
		main.add_child(item)
		item.global_position = global_position
		item.setup(Items.PAINTING)
	queue_free()


# Vanilla-faithful canvas fragments. Spawns a one-shot CPUParticles3D
# whose draw mesh shares the painting's atlas-sampled material (so the
# fragments are the same colors as the variant), emits from a box that
# wraps the painting's visible rectangle, and lets gravity pull the
# chunks down. The particle node parents under Main, auto-disposes
# itself when emission finishes.
func _spawn_break_particles(parent: Node) -> void:
	var v: Array = VARIANTS[variant]
	var w_blocks: int = v[1]
	var h_blocks: int = v[2]
	var particles := CPUParticles3D.new()
	parent.add_child(particles)
	particles.global_position = global_position
	# Particle count scales with painting area — 1×1 emits ~12 fragments,
	# a 4×4 emits ~30. Vanilla scales the count similarly.
	particles.amount = clampi(8 + w_blocks * h_blocks * 2, 12, 32)
	particles.lifetime = 1.0
	particles.one_shot = true
	particles.explosiveness = 0.85
	# Emission box matches the painting's local rectangle (X = blocks
	# wide along the rotated local X axis, Y = blocks tall, Z thin so
	# fragments spawn at the canvas plane).
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	particles.emission_box_extents = Vector3(
		float(w_blocks) * 0.5, float(h_blocks) * 0.5, _THICKNESS * 0.5
	)
	# Inherit the painting's rotation so the emission box lines up with
	# the wall — fragments spawn ON the canvas plane, not in the wall.
	particles.transform.basis = global_transform.basis
	# Outward spray + gravity. Initial velocity has some randomness so
	# fragments scatter; gravity pulls them down to settle on the floor.
	particles.direction = Vector3(0.0, 0.5, 1.0).normalized()
	particles.spread = 60.0
	particles.initial_velocity_min = 0.8
	particles.initial_velocity_max = 1.8
	particles.gravity = Vector3(0.0, -8.0, 0.0)
	particles.scale_amount_min = 0.6
	particles.scale_amount_max = 1.0
	# Tiny quad mesh — each fragment is ~1/16 block square, matching
	# the pixel-art scale of the painting itself.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.0625, 0.0625)
	# Reuse the painting's atlas-cropped material so the fragments
	# show colors from the SAME variant the player broke. Sharing the
	# StandardMaterial3D is fine here — particles only read it.
	var atlas_x: int = v[3]
	var atlas_y: int = v[4]
	var u0: float = float(atlas_x) / float(ATLAS_SIZE_PX)
	var v0: float = float(atlas_y) / float(ATLAS_SIZE_PX)
	var u1: float = float(atlas_x + w_blocks * 16) / float(ATLAS_SIZE_PX)
	var v1: float = float(atlas_y + h_blocks * 16) / float(ATLAS_SIZE_PX)
	quad.material = _make_atlas_material(u0, v0, u1, v1)
	particles.mesh = quad
	particles.emitting = true
	# Auto-cleanup — wait one full lifetime + buffer, then queue_free.
	# A SceneTreeTimer is cheaper than wiring up a `finished` signal
	# for one-shot emitters.
	particles.get_tree().create_timer(particles.lifetime + 0.5).timeout.connect(
		particles.queue_free
	)


# Public API for interaction.gd — called when LMB lands on the
# painting (raycast collider is this body or a descendant).
func take_damage(_amount: int, _knockback_dir: Vector3 = Vector3.ZERO) -> void:
	break_painting()


# Convenience: rotate the painting around Y so its front faces the
# given facing direction. Called by the spawner after `setup`.
#   facing 0 = +Z (south) → no rotation
#   facing 1 = -X (west)  → +90° around Y
#   facing 2 = -Z (north) → 180°
#   facing 3 = +X (east)  → -90° (= +270°)
func apply_facing() -> void:
	var y_deg: float = 0.0
	match facing:
		0:
			y_deg = 0.0
		1:
			y_deg = 90.0
		2:
			y_deg = 180.0
		_:
			y_deg = -90.0
	rotation = Vector3(0.0, deg_to_rad(y_deg), 0.0)


# Returns the variant index that fits the given (width, height) in
# blocks at the click point. Picks randomly from valid candidates so
# repeated placements don't all show the same art. Used by the
# placement code in interaction.gd.
static func pick_variant_for_size(max_width: int, max_height: int) -> int:
	var candidates: Array = []
	for i in range(VARIANTS.size()):
		var v: Array = VARIANTS[i]
		if v[1] <= max_width and v[2] <= max_height:
			candidates.append(i)
	if candidates.is_empty():
		return -1
	return candidates[randi() % candidates.size()]


# Variant size accessor — used by placement to compute the cell extent
# the painting will occupy.
static func variant_size(variant_idx: int) -> Vector2i:
	if variant_idx < 0 or variant_idx >= VARIANTS.size():
		return Vector2i(1, 1)
	return Vector2i(VARIANTS[variant_idx][1], VARIANTS[variant_idx][2])


# Persistence payload. `variant` + `facing` + `support_pos` are the
# minimum to re-build the mesh / collision; `pos` saves the world
# position too so EntitySave doesn't have to re-derive the off-axis
# center-offset math from the placement code. Read back by
# EntitySave._spawn_one via setup() + global_position assignment.
func to_save_dict() -> Dictionary:
	return {
		"variant": variant,
		"facing": facing,
		"support_pos": support_pos,
		"pos": global_position,
	}
