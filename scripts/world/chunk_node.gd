extends Node3D

# Node3D wrapper around a Chunk: builds and updates the visual mesh +
# collision whenever the underlying Chunk's `dirty` flag is set.
# Block data is supplied externally — set `chunk_data` before adding to
# the tree, and _ready will build the mesh.

var chunk_data: Chunk  # set by ChunkManager pre-add_child
var precomputed_mesh_data: Dictionary  # optional pre-built mesh arrays from worker

var chunk: Chunk

# Off-main-thread re-mesh bookkeeping. When `chunk.dirty` flips we
# dispatch `Mesher.mesh_chunk_fast` to the WorkerThreadPool against a
# snapshot of the chunk's PackedByteArrays, so the main thread no longer
# eats the 100-240 ms p95 mesh cost on every dig. The main thread keeps
# block-write ownership; workers only read their snapshot. If the player
# digs again while a worker is running, `chunk.dirty` gets set again and
# we requeue once the current task lands.
var _remesh_task_id: int = -1
# Single-element Array holding the most-recent worker result. Passed to
# the worker by reference so it can write without touching `self`. Array
# is RefCounted + the worker holds a strong reference, so it survives
# even if the chunk_node is freed mid-worker.
var _remesh_result_holder: Array = []
# Explicit null default + init in _init() rather than `:= Mutex.new()` —
# the inline initializer occasionally runs as null when a ChunkNode is
# instantiated from the .tscn and then its script's worker tasks fire
# before the class-level init has materialized the object. _init() is
# the earliest-guaranteed hook and always fires in a deterministic order.
var _remesh_mutex: Mutex

var _mesh_instance: MeshInstance3D
# Separate MeshInstance3D for the translucent water sub-mesh. Created lazily
# — chunks with no water cells skip both the surface and the node, matching
# vanilla's water-only VBO render pass (RenderBlocks.renderBlockFluids).
var _water_mesh_instance: MeshInstance3D
# Opaque lava sub-mesh — tapered like water but drawn with an emissive
# lava shader. Created lazily same as water; chunks with no lava cells
# skip both the surface + the node.
var _lava_mesh_instance: MeshInstance3D
var _static_body: StaticBody3D
var _collision_shape: CollisionShape3D
# Second static body on collision layer 2 (layer 1 = solid world). Holds
# the cross-quad triangles for non-cube blocks (sapling, future torches /
# levers / buttons) so the player's targeting raycast can hit them, while
# the player's CharacterBody3D — masked to layer 1 by default — passes
# straight through. Mirrors vanilla MC's split between Block.b()
# (collision bbox, null for plants) and Block.e() (selection bbox).
var _plants_body: StaticBody3D
var _plants_shape: CollisionShape3D
# Worker-built collision face soup, cached so ChunkManager can toggle
# physics on/off as the player walks near/far without a remesh. At FAR
# only a small inner ring needs a live ConcavePolygonShape3D — the rest
# keep their ~1-2 MB trimesh BVH unallocated until the player gets close.
# Raw face array is ~1/3 the size of the baked shape + BVH.
var _collision_faces_cache: PackedVector3Array = PackedVector3Array()
# Worker-built ConcavePolygonShape3D, cached so set_collision_active can
# attach/detach without rebuilding the BVH (the dominant cost). Replaces
# the per-toggle `ConcavePolygonShape3D.new() + set_faces` pattern, which
# was rebuilding the BVH on every chunk-boundary crossing's collision
# sweep. Null when the chunk has no opaque cells (empty face soup).
var _collision_shape_cache: ConcavePolygonShape3D = null
var _collision_active: bool = true
# Held completed worker result waiting for a frame where ChunkManager's
# per-frame apply budget has room. Without this latch, multiple chunks
# whose workers finish the same frame all apply on the same frame — a
# 3-mesh GPU upload × N chunks spike (120 → 70 fps range).
var _pending_apply: Dictionary = {}
# Set true by ChunkManager.set_world_block on player-edited chunks. The
# next pending_apply skips the global per-frame apply budget so the edit
# becomes visible within 1-2 frames of the break, even when many other
# chunks are queued for apply behind background relight churn. Without
# this, the player's broken block could hang as a "ghost block" for many
# seconds at FAR render distance with active chunk streaming. Cleared
# automatically on apply.
var _priority_apply: bool = false

# CHEST cells in this chunk get a separate ChestNode entity (see
# scripts/entities/chest_node.gd) for animated lid rendering. The chunk
# mesher skips face emission for CHEST so we don't double-draw. Keyed
# by chunk-local Vector3i; rebuilt every _apply_mesh_data so adds /
# removes track block edits without per-event signals.
var _chest_nodes: Dictionary = {}
# SIGN cells get a SignNode child for the in-world 3D text overlay.
# Keyed by chunk-local Vector3i; rebuilt every _apply_mesh_data so
# breaking / placing signs adds + removes nodes in lockstep with the
# chunk mesh refresh.
var _sign_nodes: Dictionary = {}


func _init() -> void:
	# Fires before _ready, before _process, and before any WorkerThreadPool
	# task could ever be dispatched against this instance — so by the time
	# _remesh_worker or _process touches the mutex, it's guaranteed live.
	_remesh_mutex = Mutex.new()


func _ready() -> void:
	_mesh_instance = MeshInstance3D.new()
	add_child(_mesh_instance)
	_water_mesh_instance = MeshInstance3D.new()
	# Water has no collision body — the player wades through it, and the
	# chunk's main StaticBody3D handles all walkable surfaces. Swim physics
	# will gate on Blocks.is_water(get_world_block) directly.
	add_child(_water_mesh_instance)
	# Lava uses the same "no collision body, physics gates on block id"
	# rule as water. Player damage on contact is handled in player.gd.
	_lava_mesh_instance = MeshInstance3D.new()
	add_child(_lava_mesh_instance)
	_static_body = StaticBody3D.new()
	add_child(_static_body)
	_collision_shape = CollisionShape3D.new()
	_static_body.add_child(_collision_shape)
	_plants_body = StaticBody3D.new()
	# Layer 2 only — no mask, since this body never *moves* and doesn't
	# need to react to anything. Player physics body keeps its default
	# mask=1, so it ignores this body entirely. Interaction.gd's raycast
	# explicitly opts in to layers 1+2.
	_plants_body.collision_layer = 2
	_plants_body.collision_mask = 0
	add_child(_plants_body)
	_plants_shape = CollisionShape3D.new()
	_plants_body.add_child(_plants_shape)
	chunk = chunk_data if chunk_data != null else Chunk.new()
	if not precomputed_mesh_data.is_empty():
		# Defer the first apply through the same throttle the re-mesh path
		# uses. Without this, `add_child()` at materialize time would run
		# the full apply (ArrayMesh upload + ConcavePolygonShape3D.set_faces
		# + BVH build, ~3-8 ms) inline inside the chunk_mgr.materialize
		# probe — that's the single biggest main-thread spike per chunk
		# crossing. Routing through `_pending_apply` lets `_process` drain
		# it next frame within the 1-per-frame `try_consume_apply_budget`
		# limit. Set dirty=false to claim the work — the pending mesh
		# fulfills the initial build, so the re-mesh dispatch loop in
		# `_process` shouldn't kick in concurrently.
		# Side effects:
		#   * Chunk has no mesh + no collision for ≥1 frame after spawn.
		#     Far-edge chunks aren't visible until rendered → no flicker.
		#   * `set_collision_active(true)` early-bails when the faces cache
		#     is empty; `_apply_mesh_data` re-respects `_collision_active`
		#     when the deferred apply lands → collision activates the same
		#     frame as the mesh.
		_pending_apply = precomputed_mesh_data
		precomputed_mesh_data = {}
		chunk.dirty = false
	else:
		# Fallback only — initial spawns go through ChunkManager with a
		# precomputed mesh from the worker pool. Synchronous build here
		# keeps the node usable if anyone constructs it without one
		# (tests, debug tools).
		_apply_mesh_data(Mesher.mesh_chunk_fast(chunk))
		chunk.dirty = false


func _process(_delta: float) -> void:
	# 1) Drain any completed worker re-mesh result onto the scene.
	if _remesh_task_id != -1 and WorkerThreadPool.is_task_completed(_remesh_task_id):
		WorkerThreadPool.wait_for_task_completion(_remesh_task_id)
		_remesh_task_id = -1
		_remesh_mutex.lock()
		var data: Dictionary = {}
		if not _remesh_result_holder.is_empty():
			data = _remesh_result_holder[0]
			_remesh_result_holder[0] = {}
		_remesh_mutex.unlock()
		if not data.is_empty() and not chunk.dirty:
			_pending_apply = data
	# 2) If we're holding a pending apply, try to spend a ChunkManager
	#    apply budget this frame. Priority-apply bypasses the budget for
	#    player-edited chunks so the edit lands in 1-2 frames instead of
	#    waiting behind background relight churn.
	if chunk.dirty and not _pending_apply.is_empty():
		_pending_apply = {}
	if not _pending_apply.is_empty():
		var manager: Node = get_parent()
		var has_budget: bool = _priority_apply
		if not has_budget:
			has_budget = manager == null or not manager.has_method("try_consume_apply_budget")
			if not has_budget:
				has_budget = manager.call("try_consume_apply_budget")
		if has_budget:
			var data: Dictionary = _pending_apply
			_pending_apply = {}
			_priority_apply = false
			_apply_mesh_data(data)
	# 3) If the chunk dirtied (player edit) and no task is in flight,
	#    dispatch a re-mesh off the main thread.
	if chunk.dirty and _remesh_task_id == -1:
		chunk.dirty = false
		_dispatch_remesh()


func _dispatch_remesh() -> void:
	# Snapshot the chunk's mutable state so the worker reads stable data.
	# PackedByteArray.duplicate() is ~µs for 32 KB; a 3× 32 KB snapshot at
	# most a couple hundred microseconds, well inside frame budget.
	var snap := Chunk.new()
	snap.blocks = chunk.blocks.duplicate()
	snap.block_meta = chunk.block_meta.duplicate()
	snap.sky_light = chunk.sky_light.duplicate()
	snap.block_light = chunk.block_light.duplicate()
	snap.max_y = chunk.max_y
	snap.has_non_cube_blocks = chunk.has_non_cube_blocks
	snap.has_water_cells = chunk.has_water_cells
	# Neighbor edge slices — snapshot the 1-block-thick plane facing our
	# chunk from each of the 4 cardinal neighbors. Lets the mesher see
	# across chunk seams and cull shared water faces. Unloaded neighbors
	# leave the slice empty; get_block then returns AIR at that edge
	# (matching the old behavior), so water faces still emit outward —
	# which looks worse than the culled case but is only a transient
	# issue: _materialize_chunk re-dirties neighbors when a chunk loads.
	_attach_neighbor_edges(snap)
	# Pass the mutex + result-holder array DIRECTLY (no self closure) so
	# the worker never touches `self` after dispatch. If the chunk_node is
	# freed mid-worker, the worker still has strong references to the
	# Mutex (RefCounted) and the result Array, so it can complete
	# safely. The main thread reads from the same Array via
	# _remesh_result_holder. Without this, freeing the chunk_node before
	# the worker landed could null `self._remesh_mutex` between worker's
	# null-check and lock() call → crash.
	if _remesh_result_holder.is_empty():
		_remesh_result_holder.append({})
	_remesh_task_id = WorkerThreadPool.add_task(
		_static_remesh_worker.bind(snap, _remesh_mutex, _remesh_result_holder)
	)


# Populate the snapshot's `edge_blocks_*` / `edge_meta_*` fields from the
# 4 loaded neighbor chunks. Reads ChunkManager via a parent-walk since
# chunk_node lives under it. If a neighbor isn't loaded, leaves the
# matching slice empty — get_block falls back to AIR at that edge.
func _attach_neighbor_edges(snap: Chunk) -> void:
	var manager: Node = get_parent()
	if manager == null or not manager.has_method("get_chunk_at_coord"):
		return
	var my_coord: Vector2i = _compute_chunk_coord()
	# West neighbor: its east edge (local x = SIZE_X-1) feeds our x=-1 plane.
	var west: Chunk = manager.get_chunk_at_coord(my_coord + Vector2i(-1, 0))
	if west != null:
		var pair: Array = west.east_edge_slices()
		snap.edge_blocks_west = pair[0]
		snap.edge_meta_west = pair[1]
	# East neighbor: its west edge feeds our x=SIZE_X plane.
	var east: Chunk = manager.get_chunk_at_coord(my_coord + Vector2i(1, 0))
	if east != null:
		var pair: Array = east.west_edge_slices()
		snap.edge_blocks_east = pair[0]
		snap.edge_meta_east = pair[1]
	# North neighbor (−Z): its south edge feeds our z=-1 plane.
	var north: Chunk = manager.get_chunk_at_coord(my_coord + Vector2i(0, -1))
	if north != null:
		var pair: Array = north.south_edge_slices()
		snap.edge_blocks_north = pair[0]
		snap.edge_meta_north = pair[1]
	# South neighbor (+Z): its north edge feeds our z=SIZE_Z plane.
	var south: Chunk = manager.get_chunk_at_coord(my_coord + Vector2i(0, 1))
	if south != null:
		var pair: Array = south.north_edge_slices()
		snap.edge_blocks_south = pair[0]
		snap.edge_meta_south = pair[1]


# Derive the chunk's (cx, cz) coord from its Node3D position. chunk_node
# is placed at `(cx * SIZE_X, 0, cz * SIZE_Z)` by ChunkManager, so a
# round-to-int divide recovers the coord.
func _compute_chunk_coord() -> Vector2i:
	var p: Vector3 = global_position
	return Vector2i(int(floor(p.x / float(Chunk.SIZE_X))), int(floor(p.z / float(Chunk.SIZE_Z))))


# Runs on a WorkerThreadPool thread. STATIC — does not touch `self`.
# Takes the mutex + result-holder array by argument so the worker holds
# its own strong references; the chunk_node can free itself mid-worker
# without crashing this function. The worker writes its result to
# holder[0]; the main thread reads via _remesh_result_holder in _process.
static func _static_remesh_worker(snap: Chunk, mtx: Mutex, holder: Array) -> void:
	var data: Dictionary = Mesher.mesh_chunk_fast(snap)
	# mtx and holder are guaranteed non-null here — they were captured by
	# the bind in _dispatch_remesh and the worker holds strong refs.
	mtx.lock()
	if not holder.is_empty():
		holder[0] = data
	mtx.unlock()


func cancel_remesh_task() -> void:
	if _remesh_task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_remesh_task_id)
		_remesh_task_id = -1


# Synchronous re-mesh for callers that NEED the mesh updated this frame
# (FallingBlock spawn point — async dispatch causes a 1-frame z-fight
# between the entity and the source cell). Pays the full mesh cost on
# the main thread; caller should use the async dispatch path instead
# whenever a 1-frame delay is acceptable.
func rebuild_mesh_immediate() -> void:
	_apply_mesh_data(Mesher.mesh_chunk_fast(chunk))
	chunk.dirty = false


# Toggle the StaticBody3D's collision shape without remeshing. Called by
# ChunkManager on player movement to keep only the near ring of chunks
# holding a live trimesh shape + BVH — saves ~1-2 MB * (outer chunks) at
# FAR. Rebuild is cheap (set_faces copies the cached PackedVector3Array
# into a fresh shape) so toggling is safe to call every chunk-boundary
# crossing.
func set_collision_active(active: bool) -> void:
	if active == _collision_active:
		return
	_collision_active = active
	if active:
		# Lazy collision-shape build — _apply_mesh_data now skips the
		# expensive ConcavePolygonShape3D.set_faces() for chunks outside
		# collision_radius. Build it here on demand, the first time the
		# player walks within range. One-time ~5-10 ms cost per chunk
		# entering the ring (instead of every chunk paying it at apply).
		if _collision_shape_cache == null and not _collision_faces_cache.is_empty():
			_collision_shape_cache = ConcavePolygonShape3D.new()
			_collision_shape_cache.set_faces(_collision_faces_cache)
		if _collision_shape_cache != null:
			_collision_shape.shape = _collision_shape_cache
	else:
		_collision_shape.shape = null


func _apply_mesh_data(data: Dictionary) -> void:
	var probe_token := PerfProbe.begin("chunk_node.apply")
	# Opaque sub-mesh. If the chunk is entirely empty OR entirely water,
	# both drop here: empty → clear opaque; water sub-mesh is handled below.
	if data.vertices.is_empty():
		_mesh_instance.mesh = null
		_collision_shape.shape = null
	else:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = data.vertices
		arrays[Mesh.ARRAY_NORMAL] = data.normals
		arrays[Mesh.ARRAY_TEX_UV] = data.uvs
		# Per-vertex face light from slice 5 (sky in R, block in G, sampled
		# from the cell adjacent to the face). Older mesh paths that
		# pre-date lighting won't include the key — chunk shader treats a
		# missing COLOR as full daylight via its default of vec4(1).
		if data.has("colors"):
			arrays[Mesh.ARRAY_COLOR] = data.colors
		arrays[Mesh.ARRAY_INDEX] = data.indices
		var array_mesh := ArrayMesh.new()
		array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		array_mesh.surface_set_material(0, BlockAtlas.material())
		_mesh_instance.mesh = array_mesh
		# Per-instance foliage tints. The chunk shader declares
		# grass_tint / leaves_tint as `instance uniform`, so the shader-
		# code defaults only apply if no per-instance value is set; we
		# always push explicitly to keep behavior identical regardless of
		# whether the user toggles the alpha-vintage setting. ChunkManager
		# re-runs apply_foliage_tints_to_all() on toggle changes.
		_apply_foliage_tints()
		# Per-instance Savanna tint — sample the climate biome at chunk
		# center; the chunk shader gates the yellow shift behind UV ∈
		# grass_top so non-grass faces stay normal. Per-chunk granularity
		# (not per-cell) is the trade-off for not plumbing a biome map
		# through the mesher.
		if Worldgen.terrain_3d_enabled:
			var coord_now: Vector2i = _compute_chunk_coord()
			var center_x: float = float(coord_now.x * Chunk.SIZE_X + 8)
			var center_z: float = float(coord_now.y * Chunk.SIZE_Z + 8)
			var biome_id: int = Worldgen3D.biome_at(center_x, center_z)
			var tint: float = 1.0 if biome_id == Worldgen3D.Biome.SAVANNA else 0.0
			_mesh_instance.set_instance_shader_parameter("savanna_tint", tint)
		# Prefer the worker-built collision faces (native mesher path).
		# When the GDScript fallback ran (e.g. chunk has water cells),
		# collision_faces isn't in the dict and we re-derive on the main
		# thread.
		if data.has("collision_faces"):
			_collision_faces_cache = data.collision_faces
		else:
			# Legacy fallback — derive from the mesh itself so we have
			# something to re-apply when collision toggles back on.
			var derived := array_mesh.create_trimesh_shape()
			_collision_faces_cache = (
				derived.get_faces() if derived != null else PackedVector3Array()
			)
		# Build the collision shape ONLY for chunks that need it RIGHT
		# NOW (within collision_radius). Distant chunks defer the build
		# to set_collision_active() when the player approaches. This
		# saves ~5-10 ms per chunk-apply during fast movement (flying
		# in creative), where 10+ chunks/sec materialize but only a
		# small inner ring actually needs collision.
		# ConcavePolygonShape3D.set_faces() calls PhysicsServer3D
		# internally and is the dominant cost in chunk_node.apply.
		if _collision_active and not _collision_faces_cache.is_empty():
			_collision_shape_cache = ConcavePolygonShape3D.new()
			_collision_shape_cache.set_faces(_collision_faces_cache)
			_collision_shape.shape = _collision_shape_cache
		else:
			# Cache the faces but don't build the shape yet — set_collision_active
			# will build it on demand.
			_collision_shape_cache = null
			_collision_shape.shape = null
	# Plant selection collision soup — only present when the GDScript
	# mesher ran (native skips non-cube blocks today). Empty soup ⇒ clear
	# the shape so the chunk doesn't keep stale plant hitboxes after the
	# last sapling is broken.
	if data.has("plant_faces") and not data.plant_faces.is_empty():
		var pshape := ConcavePolygonShape3D.new()
		pshape.set_faces(data.plant_faces)
		_plants_shape.shape = pshape
	else:
		_plants_shape.shape = null
	# Water sub-mesh — only present when the GDScript mesher ran. Keys are
	# absent on the native path (which never writes water), so a missing
	# key means "no water to render this rebuild."
	if data.has("water_vertices") and not data.water_vertices.is_empty():
		var warrs := []
		warrs.resize(Mesh.ARRAY_MAX)
		warrs[Mesh.ARRAY_VERTEX] = data.water_vertices
		warrs[Mesh.ARRAY_NORMAL] = data.water_normals
		warrs[Mesh.ARRAY_TEX_UV] = data.water_uvs
		# Per-vertex sky/block light — water shader multiplies its color by
		# max(sky·sky_factor, block) so caves / night dim water like cubes.
		# Native paths emit `water_colors`; GDScript path always does.
		# Missing key means stale extension before the lighting wiring; fall
		# back to `null` and the shader skips the multiply (constant tint).
		if data.has("water_colors") and not data.water_colors.is_empty():
			warrs[Mesh.ARRAY_COLOR] = data.water_colors
		warrs[Mesh.ARRAY_INDEX] = data.water_indices
		var water_mesh := ArrayMesh.new()
		water_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, warrs)
		water_mesh.surface_set_material(0, BlockAtlas.water_material())
		_water_mesh_instance.mesh = water_mesh
	else:
		_water_mesh_instance.mesh = null
	# Lava sub-mesh — same shape as water but opaque with the lava
	# material. Only the GDScript mesher emits it (native falls through
	# to cube; chunks with lava are flagged has_non_cube_blocks so they
	# always hit this path). Missing keys from the native path fall into
	# the else branch and clear the mesh.
	if data.has("lava_vertices") and not data.lava_vertices.is_empty():
		var larrs := []
		larrs.resize(Mesh.ARRAY_MAX)
		larrs[Mesh.ARRAY_VERTEX] = data.lava_vertices
		larrs[Mesh.ARRAY_NORMAL] = data.lava_normals
		larrs[Mesh.ARRAY_TEX_UV] = data.lava_uvs
		if data.has("lava_colors") and not data.lava_colors.is_empty():
			larrs[Mesh.ARRAY_COLOR] = data.lava_colors
		larrs[Mesh.ARRAY_INDEX] = data.lava_indices
		var lava_mesh := ArrayMesh.new()
		lava_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, larrs)
		lava_mesh.surface_set_material(0, BlockAtlas.lava_material())
		_lava_mesh_instance.mesh = lava_mesh
	else:
		_lava_mesh_instance.mesh = null
	if chunk.has_chest_blocks or not _chest_nodes.is_empty():
		_sync_chest_entities()
	if chunk.has_sign_blocks or not _sign_nodes.is_empty():
		_sync_sign_entities()
	PerfProbe.end("chunk_node.apply", probe_token)


# Walk the chunk for CHEST cells and ensure a ChestNode exists at each.
# Push the active grass / leaves tints to this chunk's mesh instance.
# Called at mesh-build time and by ChunkManager when the user toggles the
# vintage-foliage setting at runtime. Safe to call even if the chunk has
# no grass/leaves faces — the shader's UV gates skip non-foliage frags.
func apply_foliage_tints() -> void:
	if _mesh_instance == null:
		return
	_apply_foliage_tints()


func _apply_foliage_tints() -> void:
	_mesh_instance.set_instance_shader_parameter("grass_tint", BlockAtlas.grass_tint())
	_mesh_instance.set_instance_shader_parameter("leaves_tint", BlockAtlas.leaves_tint())


# Removes orphan entities for cells whose block is no longer a chest.
# Cheap because chest count per chunk is low (0..few) — we do a single
# linear scan over `chunk.blocks` keyed on the CHEST byte.
func _sync_chest_entities() -> void:
	var seen: Dictionary = {}
	# `chunk.blocks` is the flat PackedByteArray; inline-iterate via
	# Chunk.SIZE_X/Y/Z so we don't pay the per-call get_block bounds check.
	for y in range(Chunk.SIZE_Y):
		for z in range(Chunk.SIZE_Z):
			for x in range(Chunk.SIZE_X):
				var idx: int = y * Chunk.SIZE_X * Chunk.SIZE_Z + z * Chunk.SIZE_X + x
				if chunk.blocks[idx] != Blocks.CHEST:
					continue
				var key := Vector3i(x, y, z)
				seen[key] = true
				if not _chest_nodes.has(key):
					var node := ChestNode.new()
					# ChestNode mesh is centered on XZ (origin at cell
					# center), so node position = cell center. set_facing
					# rotates about this origin → pivots around the
					# chest's centerline as expected.
					node.position = Vector3(float(x) + 0.5, float(y), float(z) + 0.5)
					add_child(node)
					_chest_nodes[key] = node
				var meta: int = chunk.get_block_meta(x, y, z)
				_chest_nodes[key].set_facing(meta)
	# Despawn any chest entity whose cell is no longer a chest.
	for key: Vector3i in _chest_nodes.keys():
		if not seen.has(key):
			_chest_nodes[key].queue_free()
			_chest_nodes.erase(key)


# Called by interaction.gd via ChunkManager.find_chest_node_at(world_pos)
# so the right-click-to-open path can drive set_open() on the entity.
func find_chest_node_at_local(local_pos: Vector3i) -> ChestNode:
	return _chest_nodes.get(local_pos, null)


# Walk the chunk for SIGN_STANDING / SIGN_WALL cells, spawning a
# SignNode per cell that doesn't already have one. Removes orphan
# nodes whose underlying block was broken. Same iteration shape as
# _sync_chest_entities — signs are rare per chunk so the per-cell
# scan cost is negligible.
func _sync_sign_entities() -> void:
	var seen: Dictionary = {}
	var coord: Vector2i = _compute_chunk_coord()
	var ox: int = coord.x * Chunk.SIZE_X
	var oz: int = coord.y * Chunk.SIZE_Z
	for y in range(Chunk.SIZE_Y):
		for z in range(Chunk.SIZE_Z):
			for x in range(Chunk.SIZE_X):
				var idx: int = y * Chunk.SIZE_X * Chunk.SIZE_Z + z * Chunk.SIZE_X + x
				var bid: int = chunk.blocks[idx]
				if bid != Blocks.SIGN_STANDING and bid != Blocks.SIGN_WALL:
					continue
				var key := Vector3i(x, y, z)
				seen[key] = true
				var cell_meta: int = chunk.get_block_meta(x, y, z)
				# For wall signs only: detect fence support so the
				# SignNode label layout offsets to match the mesher's
				# panel offset into the fence cell. Same neighbour-query
				# pattern + same 0.375 m offset as mesher._emit_wall_sign.
				var fence_offset: Vector3 = Vector3.ZERO
				if bid == Blocks.SIGN_WALL:
					var off: float = 0.375
					match cell_meta & 3:
						0:
							if chunk.get_block(x, y, z + 1) == Blocks.FENCE:
								fence_offset = Vector3(0, 0, off)
						1:
							if chunk.get_block(x, y, z - 1) == Blocks.FENCE:
								fence_offset = Vector3(0, 0, -off)
						2:
							if chunk.get_block(x + 1, y, z) == Blocks.FENCE:
								fence_offset = Vector3(off, 0, 0)
						_:
							if chunk.get_block(x - 1, y, z) == Blocks.FENCE:
								fence_offset = Vector3(-off, 0, 0)
				# For STANDING signs: detect if the cell below is a
				# fence — mesher renders a shorter post and the label
				# layout follows the lower panel position.
				var standing_on_fence: bool = false
				if bid == Blocks.SIGN_STANDING:
					standing_on_fence = chunk.get_block(x, y - 1, z) == Blocks.FENCE
				if not _sign_nodes.has(key):
					var node := SignNode.new()
					node.is_wall_sign = (bid == Blocks.SIGN_WALL)
					node.meta = cell_meta
					node.fence_offset = fence_offset
					node.on_fence = standing_on_fence
					# Explicit world-cell coords so the SignNode's
					# text_changed signal listener matches the key used
					# by interaction.gd + SignStorage. Deriving this
					# from global_position used to break at coord 0 and
					# negative coords (Godot rounds half away from zero).
					node.world_pos = Vector3i(ox + x, y, oz + z)
					# Position at chunk-local cell origin (0..16 XZ;
					# Y in world coords). SignNode internally offsets
					# to cell-center XZ + cell-base Y via its label
					# layout. The chunk_node is translated to the
					# chunk origin in world space, so positioning
					# here is purely local.
					node.position = Vector3(float(x), float(y), float(z))
					add_child(node)
					_sign_nodes[key] = node
				else:
					# Existing node — re-check meta in case the player
					# broke + re-placed with a new orientation. Use the
					# setter so labels relayout.
					var existing: SignNode = _sign_nodes[key]
					existing.fence_offset = fence_offset
					existing.on_fence = standing_on_fence
					existing.update_orientation(bid == Blocks.SIGN_WALL, cell_meta)
	# Despawn entries whose cell is no longer a sign.
	for key: Vector3i in _sign_nodes.keys():
		if not seen.has(key):
			_sign_nodes[key].queue_free()
			_sign_nodes.erase(key)
