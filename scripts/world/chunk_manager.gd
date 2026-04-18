extends Node3D

# Manages ChunkNode instances around the player. Worldgen + meshing run on
# WorkerThreadPool; the main thread only handles the GPU mesh upload (which
# must stay on the main thread) and scene-tree manipulation.

@export var render_distance: int = 3
@export var chunk_scene: PackedScene
@export var player_path: NodePath = ^"../Player"
@export var max_concurrent_jobs: int = 4

var _player: Node3D
var _chunks: Dictionary = {}  # Vector2i → Node3D (ChunkNode)
var _pending: Dictionary = {}  # Vector2i → true (currently being computed)
var _spawn_queue: Array = []  # Vector2i FIFO of chunks to enqueue for workers
var _result_mutex := Mutex.new()
var _ready_results: Dictionary = {}  # Vector2i → {chunk, mesh} (set by workers)


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
	_update_chunk_set()
	_dispatch_workers()
	_materialize_one_ready_chunk()


# Decide which chunks should be loaded; enqueue missing ones, unload extras.
func _update_chunk_set() -> void:
	var pc := _player_chunk_coord()
	var needed: Dictionary = {}
	for dx in range(-render_distance, render_distance + 1):
		for dz in range(-render_distance, render_distance + 1):
			var coord := Vector2i(pc.x + dx, pc.y + dz)
			needed[coord] = true
			if not _chunks.has(coord) and not _pending.has(coord) and not _spawn_queue.has(coord):
				_spawn_queue.append(coord)
	var to_remove: Array = []
	for coord: Vector2i in _chunks:
		if not needed.has(coord):
			to_remove.append(coord)
	for coord: Vector2i in to_remove:
		_chunks[coord].queue_free()
		_chunks.erase(coord)
	# Drop queued chunks that are no longer needed
	_spawn_queue = _spawn_queue.filter(func(c: Vector2i) -> bool: return needed.has(c))
	# Drop completed worker results for chunks no longer needed, so evicted
	# mesh data doesn't linger in the queue (materialize consumes one per frame).
	# Leaves `_pending` alone — a worker may still be running and will write
	# to `_ready_results` after the sweep; the distance check in
	# `_materialize_one_ready_chunk` drops those.
	_result_mutex.lock()
	var stale_results: Array = []
	for coord: Vector2i in _ready_results:
		if not needed.has(coord):
			stale_results.append(coord)
	for coord: Vector2i in stale_results:
		_ready_results.erase(coord)
	_result_mutex.unlock()


# Hand queued chunks off to worker threads, capping in-flight work.
func _dispatch_workers() -> void:
	while not _spawn_queue.is_empty() and _pending.size() < max_concurrent_jobs:
		var coord: Vector2i = _spawn_queue.pop_front()
		if _chunks.has(coord) or _pending.has(coord):
			continue
		_pending[coord] = true
		WorkerThreadPool.add_task(_compute_chunk_data.bind(coord))


# Worker-thread function — runs off the main thread. Generates worldgen
# blocks + builds mesh arrays; stores results behind a mutex.
func _compute_chunk_data(coord: Vector2i) -> void:
	var chunk := Worldgen.generate_chunk(coord.x, coord.y)
	var mesh_data := Mesher.mesh_chunk(chunk)
	_result_mutex.lock()
	_ready_results[coord] = {"chunk": chunk, "mesh": mesh_data}
	_result_mutex.unlock()


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
	var node: Node3D = chunk_scene.instantiate()
	node.position = Vector3(coord.x * Chunk.SIZE_X, 0, coord.y * Chunk.SIZE_Z)
	node.set("chunk_data", data.chunk)
	node.set("precomputed_mesh_data", data.mesh)
	add_child(node)
	_chunks[coord] = node


# Synchronous fallback used at startup so the player has terrain to land on.
func _spawn_chunk_sync(coord: Vector2i) -> void:
	var chunk := Worldgen.generate_chunk(coord.x, coord.y)
	var mesh_data := Mesher.mesh_chunk(chunk)
	_materialize_chunk(coord, {"chunk": chunk, "mesh": mesh_data})


func _player_chunk_coord() -> Vector2i:
	var pos := _player.global_position
	return Vector2i(
		int(floor(pos.x / float(Chunk.SIZE_X))), int(floor(pos.z / float(Chunk.SIZE_Z)))
	)


# World-coord block edit. Looks up the right chunk, converts to local coords,
# applies. Silently no-ops if the target is outside the currently loaded area.
func set_world_block(world_pos: Vector3i, id: int) -> void:
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return
	var local_x: int = world_pos.x - chunk_x * Chunk.SIZE_X
	var local_z: int = world_pos.z - chunk_z * Chunk.SIZE_Z
	var chunk_node: Node3D = _chunks[coord]
	chunk_node.chunk.set_block(local_x, world_pos.y, local_z, id)


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
