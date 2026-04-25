class_name ChunkView
extends RefCounted

# Helpers for anything tied to the player's render-distance view: the
# ring-order chunk load iterator and the Alpha-faithful linear fog setup.
# Factored out of ChunkManager purely to keep that file under the linter's
# 1000-line cap; no behavioral change.


# Returns the `(2r+1)^2 - 1` ring offsets around (0,0), sorted by squared
# distance ascending so callers process the nearest cells first. Used by
# ChunkManager._spawn_initial_chunks and _update_chunk_set — at FAR this
# is the difference between "player-ring loads in ~1 s" and "player-ring
# waits behind the worker queue for ~18 s". Mirrors vanilla's
# ChunkProviderGenerate spiral ordering around the active chunk.
static func spiral_offsets(r: int) -> Array:
	var pairs: Array = []
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			if dx == 0 and dz == 0:
				continue
			pairs.append([dx * dx + dz * dz, Vector2i(dx, dz)])
	pairs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out: Array = []
	for p: Array in pairs:
		out.append(p[1])
	return out


# Enable physics trimesh only on chunks within `radius` (Chebyshev) of
# `center` — chunk_node caches the face soup so toggling is just a
# set_faces() call, no worker dispatch. Keeps ~1-2 MB per chunk of
# trimesh + BVH out of physics memory at FAR. Chunks are the loaded
# ChunkNodes dict from ChunkManager.
static func update_collision_activity(chunks: Dictionary, center: Vector2i, radius: int) -> void:
	for coord: Vector2i in chunks:
		var active: bool = absi(coord.x - center.x) <= radius and absi(coord.y - center.y) <= radius
		chunks[coord].call("set_collision_active", active)


# Alpha 1.2.6 kb.java:502-504 uses linear fog over `[0.25*i, i]` where
# `i = 256 >> viewDistance`. OpenGL GL_LINEAR looks gentle because fragment
# alpha ramps linearly; Godot 4's DEPTH fog with `depth_curve=1.0` at those
# exact parameters reads visibly more aggressive (half the view clouded).
# We keep vanilla's _end_ (the horizon must fade to sky color at the ring
# edge) and vanilla's _linear shape_ (curve=1.0), but start fog at half
# the view distance so the near-and-mid ground stays clear — matches
# Alpha's perceptual feel at any render distance.
static func apply_alpha_fog(tree: SceneTree, render_distance_chunks: int) -> void:
	var view_dist_blocks: float = float(render_distance_chunks * Chunk.SIZE_X)
	var env_node: WorldEnvironment = tree.get_root().find_child("WorldEnvironment", true, false)
	if env_node == null or env_node.environment == null:
		return
	var env: Environment = env_node.environment
	env.fog_enabled = true
	env.fog_depth_begin = view_dist_blocks * 0.5
	env.fog_depth_end = view_dist_blocks
	env.fog_depth_curve = 1.0
