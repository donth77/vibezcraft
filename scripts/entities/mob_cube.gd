class_name MobCube
extends RefCounted

# Mesh cache. Keyed by (physical_size, tex_size, tex_origin, cube_px,
# mirror_x). Mob _ready() is called per-spawn and rebuilds 5-7 cubes
# per mob; without caching, each spawn allocates 5-7 fresh ArrayMeshes
# (4 PackedArrays + index buffer each) which dominates per-mob spawn
# cost. Cached meshes are shared across all instances of the same
# species — vanilla `dc.java` does the same (one ModelQuadruped per
# species, transforms diff between mobs).
static var _mesh_cache: Dictionary = {}

# Vanilla cube-unfold UV mapping for the per-mob sprite sheets in
# `assets/textures/mob/` (extracted from `/mob/pig.png`, `/mob/cow.png`,
# etc.). Mirrors Minecraft's `ka.java` cube renderer in dc.java
# (ModelQuadruped) — each cube part is a 6-face box whose UVs are laid
# out as:
#
#       +--------+--------+
#       |  TOP   | BOTTOM |
#       +--------+--------+
#       | RIGHT  | FRONT  | BACK  | LEFT |
#       +--------+--------+-------+------+
#
# in a contiguous region of the texture sheet. The caller supplies the
# physical box size (in meters), the sheet dimensions, the top-left
# corner of the cube's region in pixel coords, and the cube's pixel
# dimensions on the sheet. The output is an ArrayMesh that an
# MeshInstance3D can render with a StandardMaterial3D whose albedo is
# the mob's texture.
#
# Vanilla layout reference for the pig (pig.png 64×32):
#   head a: tex_origin (0, 0),  cube_px (8, 8, 8)
#   body c: tex_origin (16, 16), cube_px (8, 12, 4)  ← wide × tall × shallow
#   leg d/e: tex_origin (40, 16), cube_px (4, 12, 4)  (e is x-mirrored)
#   leg f/g: tex_origin (0, 16),  cube_px (4, 12, 4)  (g is x-mirrored)


# Build a 24-vert (4 verts per face × 6 faces) textured-cube mesh.
# `physical_size` is the box's world-space extent (the mesh sits
# centered on Y axis at origin; offset the MeshInstance3D for placement).
# `tex_size` is the full sheet dimensions (64×32 for pig).
# `tex_origin` is the top-left pixel of this cube's region on the
# sheet (per `ka.java`'s constructor (textureOffsetX, textureOffsetY)).
# `cube_px` is the cube's size in PIXEL units on the sheet
# (vanilla's `ka.a(x, y, z, width, height, depth, scale)`). Note that
# width = X-axis face = front/back face width, height = Y-axis = front/back
# face height, depth = Z-axis = side face width.
# `mirror_x` swaps the X-axis UV direction (vanilla's `ka.g = true`
# flag — used for the left-side limbs so they share the right-side
# UVs without authoring separate texture regions).
static func build_textured_cube(
	physical_size: Vector3,
	tex_size: Vector2i,
	tex_origin: Vector2i,
	cube_px: Vector3i,
	mirror_x: bool = false
) -> ArrayMesh:
	var key: String = (
		"%.4f,%.4f,%.4f|%d,%d|%d,%d|%d,%d,%d|%d"
		% [
			physical_size.x,
			physical_size.y,
			physical_size.z,
			tex_size.x,
			tex_size.y,
			tex_origin.x,
			tex_origin.y,
			cube_px.x,
			cube_px.y,
			cube_px.z,
			1 if mirror_x else 0,
		]
	)
	var cached: ArrayMesh = _mesh_cache.get(key) as ArrayMesh
	if cached != null:
		return cached
	var sx: float = physical_size.x * 0.5
	var sy: float = physical_size.y * 0.5
	var sz: float = physical_size.z * 0.5
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Pixel-to-UV scale
	var inv_tw: float = 1.0 / float(tex_size.x)
	var inv_th: float = 1.0 / float(tex_size.y)
	var ox: float = float(tex_origin.x)
	var oy: float = float(tex_origin.y)
	var pw: float = float(cube_px.x)  # X-axis face width
	var ph: float = float(cube_px.y)  # Y-axis face height
	var pd: float = float(cube_px.z)  # Z-axis face depth
	# Per-face UV rects matching vanilla `ka.java::a` unfold positions
	# (lines 68-73). The unfold is:
	#
	#       +--------+--------+
	#       | -Y bot | +Y top |
	#       +----+---+--+-----+
	#       | -X | -Z |+X| +Z |  ← side row: LEFT, BACK, RIGHT, FRONT
	#       | pd | pw |pd|  pw|     widths alternate pd, pw, pd, pw
	#       +----+----+--+----+
	#
	# Vanilla pixel positions (l=tex_origin.x, m=tex_origin.y):
	#   +Y top:   x [l+pd+pw, l+pd+pw+pw],  y [m, m+pd]
	#   -Y bot:   x [l+pd,    l+pd+pw],     y [m, m+pd]
	#   -X left:  x [l,       l+pd],        y [m+pd, m+pd+ph]
	#   -Z back:  x [l+pd,    l+pd+pw],     y [m+pd, m+pd+ph]
	#   +X right: x [l+pd+pw, l+pd+pw+pd],  y [m+pd, m+pd+ph]
	#   +Z front: x [l+pd+pw+pd, l+pd+pw+pd+pw], y [m+pd, m+pd+ph]
	#
	# Earlier mapping had RIGHT|FRONT|BACK|LEFT in the side row with
	# widths pd|pw|pw|pd, which doesn't exist in vanilla. saddle.png
	# (asymmetric) made the bug visible — main seat artwork landed on
	# the pig's LEFT instead of the TOP after the body's -PI/2 X rot.
	#
	# IMPORTANT: vanilla naming of "TOP" (-Y face) vs "BOTTOM" (+Y face)
	# follows MC's +Y-DOWN model convention — vanilla -Y faces UP in
	# the model and ends up on world UP after the renderer's Y-flip
	# (`glScalef(1, -1, 1)`). Since OUR Godot rendering has NO Y-flip,
	# we apply vanilla's -Y-face UV to our cube's +Y face (world UP)
	# and vice versa. Without this swap, the chicken head's top face
	# rendered the vanilla "+Y" UV which is transparent for the chin —
	# leaving a hole in the top of the head.
	var uv_top: Vector4 = Vector4(ox + pd, oy, pw, pd)
	var uv_bot: Vector4 = Vector4(ox + pd + pw, oy, pw, pd)
	var uv_left: Vector4 = Vector4(ox, oy + pd, pd, ph)
	var uv_back: Vector4 = Vector4(ox + pd, oy + pd, pw, ph)
	var uv_right: Vector4 = Vector4(ox + pd + pw, oy + pd, pd, ph)
	var uv_front: Vector4 = Vector4(ox + pd + pw + pd, oy + pd, pw, ph)
	# Build the 6 faces.
	_add_face(
		verts,
		norms,
		uvs,
		indices,
		Vector3(-sx, sy, sz),
		Vector3(sx, sy, sz),
		Vector3(sx, sy, -sz),
		Vector3(-sx, sy, -sz),
		Vector3.UP,
		uv_top,
		inv_tw,
		inv_th,
		mirror_x,
	)
	_add_face(
		verts,
		norms,
		uvs,
		indices,
		Vector3(-sx, -sy, -sz),
		Vector3(sx, -sy, -sz),
		Vector3(sx, -sy, sz),
		Vector3(-sx, -sy, sz),
		Vector3.DOWN,
		uv_bot,
		inv_tw,
		inv_th,
		mirror_x,
	)
	_add_face(
		verts,
		norms,
		uvs,
		indices,
		Vector3(-sx, -sy, sz),
		Vector3(sx, -sy, sz),
		Vector3(sx, sy, sz),
		Vector3(-sx, sy, sz),
		Vector3(0, 0, 1),
		uv_front,
		inv_tw,
		inv_th,
		mirror_x,
	)
	_add_face(
		verts,
		norms,
		uvs,
		indices,
		Vector3(sx, -sy, sz),
		Vector3(sx, -sy, -sz),
		Vector3(sx, sy, -sz),
		Vector3(sx, sy, sz),
		Vector3.RIGHT,
		uv_right,
		inv_tw,
		inv_th,
		mirror_x,
	)
	_add_face(
		verts,
		norms,
		uvs,
		indices,
		Vector3(sx, -sy, -sz),
		Vector3(-sx, -sy, -sz),
		Vector3(-sx, sy, -sz),
		Vector3(sx, sy, -sz),
		Vector3(0, 0, -1),
		uv_back,
		inv_tw,
		inv_th,
		mirror_x,
	)
	_add_face(
		verts,
		norms,
		uvs,
		indices,
		Vector3(-sx, -sy, -sz),
		Vector3(-sx, -sy, sz),
		Vector3(-sx, sy, sz),
		Vector3(-sx, sy, -sz),
		Vector3.LEFT,
		uv_left,
		inv_tw,
		inv_th,
		mirror_x,
	)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_cache[key] = mesh
	return mesh


# Append one face's 4 verts + 6 indices + UVs (converted from pixel-rect
# to UV-rect using the inverse texture dimensions). `mirror_x` swaps the
# U direction so vanilla's left-side limb mirroring works without a
# separate texture region.
static func _add_face(
	verts: PackedVector3Array,
	norms: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
	normal: Vector3,
	uv_rect_px: Vector4,
	inv_tw: float,
	inv_th: float,
	mirror_x: bool
) -> void:
	var base: int = verts.size()
	verts.append(v0)
	verts.append(v1)
	verts.append(v2)
	verts.append(v3)
	norms.append(normal)
	norms.append(normal)
	norms.append(normal)
	norms.append(normal)
	# Pixel rect (ox, oy, w, h) → UV corners with a HALF-TEXEL INSET on
	# every side. Mob atlases (pig.png, cow.png etc.) pack cube unfolds
	# adjacent to one another with NO gutters — sampling exactly at a
	# face boundary with nearest filtering can pick up the neighboring
	# face's pixel, producing dark/wrong-colored streaks at the cube's
	# edges. Pushing UVs inward by 0.5 texel guarantees the sampler
	# stays inside the intended pixel block at every cube edge.
	var u0: float = (uv_rect_px.x + 0.5) * inv_tw
	var v0_u: float = (uv_rect_px.y + 0.5) * inv_th
	var u1: float = (uv_rect_px.x + uv_rect_px.z - 0.5) * inv_tw
	var v1_u: float = (uv_rect_px.y + uv_rect_px.w - 0.5) * inv_th
	if mirror_x:
		var tmp: float = u0
		u0 = u1
		u1 = tmp
	# Map verts to corners. v0=BL, v1=BR, v2=TR, v3=TL of the texture rect.
	uvs.append(Vector2(u0, v1_u))
	uvs.append(Vector2(u1, v1_u))
	uvs.append(Vector2(u1, v0_u))
	uvs.append(Vector2(u0, v0_u))
	# REVERSED winding (v0, v2, v1) instead of natural (v0, v1, v2). The
	# face verts above are placed CCW when viewed from outside, but
	# Godot 4's `cull_back` keeps CW-from-outside as the front face
	# (opposite of OpenGL convention — see scripts/world/mesher.gd:470).
	# Without this reversal the entire cube renders inside-out: every
	# face is back-face-culled from outside, so the viewer sees through
	# to the FAR INSIDE of the opposite face — which makes the head
	# texture appear "on the wrong side" and the body sides look
	# missing entirely.
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 1)
	indices.append(base)
	indices.append(base + 3)
	indices.append(base + 2)
