extends Node3D

# Manages ChunkNode instances around the player. Worldgen + meshing run on
# WorkerThreadPool; the main thread only handles the GPU mesh upload (which
# must stay on the main thread) and scene-tree manipulation.

const _COMPRESS_MODE: int = FileAccess.COMPRESSION_FASTLZ

# Per-leaf random decay delay (seconds). Approximates vanilla Alpha's
# random-tick model — canopy visibly crumbles over a few seconds instead
# of vanishing in one frame.
const _LEAF_DECAY_DELAY_MIN: float = 1.0
const _LEAF_DECAY_DELAY_MAX: float = 4.0
# Cap on how many leaves we actually remove (including the BFS re-check)
# per frame, so a simultaneous multi-tree harvest doesn't stall the main
# thread. Entries left over stay queued for subsequent frames.
const _LEAF_DECAY_MAX_PER_TICK: int = 16

@export var render_distance: int = 3
@export var chunk_scene: PackedScene
@export var player_path: NodePath = ^"../Player"
@export var max_concurrent_jobs: int = 4

# Cumulative count of chunks fully materialized this session — never
# decremented when chunks unload. Read by the debug stats panel.
var chunks_generated_total: int = 0

var _player: Node3D
var _chunks: Dictionary = {}  # Vector2i → Node3D (ChunkNode)
var _pending: Dictionary = {}  # Vector2i → true (currently being computed)
var _spawn_queue: Array = []  # Vector2i FIFO of chunks to enqueue for workers
var _result_mutex := Mutex.new()
var _ready_results: Dictionary = {}  # Vector2i → {chunk, mesh} (set by workers)
# Player-edited chunks live here even after they're unloaded from the
# scene. On reload we restore from this cache instead of re-running
# worldgen, so towers / mined blocks / placed blocks survive walking out
# of render distance and back. In-memory only — disk save is a later phase.
#
# Storage shape: coord → { bytes: PackedByteArray (FastLZ-compressed
# 32 KB block array), max_y: int }. Above-ground edited chunks are mostly
# air which compresses ~50:1, so a typical edited chunk costs ~600 bytes
# instead of 32 KB. Compression runs only on UNLOAD (not per edit) so the
# cost stays out of the hot path. Decompression happens on dispatch
# (~1 ms, main thread) and the resulting Chunk is handed to the worker
# for re-meshing — no main-thread mesh hitch on re-entry.
var _saved_chunks: Dictionary = {}
# Loaded chunks that have been edited and need to be compressed-and-saved
# when they unload. Presence-set; values unused.
var _dirty_loaded: Dictionary = {}
# Orphaned leaves awaiting gradual decay. Entries: { pos: Vector3i,
# decay_at: float (seconds since boot) }. Alpha's random-tick model is
# approximated with a randomized per-leaf delay so the canopy visibly
# crumbles over a few seconds instead of vanishing in one frame. Each
# entry is re-checked at its decay tick — if a log was placed during the
# grace window, the leaf stays.
var _decaying_leaves: Array = []


func _ready() -> void:
	_player = get_node_or_null(player_path) as Node3D
	# Pre-generate the chunks around (0,0) synchronously so the player has
	# terrain to land on at game start. This blocks the main thread for ~50ms
	# at startup but only happens once.
	for dx in range(-render_distance, render_distance + 1):
		for dz in range(-render_distance, render_distance + 1):
			_spawn_chunk_sync(Vector2i(dx, dz))


func _process(_delta: float) -> void:
	if _player == null:
		return
	var probe_token := PerfProbe.begin("chunk_mgr.tick")
	_update_chunk_set()
	_dispatch_workers()
	_materialize_one_ready_chunk()
	_tick_leaf_decay()
	PerfProbe.end("chunk_mgr.tick", probe_token)


# Decide which chunks should be loaded; enqueue missing ones, unload extras.
# Chunks the player has previously edited get re-loaded from `_saved_chunks`
# via the same worker path — no synchronous mesh hitch — so towers / mines /
# any block edits survive walking out of render distance and back.
func _update_chunk_set() -> void:
	var pc := _player_chunk_coord()
	var needed: Dictionary = {}
	for dx in range(-render_distance, render_distance + 1):
		for dz in range(-render_distance, render_distance + 1):
			var coord := Vector2i(pc.x + dx, pc.y + dz)
			needed[coord] = true
			if _chunks.has(coord) or _pending.has(coord) or _spawn_queue.has(coord):
				continue
			# Same enqueue path whether the chunk is fresh worldgen or a
			# previously-saved edit — _dispatch_workers picks up the saved
			# bytes and the worker uses them instead of running worldgen.
			_spawn_queue.append(coord)
	var to_remove: Array[Vector2i] = []
	for coord: Vector2i in _chunks:
		if not needed.has(coord):
			to_remove.append(coord)
	for coord: Vector2i in to_remove:
		# If the chunk was edited while loaded, compress and persist its
		# blocks before freeing the ChunkNode.
		if _dirty_loaded.has(coord):
			_persist_chunk(coord, _chunks[coord].chunk)
			_dirty_loaded.erase(coord)
		_chunks[coord].queue_free()
		_chunks.erase(coord)
	# Drop queued chunks that are no longer needed. In-place reverse-loop
	# removal avoids allocating a fresh Array + Callable every frame.
	for i in range(_spawn_queue.size() - 1, -1, -1):
		if not needed.has(_spawn_queue[i]):
			_spawn_queue.remove_at(i)
	# Drop completed worker results for chunks no longer needed, so evicted
	# mesh data doesn't linger in the queue (materialize consumes one per frame).
	# Leaves `_pending` alone — a worker may still be running and will write
	# to `_ready_results` after the sweep; the distance check in
	# `_materialize_one_ready_chunk` drops those.
	_result_mutex.lock()
	var stale_results: Array[Vector2i] = []
	for coord: Vector2i in _ready_results:
		if not needed.has(coord):
			stale_results.append(coord)
	for coord: Vector2i in stale_results:
		_ready_results.erase(coord)
	_result_mutex.unlock()


# Hand queued chunks off to worker threads, capping in-flight work. If the
# chunk has saved player edits, we decompress on the main thread (~1 ms,
# infrequent) and pass the restored Chunk to the worker — saves the worker
# from running worldgen and keeps `_saved_chunks` access main-thread-only.
func _dispatch_workers() -> void:
	while not _spawn_queue.is_empty() and _pending.size() < max_concurrent_jobs:
		var coord: Vector2i = _spawn_queue.pop_front()
		if _chunks.has(coord) or _pending.has(coord):
			continue
		_pending[coord] = true
		var saved_chunk: Chunk = _restore_saved_chunk(coord)  # null if not saved
		WorkerThreadPool.add_task(_compute_chunk_data.bind(coord, saved_chunk))


# Worker-thread function — runs off the main thread. Uses the supplied
# saved chunk if present (player-edited reload); otherwise runs worldgen.
# Either way, builds the mesh arrays and stores the result behind a mutex.
func _compute_chunk_data(coord: Vector2i, saved_chunk: Chunk) -> void:
	var probe_token := PerfProbe.begin("chunk_mgr.worker_total")
	var chunk: Chunk = (
		saved_chunk if saved_chunk != null else Worldgen.generate_chunk(coord.x, coord.y)
	)
	var mesh_data := Mesher.mesh_chunk_fast(chunk)
	_result_mutex.lock()
	_ready_results[coord] = {"chunk": chunk, "mesh": mesh_data, "from_save": saved_chunk != null}
	_result_mutex.unlock()
	PerfProbe.end("chunk_mgr.worker_total", probe_token)


# Main thread: pick at most one completed chunk per frame and finish it
# (ArrayMesh build + collision + add to scene). Caps per-frame upload cost.
func _materialize_one_ready_chunk() -> void:
	_result_mutex.lock()
	var coord: Vector2i = Vector2i.ZERO
	var data: Dictionary = {}
	var has_one: bool = false
	for c: Vector2i in _ready_results:
		coord = c
		data = _ready_results[c]
		has_one = true
		break
	if has_one:
		_ready_results.erase(coord)
	_result_mutex.unlock()
	if not has_one:
		return
	_pending.erase(coord)
	# Player may have moved away while the worker was running — drop the result.
	var pc := _player_chunk_coord()
	if absi(coord.x - pc.x) > render_distance or absi(coord.y - pc.y) > render_distance:
		return
	if _chunks.has(coord):
		return
	_materialize_chunk(coord, data)


func _materialize_chunk(coord: Vector2i, data: Dictionary) -> void:
	var probe_token := PerfProbe.begin("chunk_mgr.materialize")
	var node: Node3D = chunk_scene.instantiate()
	node.position = Vector3(coord.x * Chunk.SIZE_X, 0, coord.y * Chunk.SIZE_Z)
	node.set("chunk_data", data.chunk)
	node.set("precomputed_mesh_data", data.mesh)
	add_child(node)
	_chunks[coord] = node
	chunks_generated_total += 1
	# A chunk that came from `_saved_chunks` is already player-edited;
	# mark it so any further edits (or just the next unload) re-persist.
	if data.get("from_save", false):
		_dirty_loaded[coord] = true
	PerfProbe.end("chunk_mgr.materialize", probe_token)


# Synchronous fallback used at startup so the player has terrain to land on.
func _spawn_chunk_sync(coord: Vector2i) -> void:
	var chunk := Worldgen.generate_chunk(coord.x, coord.y)
	var mesh_data := Mesher.mesh_chunk_fast(chunk)
	_materialize_chunk(coord, {"chunk": chunk, "mesh": mesh_data})


# Compress a chunk's blocks and stash them in `_saved_chunks`. Called only
# when an edited chunk is about to be unloaded, so the per-edit hot path
# never pays for compression.
func _persist_chunk(coord: Vector2i, chunk: Chunk) -> void:
	_saved_chunks[coord] = {
		"bytes": chunk.blocks.compress(_COMPRESS_MODE),
		"max_y": chunk.max_y,
	}


# Decompress a previously-saved chunk back into a Chunk RefCounted, ready
# to hand off to a worker for re-meshing. Returns null if the coord has
# no saved data. We pop it from `_saved_chunks` because the chunk will
# be live in `_chunks` again — re-persistence happens on next unload.
func _restore_saved_chunk(coord: Vector2i) -> Chunk:
	if not _saved_chunks.has(coord):
		return null
	var entry: Dictionary = _saved_chunks[coord]
	_saved_chunks.erase(coord)
	var c := Chunk.new()
	c.blocks = (entry.bytes as PackedByteArray).decompress(Chunk.TOTAL_BLOCKS, _COMPRESS_MODE)
	c.max_y = entry.max_y
	return c


func _player_chunk_coord() -> Vector2i:
	var pos := _player.global_position
	return Vector2i(
		int(floor(pos.x / float(Chunk.SIZE_X))), int(floor(pos.z / float(Chunk.SIZE_Z)))
	)


# World-coord block edit. Looks up the right chunk, converts to local coords,
# applies. Silently no-ops if the target is outside the currently loaded area.
# Marks the chunk as "modified" so it's preserved across unload/reload.
func set_world_block(world_pos: Vector3i, id: int) -> void:
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return
	var local_x: int = world_pos.x - chunk_x * Chunk.SIZE_X
	var local_z: int = world_pos.z - chunk_z * Chunk.SIZE_Z
	var chunk_node: Node3D = _chunks[coord]
	var old_id: int = chunk_node.chunk.get_block(local_x, world_pos.y, local_z)
	chunk_node.chunk.set_block(local_x, world_pos.y, local_z, id)
	# Just mark the coord as needing persistence; actual compression
	# happens lazily on unload (compressing on every edit would burn cycles
	# the player can feel during fast mining/placement).
	_dirty_loaded[coord] = true
	# Leaf decay — when a log is removed, scan nearby leaves and orphan
	# any that can no longer BFS-reach a log within LeafDecay.DECAY_RADIUS.
	# The nested set_world_block writes only AIR over LEAVES (never LOG),
	# so this cannot recurse indefinitely.
	if old_id == Blocks.LOG and id != Blocks.LOG:
		_decay_orphaned_leaves(world_pos)


# Queue orphaned leaves for gradual decay instead of removing them
# instantly. Each queued leaf picks a random delay so the canopy falls
# apart visibly (Alpha-style) rather than popping out in one frame.
func _decay_orphaned_leaves(log_world_pos: Vector3i) -> void:
	var orphans: Array[Vector3i] = LeafDecay.find_orphan_leaves(get_world_block, log_world_pos)
	if orphans.is_empty():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	for p: Vector3i in orphans:
		var delay: float = randf_range(_LEAF_DECAY_DELAY_MIN, _LEAF_DECAY_DELAY_MAX)
		_decaying_leaves.append({"pos": p, "decay_at": now + delay})


# Drain any leaves whose decay delay has elapsed. Re-checks connectivity
# at the moment of decay, so if the player placed a log during the grace
# period the remaining orphans quietly reattach and survive. In-place
# reverse-loop removal (no per-frame Array rebuild); cap per-tick BFS
# count so a large forest harvest doesn't spike the main thread when
# many orphans hit their timer on the same frame.
func _tick_leaf_decay() -> void:
	if _decaying_leaves.is_empty():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var processed: int = 0
	for i in range(_decaying_leaves.size() - 1, -1, -1):
		var entry: Dictionary = _decaying_leaves[i]
		if entry.decay_at > now:
			continue
		_decaying_leaves.remove_at(i)
		var p: Vector3i = entry.pos
		# Re-check: leaf might have been saved by a freshly placed log, or
		# already removed by an adjacent decay rippling through.
		if LeafDecay.is_orphan(get_world_block, p):
			set_world_block(p, Blocks.AIR)
		processed += 1
		if processed >= _LEAF_DECAY_MAX_PER_TICK:
			return


# World-coord block read. Returns AIR if the chunk isn't loaded.
func get_world_block(world_pos: Vector3i) -> int:
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return Blocks.AIR
	var local_x: int = world_pos.x - chunk_x * Chunk.SIZE_X
	var local_z: int = world_pos.z - chunk_z * Chunk.SIZE_Z
	var chunk_node: Node3D = _chunks[coord]
	return chunk_node.chunk.get_block(local_x, world_pos.y, local_z)
