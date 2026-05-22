class_name ChestNode
extends Node3D

# A single visible chest entity. Renders the body + lid as two meshes
# parented under this node so the lid can pivot independently. Mesh
# geometry is generated at runtime from the atlas UVs of chest_top,
# chest_side, and chest_front — no binary asset shipped.
#
# Vanilla reference: cz.java::TileEntityChestRenderer. Box dims:
#   body  : x=1..15, y=0..10, z=1..15  (14×10×14, 1/16 inset on XZ)
#   lid   : x=1..15, y=9..14, z=1..15  (14×5×14)
#   latch : x=7..9,  y=8..10, z=15..16 (2×2×1) — small block on the lid
#
# The lid pivots around the BACK edge of the chest (z=15) at y=9. When
# closed, lid local rotation.x = 0; fully open is +pi/2 (lid swings up
# and back) to match cz.java's `(open * pi * 0.5)` formula.
#
# Texture UVs sample partial subrects of the chest_top/side/front tiles
# so the body and lid each show only the slab of the original 16-pixel-
# tall texture they correspond to.

const _BODY_HEIGHT: float = 10.0 / 16.0
const _LID_HEIGHT: float = 5.0 / 16.0
const _BODY_INSET: float = 1.0 / 16.0
const _LID_PIVOT_Y: float = 9.0 / 16.0  # back-top edge of body (cz.java)
# Vanilla cz.java::TileEntityChestRenderer line ~57 rotates the lid by
# `-(angle + 1) * 0.5 * pi` where `angle` ramps 0→1. The negation cancels
# Java/Godot's opposite Y-up handedness so in our coords positive X-axis
# rotation swings the lid UP and BACK (towards +Z, the chest's back). A
# negative angle would swing the lid DOWN into the body — which read as
# "the chest is shrinking" before this fix.
const _OPEN_ANGLE: float = PI / 2.0
const _ANIM_TIME: float = 0.18

var _body: MeshInstance3D
var _lid_pivot: Node3D
var _lid: MeshInstance3D
var _open_tween: Tween
var _is_open: bool = false


func _ready() -> void:
	_body = MeshInstance3D.new()
	_body.mesh = _build_body_mesh()
	_body.material_override = BlockAtlas.material()
	add_child(_body)
	_lid_pivot = Node3D.new()
	# Position the pivot at the back-top edge of the body. Mesh coords
	# are centered on XZ (see _build_body_mesh), so the pivot sits at
	# x=0 (centered) and z=+(0.5-inset) (back face of the chest, towards
	# +Z which is "back" in vanilla — front faces -Z).
	_lid_pivot.position = Vector3(0.0, _LID_PIVOT_Y, 0.5 - _BODY_INSET)
	add_child(_lid_pivot)
	_lid = MeshInstance3D.new()
	_lid.mesh = _build_lid_mesh()
	_lid.material_override = BlockAtlas.material()
	_lid_pivot.add_child(_lid)


# Vanilla c.java places the chest's "front" face based on the player's
# yaw at placement time. meta 0..3 maps to -Z / -X / +Z / +X (chest opens
# toward that direction). We rotate the whole node so the body/lid front
# faces the correct world direction.
func set_facing(meta: int) -> void:
	# Godot rotation.y is CCW from above (right-hand rule on +Y axis): the
	# node's local -Z (forward) maps to world (-sin yaw, 0, -cos yaw). So
	# yaw +π/2 sends the front to -X, yaw -π/2 sends it to +X. The previous
	# version had meta 1 and meta 3 swapped, which made E/W chest placements
	# read as "front faces away from the player."
	var yaw: float = 0.0
	match meta & 3:
		0:
			yaw = 0.0  # front faces -Z
		1:
			yaw = PI / 2.0  # front faces -X
		2:
			yaw = PI  # front faces +Z
		3:
			yaw = -PI / 2.0  # front faces +X
	rotation.y = yaw


# Drive the lid open/close animation. No-op if already in the target
# state — lets the caller call this idempotently from interaction +
# screen-close hooks.
func set_open(want_open: bool) -> void:
	if want_open == _is_open:
		return
	_is_open = want_open
	if _open_tween != null and _open_tween.is_valid():
		_open_tween.kill()
	_open_tween = create_tween()
	var target: float = _OPEN_ANGLE if want_open else 0.0
	_open_tween.tween_property(_lid_pivot, "rotation:x", target, _ANIM_TIME).set_trans(
		Tween.TRANS_CUBIC
	)


# --- Mesh builders ---


# Build the static body box. ArrayMesh with 6 axis-aligned faces, each
# UV-mapped into the chest_top / chest_side / chest_front tiles. Face
# winding matches the chunk mesher's `[base, base+2, base+1, base, base+3,
# base+2]` reversed-index pattern so cull_back keeps outward sides.
func _build_body_mesh() -> ArrayMesh:
	# Mesh coords are CENTERED on XZ (-0.5..0.5 across the cell) so that
	# set_facing's Y-rotation pivots around the chest's centerline. Y is
	# uncentered (0 at cell floor) since facing only spins on Y.
	var half := 0.5 - _BODY_INSET
	var ymin := 0.0
	var ymax := _BODY_HEIGHT
	# Side strip = bottom 10/16 of the chest_side / chest_front tiles.
	var side_v_top := 10.0 / 16.0
	return _build_box_mesh(
		-half,
		half,
		ymin,
		ymax,
		-half,
		half,
		"chest_top",
		"chest_top",
		"chest_side",
		"chest_front",
		Vector2(0.0, 1.0 - side_v_top),
		Vector2(1.0, 1.0)
	)


# Build the lid box. Local origin sits at the lid_pivot point; mesh
# vertices are emitted RELATIVE to that point so rotation pivots the
# back-top edge.
#
# Lid in cell-local coords spans y=9/16..14/16 and the same XZ as the
# body. After translating so the pivot point becomes the local origin,
# the lid mesh spans:
#   x=(inset - 0.5)..(1.0 - inset - 0.5)   (centered on x=0.5)
#   y=0..(LID_HEIGHT)                       (lid_pivot_y up by 5/16)
#   z=(inset - 1.0 + inset)..(0)            (back edge at z=0)
func _build_lid_mesh() -> ArrayMesh:
	# Lid mesh is local to _lid_pivot (which sits at the back-top edge
	# of the chest). After translating so the pivot point is at local
	# origin, the lid box spans:
	#   x: ±(0.5 - inset)   (centered, full width)
	#   y: 0..LID_HEIGHT    (lid grows upward from the pivot)
	#   z: -(1.0 - 2*inset)..0   (extends forward from the back edge)
	var half := 0.5 - _BODY_INSET
	# Side strip = top 5/16 (the chest_side/front tile rows above the body).
	var side_v_top := 5.0 / 16.0
	return _build_box_mesh(
		-half,
		half,
		0.0,
		_LID_HEIGHT,
		-(1.0 - 2.0 * _BODY_INSET),
		0.0,
		"chest_top",
		"chest_top",
		"chest_side",
		"chest_front",
		Vector2(0.0, 0.0),
		Vector2(1.0, side_v_top)
	)


# Generic UV-aware box builder. Six faces, each routed to a named atlas
# tile. `side_uv_top`/`side_uv_bot` is a sub-rect of the side/front tile
# (so the body and lid each pick the right horizontal strip). Top and
# bottom faces always use the full tile (chest is uniform top-down).
# gdlint: disable=function-arguments-number
func _build_box_mesh(
	x0: float,
	x1: float,
	y0: float,
	y1: float,
	z0: float,
	z1: float,
	top_name: String,
	bottom_name: String,
	side_name: String,
	front_name: String,
	side_uv_min: Vector2,
	side_uv_max: Vector2
) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Vanilla chest "front" faces -Z (player sees latch when looking
	# south). meta 0 = -Z is the canonical orientation; ChestNode rotates
	# the whole node for other facings.
	_emit_face(
		verts,
		norms,
		uvs,
		indices,
		[Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0)],
		Vector3.UP,
		_full_tile_uvs(top_name)
	)
	_emit_face(
		verts,
		norms,
		uvs,
		indices,
		[Vector3(x0, y0, z1), Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1)],
		Vector3.DOWN,
		_full_tile_uvs(bottom_name)
	)
	_emit_face(
		verts,
		norms,
		uvs,
		indices,
		[Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y0, z0)],
		Vector3.FORWARD,  # -Z = vanilla "front"
		_subrect_uvs(front_name, side_uv_min, side_uv_max)
	)
	_emit_face(
		verts,
		norms,
		uvs,
		indices,
		[Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3(x0, y0, z1)],
		Vector3.BACK,  # +Z = back of chest, plain side texture
		_subrect_uvs(side_name, side_uv_min, side_uv_max)
	)
	_emit_face(
		verts,
		norms,
		uvs,
		indices,
		[Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y0, z1)],
		Vector3.RIGHT,
		_subrect_uvs(side_name, side_uv_min, side_uv_max)
	)
	_emit_face(
		verts,
		norms,
		uvs,
		indices,
		[Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3(x0, y0, z0)],
		Vector3.LEFT,
		_subrect_uvs(side_name, side_uv_min, side_uv_max)
	)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _emit_face(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
	face_verts: Array,
	normal: Vector3,
	face_uvs: Array
) -> void:
	var base := verts.size()
	for v: Vector3 in face_verts:
		verts.append(v)
		norms.append(normal)
	for u: Vector2 in face_uvs:
		uvs.append(u)
	# Reversed-winding to match the chunk mesher's cull_back convention.
	indices.append_array([base, base + 2, base + 1, base, base + 3, base + 2] as PackedInt32Array)


# Full-tile UVs (matching the chunk mesher's V-flipped convention so the
# top of the texture is on top of the face).
func _full_tile_uvs(name: String) -> Array:
	var rect: Rect2 = BlockAtlas.uv_rect(name)
	var x0 := rect.position.x
	var x1 := rect.position.x + rect.size.x
	var y0 := rect.position.y
	var y1 := rect.position.y + rect.size.y
	# Order matches face_verts order in _build_box_mesh
	# ([(x0,y1), (x0,y0), (x1,y0), (x1,y1)] when traversing CCW from outside).
	return [Vector2(x0, y1), Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1)]


# Subrect UVs — `uv_min` / `uv_max` are unit-tile coords (0..1, 0=top of
# tile, 1=bottom) that we map into the atlas-space rect for this tile.
# Lets body + lid each show their respective horizontal strip of the
# chest_side / chest_front 16-tall texture.
func _subrect_uvs(name: String, uv_min: Vector2, uv_max: Vector2) -> Array:
	var rect: Rect2 = BlockAtlas.uv_rect(name)
	var x0 := rect.position.x + uv_min.x * rect.size.x
	var x1 := rect.position.x + uv_max.x * rect.size.x
	var y0 := rect.position.y + uv_min.y * rect.size.y
	var y1 := rect.position.y + uv_max.y * rect.size.y
	return [Vector2(x0, y1), Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1)]
