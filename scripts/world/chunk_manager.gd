# gdlint: disable=max-file-lines
extends Node3D

# Manages ChunkNode instances around the player. Worldgen + meshing run on
# WorkerThreadPool; main thread handles GPU mesh upload + scene-tree ops.
# `initial_chunks_ready` drives the LoadingScreen progress bar (mirrors
# Minecraft.java:1012 d(String)).
signal initial_chunks_ready(loaded: int, total: int)
const _COMPRESS_MODE: int = FileAccess.COMPRESSION_FASTLZ
# preload() sidesteps a Godot editor class-index race on fresh class_name.
const _TICK_SCHEDULER: GDScript = preload("res://scripts/world/tick_scheduler.gd")
const _BLOCK_FX: GDScript = preload("res://scripts/world/block_fx.gd")

# Leaf-decay + sapling-growth delays. Exponential-distributed to
# approximate Alpha random-tick pacing. MIN clamps avoid same-frame
# pop-in; MAX caps the long tail. Per-frame caps bound main-thread work
# on multi-tree harvests / sapling bursts.
const _LEAF_DECAY_MEAN_SEC: float = 30.0
const _LEAF_DECAY_MIN_SEC: float = 2.0
const _LEAF_DECAY_MAX_SEC: float = 180.0
const _LEAF_DECAY_MAX_PER_TICK: int = 16
const _SAPLING_GROW_MEAN_SEC: float = 90.0
const _SAPLING_GROW_MIN_SEC: float = 30.0
const _SAPLING_GROW_MAX_SEC: float = 300.0
# Retry delay when growth is blocked (no sky exposure yet).
const _SAPLING_GROW_RETRY_SEC: float = 30.0
const _SAPLING_GROW_MAX_PER_TICK: int = 4

@export var render_distance: int = 8
@export var chunk_scene: PackedScene
@export var player_path: NodePath = ^"../Player"
@export var max_concurrent_jobs: int = 4
# Cap on _apply_mesh_data calls per frame. Each apply = up to 3 ArrayMesh
# VBOs + trimesh; stacking them on one frame caused 120→70 fps spikes.
@export var apply_budget_per_frame: int = 1
# Chebyshev radius of the live-physics ring around the player. Saves
# ~1-2 MB × outer chunks of trimesh + BVH at FAR.
@export var collision_radius: int = 2

# Cumulative count of chunks fully materialized this session — never
# decremented when chunks unload. Read by the debug stats panel.
var chunks_generated_total: int = 0

var _player: Node3D
var _chunks: Dictionary = {}  # Vector2i → Node3D (ChunkNode)
var _pending: Dictionary = {}  # Vector2i → true (currently being computed)
var _spawn_queue: Array = []  # Vector2i FIFO of chunks to enqueue for workers
var _result_mutex := Mutex.new()
var _ready_results: Dictionary = {}  # Vector2i → {chunk, mesh} (set by workers)
# Off-main relight machinery. `_pending_relights` blocks double-dispatch
# while a worker is in flight for a coord; `_relight_results` is filled by
# the worker and drained one-per-frame on the main thread. Together they
# move `Lighting.relight_chunk_borders` (p50 5 ms / max 18 ms on main) onto
# the worker pool — the main thread now only pays the cheap apply-back step
# (PackedByteArray assigns + dirty marks). See `_dispatch_relight`.
var _pending_relights: Dictionary = {}  # Vector2i → true
var _relight_results: Dictionary = {}  # Vector2i → result_dict (mutex-guarded)
# Player-edited chunks compressed on unload, restored on re-entry.
# Shape: coord → { bytes, block_meta, sky_light, block_light, height_map,
# max_y, pending_ticks }, all FastLZ-compressed; ~50:1 on above-ground edits.
var _saved_chunks: Dictionary = {}
var _dirty_loaded: Dictionary = {}  # loaded edited chunks awaiting persist-on-unload
# Orphaned leaves / saplings awaiting a timed callback. Entries:
#   _decaying_leaves: { pos, decay_at } — exponential delay; logs within
#     the grace window abort decay. Alpha random-tick approximation.
#   _growing_saplings: { pos, grow_at } — sky-exposure checked at grow
#     time (proxy for Alpha's light≥9), re-queues if blocked.
var _decaying_leaves: Array = []
var _growing_saplings: Array = []
# Guard: prevents recursive STILL-water cell cascades via set_world_block
# from inside on_neighbor_changed. See BlockFluids for the fanout shape.
var _inside_fluid_notify: bool = false
# Deferred sky-light seeds + fizz during a fluid fanout — prevents
# per-cell BFS + particle alloc on water-on-lava cascades. Flushed on
# unwind via FluidFx.flush_deferred.
var _light_defer_depth: int = 0
var _deferred_sky_seeds: Dictionary = {}  # Vector3i → true
var _deferred_fizz: Array = []
# Last player chunk we ran _update_collision_activity against. Skip the
# sweep until the player actually crosses a chunk boundary.
var _last_collision_center: Vector2i = Vector2i(2147483647, 2147483647)
var _applies_this_frame: int = 0  # reset each _process; see try_consume_apply_budget
# Ambient scanner timer — drives AmbientFx.tick at 10 Hz. Vanilla's
# cy.java randomDisplayTick runs per-frame; we sample less often.
var _ambient_scan_accum: float = 0.0
# Spiral-offsets cache + spawn-queue membership set: rebuilding the 1088
# offset array + sorting every frame at FAR cost ~1-2 ms; O(n) _spawn_queue.has
# inside the 1089-iteration loop compounds. Both keyed off render_distance.
var _spiral_offsets_cache: Array = []
var _spiral_offsets_r: int = -1
var _spawn_queue_set: Dictionary = {}


func _ready() -> void:
	_player = get_node_or_null(player_path) as Node3D
	# Pre-warm the fluid-FX particle pool so the first water-on-lava fizz
	# doesn't pay a GPU shader-compile hitch. Safe here (ChunkManager
	# outlives the gameplay session) and cheap (builds 6 inert emitters).
	FluidFx.warm_pool(self)
	# Same trick for break particles — without this, the first dirt break
	# pays a ~10-30 ms shader-compile spike (user reported as a stutter
	# after first break). preload() instead of class_name BlockFx — the
	# editor index lags one reload behind for new files.
	_BLOCK_FX.warm_pool(self)
	# Honor the Main-Menu → Settings render-distance choice. Overrides the
	# @export default on the .tscn instance without requiring per-user
	# edits to the scene file.
	var cfg := SettingsMenu.load_config()
	render_distance = int(cfg.get_value("graphics", "render_distance", render_distance))
	ChunkView.apply_alpha_fog(get_tree(), render_distance)
	# Spawn the player's current chunk synchronously so they have ground
	# under them the moment the scene comes up. The rest of the render-
	# distance ring spawns one chunk per frame so the LoadingScreen can
	# actually render between steps (synchronous 49-chunk pre-gen was
	# showing up as a multi-second gray freeze). initial_chunks_ready fires
	# after each chunk materializes so the progress bar updates live.
	_spawn_initial_chunks.call_deferred()


func _spawn_initial_chunks() -> void:
	var span: int = render_distance * 2 + 1
	var total: int = span * span
	var loaded: int = 0
	_spawn_chunk_sync(Vector2i.ZERO)
	loaded += 1
	initial_chunks_ready.emit(loaded, total)
	# Spiral-out by squared distance so the player-ring lands first.
	var order: Array = ChunkView.spiral_offsets(render_distance)
	for c: Vector2i in order:
		await get_tree().process_frame
		_spawn_chunk_sync(c)
		loaded += 1
		initial_chunks_ready.emit(loaded, total)


func _process(_delta: float) -> void:
	if _player == null:
		return
	var probe_token := PerfProbe.begin("chunk_mgr.tick")
	_applies_this_frame = 0
	_update_chunk_set()
	_update_collision_activity()
	_dispatch_workers()
	_materialize_one_ready_chunk()
	_drain_relight_results()
	_ambient_scan_accum += _delta
	if _ambient_scan_accum >= 0.1:
		_ambient_scan_accum = 0.0
		AmbientFx.tick(self, _player_chunk_coord(), int(floor(_player.global_position.y)))
	_tick_leaf_decay()
	_tick_sapling_growth()
	# Scheduled block-tick queue — Flow #2 foundation for fluid flow.
	# Drains at vanilla 20 Hz (50 ms per tick); fires BlockFluids cascade
	# and future redstone / growth callbacks. Frame-hitch-safe: the
	# scheduler caps catch-up to 20 ticks/frame so a long pause doesn't
	# dump hundreds of pending ticks into one frame.
	#
	# preload() instead of the class_name — Godot's editor class index
	# sometimes lags one reload behind when a new class_name lands,
	# which manifests as "Identifier TickScheduler not declared" on
	# first run. The preload path doesn't depend on the index.
	_TICK_SCHEDULER.advance(_delta, self)
	PerfProbe.end("chunk_mgr.tick", probe_token)


# Decide which chunks should be loaded; enqueue missing ones, unload extras.
# Chunks the player has previously edited get re-loaded from `_saved_chunks`
# via the same worker path — no synchronous mesh hitch — so towers / mines /
# any block edits survive walking out of render distance and back.
func _update_chunk_set() -> void:
	var pc := _player_chunk_coord()
	var needed: Dictionary = {}
	# Mark the full ring needed, then enqueue misses in nearest-first order
	# so workers finish the player-ring before chasing far corners.
	for dx in range(-render_distance, render_distance + 1):
		for dz in range(-render_distance, render_distance + 1):
			needed[Vector2i(pc.x + dx, pc.y + dz)] = true
	# Rebuild spiral offsets only when render_distance changes. At FAR
	# the raw build + sort_custom is ~1 ms per call — 60 fps × 1 ms =
	# 60 ms/s of pure waste when the value is stable.
	if _spiral_offsets_r != render_distance:
		_spiral_offsets_cache = ChunkView.spiral_offsets(render_distance)
		_spiral_offsets_r = render_distance
	for off: Vector2i in _spiral_offsets_cache:
		var coord: Vector2i = pc + off
		if _chunks.has(coord) or _pending.has(coord) or _spawn_queue_set.has(coord):
			continue
		_spawn_queue.append(coord)
		_spawn_queue_set[coord] = true
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
		_chunks[coord].cancel_remesh_task()
		_chunks[coord].queue_free()
		_chunks.erase(coord)
	# Drop queued chunks that are no longer needed. In-place reverse-loop
	# removal avoids allocating a fresh Array + Callable every frame.
	for i in range(_spawn_queue.size() - 1, -1, -1):
		var qc: Vector2i = _spawn_queue[i]
		if not needed.has(qc):
			_spawn_queue.remove_at(i)
			_spawn_queue_set.erase(qc)
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
		_spawn_queue_set.erase(coord)
		if _chunks.has(coord) or _pending.has(coord):
			continue
		_pending[coord] = true
		var saved_chunk: Chunk = _restore_saved_chunk(coord)  # null if not saved
		WorkerThreadPool.add_task(_compute_chunk_data.bind(coord, saved_chunk))


# Worker-thread function — runs off the main thread. Uses the supplied
# saved chunk if present (player-edited reload); otherwise runs worldgen.
# Either way, builds the mesh arrays and stores the result behind a mutex.
# Lighting fill runs after worldgen but before mesh: vanilla mesher reads
# sky_light per face for the chunk shader (slice 5), so the data must be
# in place before the mesh arrays are baked. We ALWAYS re-run the fill
# (even on restore) — saved sky_light from earlier sessions can be stale
# if the player saved before the lighting code shipped (everything reads
# as default 15 and caves render lit). With the C++ port this costs
# ~30-50ms per chunk vs the old 380ms, so the wasted-work argument no
# longer holds and correctness wins.
func _compute_chunk_data(coord: Vector2i, saved_chunk: Chunk) -> void:
	var probe_token := PerfProbe.begin("chunk_mgr.worker_total")
	var chunk: Chunk = (
		saved_chunk if saved_chunk != null else Worldgen.generate_chunk(coord.x, coord.y)
	)
	Lighting.fill_sky_light(chunk)
	Lighting.fill_block_light(chunk)
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
	# Re-dirty loaded neighbors AND this new chunk so the edge-snapshot
	# re-mesh path (chunk_node._dispatch_remesh → _attach_neighbor_edges)
	# runs once per seam. The worker's initial mesh (_compute_chunk_data
	# → mesh_chunk_fast) sees empty neighbor slices because workers can't
	# safely read main-thread data; the first correct mesh happens on the
	# next frame via chunk_node._process.
	var had_neighbor: bool = false
	for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var neighbor_coord: Vector2i = coord + offset
		if _chunks.has(neighbor_coord):
			_chunks[neighbor_coord].chunk.dirty = true
			had_neighbor = true
	# Set initial collision activity from distance so far-ring chunks
	# don't waste a trimesh + BVH between materialize and the next
	# boundary-crossing sweep.
	var pc := _player_chunk_coord()
	var near: bool = (
		absi(coord.x - pc.x) <= collision_radius and absi(coord.y - pc.y) <= collision_radius
	)
	node.call("set_collision_active", near)
	if had_neighbor:
		data.chunk.dirty = true
		# Cross-chunk lighting relight (slice 3b). Per-chunk fill_*_light is
		# pessimistic at borders — torches near a seam don't light into the
		# neighbor, and a sealed cave under one chunk doesn't get sky-light
		# leaked in from a sky-open neighbor. Walk each loaded seam, recompute
		# both channels at the boundary, and BFS the changes inland. Mirrors
		# vanilla WorldServer.lightChunk → World.b(EnumSkyBlock, AABB) called
		# after Chunk.k() inserts the chunk into the loaded set.
		# Dispatched to a worker thread — the BFS itself is native + sub-ms
		# but the FFI marshalling + per-cell dict writes were a 5-18 ms
		# main-thread spike on every materialize. The worker reads chunk
		# snapshots; the result is applied one-per-frame in `_drain_relight_results`.
		_dispatch_relight(coord)
	PerfProbe.end("chunk_mgr.materialize", probe_token)


# Synchronous fallback used at startup so the player has terrain to land on.
func _spawn_chunk_sync(coord: Vector2i) -> void:
	if _chunks.has(coord):
		return
	var chunk := Worldgen.generate_chunk(coord.x, coord.y)
	Lighting.fill_sky_light(chunk)
	Lighting.fill_block_light(chunk)
	var mesh_data := Mesher.mesh_chunk_fast(chunk)
	_materialize_chunk(coord, {"chunk": chunk, "mesh": mesh_data})


# Snapshot the {target + cardinal neighbors} chunks and dispatch the
# native cross-chunk relight to a worker thread. Replaces the synchronous
# `Lighting.relight_chunk_borders` main-thread call. Result is drained
# one-per-frame in `_drain_relight_results` and applied via
# `Lighting.apply_relight_result`.
#
# Race handling:
#   * `_pending_relights[coord]` blocks double-dispatch while a worker is
#     in flight for the same coord.
#   * `apply_relight_result` skips chunks that were unloaded mid-flight.
#   * Player edits to a chunk between dispatch and apply will get
#     overwritten by the stale worker result. The next edit triggers
#     `update_*_light_around_world` which repairs the affected cells.
#     Walking-only (the reported lag-spike case) has no edits.
func _dispatch_relight(coord: Vector2i) -> void:
	if _pending_relights.has(coord):
		return
	var target: Chunk = get_chunk_at_coord(coord)
	if target == null:
		return
	var neighbors: Array[Vector2i] = []
	for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = coord + offset
		if get_chunk_at_coord(n) != null:
			neighbors.append(n)
	if neighbors.is_empty():
		return
	# Heightmap rebuild + array snapshot happens here on main (single-digit
	# µs per chunk; the height_map cache is a main-thread mutation).
	var chunk_data: Array = Lighting.prepare_relight_data(coord, target, neighbors, self)
	_pending_relights[coord] = true
	WorkerThreadPool.add_task(_relight_worker.bind(coord, chunk_data))


# Worker-thread entry — runs the native BFS on the snapshotted slabs and
# stashes the result for the main thread to apply.
func _relight_worker(coord: Vector2i, chunk_data: Array) -> void:
	var result: Dictionary = Lighting.compute_relight_borders_native(coord, chunk_data)
	_result_mutex.lock()
	_relight_results[coord] = result
	_result_mutex.unlock()


# Main-thread drain — at most one relight result per frame keeps the apply
# spike bounded. Apply itself is cheap (a few PackedByteArray pointer
# assigns + dirty marks) but each one re-meshes the touched chunks, so
# spreading them out reads as smoother frames.
func _drain_relight_results() -> void:
	_result_mutex.lock()
	var coord: Vector2i = Vector2i.ZERO
	var result: Dictionary = {}
	var has_one: bool = false
	for c: Vector2i in _relight_results:
		coord = c
		result = _relight_results[c]
		has_one = true
		break
	if has_one:
		_relight_results.erase(coord)
	_result_mutex.unlock()
	if not has_one:
		return
	_pending_relights.erase(coord)
	Lighting.apply_relight_result(result, self)


# Compress a chunk's blocks and stash them in `_saved_chunks`. Called only
# when an edited chunk is about to be unloaded, so the per-edit hot path
# never pays for compression. Light arrays compress cheaply (long runs of
# 15s above ground, 0s in caves) so adding them ~doubles the payload but
# stays under a couple KB per typical edited chunk.
func _persist_chunk(coord: Vector2i, chunk: Chunk) -> void:
	# Heightmap is only 256 bytes — compresses to nothing, but persisting
	# saves a 32 KB rebuild on the next is_sky_exposed call after restore.
	# `pending_ticks` harvests any BlockFluids/etc. ticks still queued for
	# cells in this chunk so mid-flow fluid resumes on reload instead of
	# freezing (vanilla keeps chunk tick state via NBT's TileTicks).
	_saved_chunks[coord] = {
		"bytes": chunk.blocks.compress(_COMPRESS_MODE),
		"block_meta": chunk.block_meta.compress(_COMPRESS_MODE),
		"sky_light": chunk.sky_light.compress(_COMPRESS_MODE),
		"block_light": chunk.block_light.compress(_COMPRESS_MODE),
		"height_map": chunk.height_map.compress(_COMPRESS_MODE),
		"max_y": chunk.max_y,
		"pending_ticks": TickScheduler.take_for_chunk(coord.x, coord.y),
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
	# Light arrays — older save entries (from before slice 1 lighting
	# landed) won't have these keys; fall through to Chunk._init's defaults
	# (sky=15 everywhere, block=0) for backward compatibility with any
	# in-memory caches still holding pre-lighting payloads.
	if entry.has("sky_light"):
		c.sky_light = ((entry.sky_light as PackedByteArray).decompress(
			Chunk.TOTAL_BLOCKS, _COMPRESS_MODE
		))
	if entry.has("block_light"):
		c.block_light = ((entry.block_light as PackedByteArray).decompress(
			Chunk.TOTAL_BLOCKS, _COMPRESS_MODE
		))
	# Block metadata — required once flow-fluid landed in Flow #1. Older
	# saves without the key fall through to Chunk._init's zero defaults,
	# which is still correct for any block that was ID-only (pre-flow).
	if entry.has("block_meta"):
		c.block_meta = ((entry.block_meta as PackedByteArray).decompress(
			Chunk.TOTAL_BLOCKS, _COMPRESS_MODE
		))
	# Heightmap — restore when present, else flag dirty so the next
	# is_sky_exposed call rebuilds from raw blocks. Saves a 32 KB rescan
	# on every chunk reload from save cache.
	if entry.has("height_map"):
		c.height_map = ((entry.height_map as PackedByteArray).decompress(
			Chunk.SIZE_X * Chunk.SIZE_Z, _COMPRESS_MODE
		))
		c._height_map_dirty = false
	else:
		c._height_map_dirty = true
	# Rescan non-cube flag + re-enqueue saplings.
	var found_non_cube: bool = false
	for i in range(c.blocks.size()):
		var b: int = c.blocks[i]
		if Blocks.needs_gdscript_mesher(b):
			found_non_cube = true
			if b == Blocks.SAPLING:
				var lx: int = i % Chunk.SIZE_X
				var lz: int = (i / Chunk.SIZE_X) % Chunk.SIZE_Z
				var ly: int = i / (Chunk.SIZE_X * Chunk.SIZE_Z)
				_enqueue_sapling_growth(
					Vector3i(coord.x * Chunk.SIZE_X + lx, ly, coord.y * Chunk.SIZE_Z + lz)
				)
	c.has_non_cube_blocks = found_non_cube
	# Re-enqueue any pending block ticks harvested when this chunk was
	# unloaded (fluid spread mid-flow, FIRE burn-out timers, etc.).
	# Their relative `delay` resumes from current_tick on restore.
	if entry.has("pending_ticks"):
		TickScheduler.restore_ticks(entry.pending_ticks as Array)
	return c


# Re-enable physics only on chunks within collision_radius of the player
# (Chebyshev / square ring). Skips unless the player actually crossed a
# chunk boundary, so cost is O(loaded) at most once per crossing.
func _update_collision_activity() -> void:
	var pc := _player_chunk_coord()
	if pc == _last_collision_center:
		return
	_last_collision_center = pc
	ChunkView.update_collision_activity(_chunks, pc, collision_radius)


func _player_chunk_coord() -> Vector2i:
	var pos := _player.global_position
	return Vector2i(
		int(floor(pos.x / float(Chunk.SIZE_X))), int(floor(pos.z / float(Chunk.SIZE_Z)))
	)


# Find the ChestNode entity at a given world cell, or null if none. Used
# by interaction.gd to drive the lid open/close animation when the
# chest UI opens. Routes through the owning chunk_node, which maintains
# a per-chunk dict of chest entities (chunk_node._sync_chest_entities).
func find_chest_node_at(world_pos: Vector3i) -> ChestNode:
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return null
	var chunk_node: Node3D = _chunks[coord]
	var local := Vector3i(
		world_pos.x - chunk_x * Chunk.SIZE_X, world_pos.y, world_pos.z - chunk_z * Chunk.SIZE_Z
	)
	if chunk_node.has_method("find_chest_node_at_local"):
		return chunk_node.find_chest_node_at_local(local)
	return null


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
	_dirty_loaded[coord] = true
	# Priority-apply flag — the upcoming worker re-mesh result skips the
	# 1-per-frame apply budget queue. Without this, player edits at FAR
	# render distance can hang behind background relight-driven re-meshes
	# for many seconds (ghost-block bug). chunk_node clears the flag on
	# apply.
	chunk_node.set("_priority_apply", true)
	# Edge-edit neighbor refresh. Native mesher culls faces across chunk
	# seams via chunk_node._attach_neighbor_edges; neighbors must re-mesh
	# when our edit lands on a seam cell, otherwise their opposing face
	# stays culled against a stale slice (screenshot 2026-04-24: grass
	# side holes + walkable gaps at chunk x=15).
	if old_id != id:
		var nx: int = -1 if local_x == 0 else (1 if local_x == Chunk.SIZE_X - 1 else 0)
		var nz: int = -1 if local_z == 0 else (1 if local_z == Chunk.SIZE_Z - 1 else 0)
		for off: Vector2i in [Vector2i(nx, 0), Vector2i(0, nz), Vector2i(nx, nz)]:
			if off == Vector2i.ZERO:
				continue
			var target: Vector2i = coord + off
			if _chunks.has(target):
				_chunks[target].chunk.dirty = true
	# Gravity — when a block becomes air, settle anything gravity-affected
	# (sand, gravel) sitting above. Single-pass column scan, no recursion.
	if id == Blocks.AIR:
		_settle_gravity_above(coord, local_x, world_pos.y, local_z)
	# Sky-light incremental update — bounded BFS in WORLD coords so it
	# crosses chunk boundaries cleanly. Mirrors vanilla cy.a(SKY, ...) →
	# mc.a() relight box (vendor/alpha-1.2.6-src/src/mc.java). Skipped
	# when opacity is unchanged (e.g. swapping two solid blocks) since
	# that can't move light. Touched chunks are marked dirty by
	# `set_world_sky_light` so they re-mesh next frame — including
	# neighbor chunks at the edit's chunk border.
	if old_id != id and Blocks.light_opacity(old_id) != Blocks.light_opacity(id):
		if _light_defer_depth > 0:
			_deferred_sky_seeds[world_pos] = true
		else:
			Lighting.update_sky_light_around_world(world_pos, self)
	# Block-light update mirrors the sky branch — lava (bucket + flow)
	# emits 15 and needs this BFS to light surrounding cells on edit.
	var em_diff: bool = Blocks.light_emission(old_id) != Blocks.light_emission(id)
	var op_diff: bool = Blocks.light_opacity(old_id) != Blocks.light_opacity(id)
	if old_id != id and (em_diff or op_diff):
		Lighting.update_block_light_around_world(world_pos, self)
	# Plant detach — vanilla BlockPlant.doPhysics fires when a neighbor
	# changes; if the support directly below is no longer grass/dirt/
	# farmland, the plant pops off and drops itself. We trigger on any
	# write at world_pos that invalidates the support of a plant in the
	# cell directly above. Cheap: one lookup, one is_valid check.
	if not Blocks.is_valid_plant_support(id):
		_drop_plant_if_unsupported(coord, local_x, world_pos.y + 1, local_z)
	# Sapling growth queue — when a sapling is placed (player drop or
	# bonemeal-spawn later), schedule it for a future tree growth tick.
	if id == Blocks.SAPLING:
		_enqueue_sapling_growth(world_pos)
	# Leaf decay — when a log is removed, scan nearby leaves and orphan
	# any that can no longer BFS-reach a log within LeafDecay.DECAY_RADIUS.
	# The nested set_world_block writes only AIR over LEAVES (never LOG),
	# so this cannot recurse indefinitely.
	if old_id == Blocks.LOG and id != Blocks.LOG:
		_decay_orphaned_leaves(world_pos)
	# Fluid neighbor-notify (Flow #3). When a block changes, the 6 adjacent
	# cells plus the cell itself may need to re-evaluate fluid flow. Still
	# fluids flip to flowing (via BlockFluids.on_neighbor_changed) so the
	# spread algorithm re-runs; flowing fluids already tick on their own.
	# Placing a fluid source (e.g. via bucket → set_world_block_with_meta)
	# needs to schedule the initial tick — handled below.
	if old_id != id:
		_notify_fluid_neighbors(world_pos)
		# Placing any fluid variant (source or flowing) at `pos` requires
		# the cell itself to start ticking. Vanilla calls this from
		# BlockFluids.c() on initial place; we dispatch here centrally.
		if Blocks.is_water(id) or Blocks.is_lava(id):
			_schedule_fluid_tick(world_pos, id)


# Same as set_world_block, but rebuilds the target chunk's mesh + collision
# on this frame rather than waiting for chunk_node._process to pick up the
# dirty flag next frame. FallingBlock uses this on land so the just-placed
# block is visible the same frame the entity hides — without it, the
# entity disappears one frame before the block appears, and entities
# above us would also render overlapping the fresh block for a frame.
func set_world_block_immediate(world_pos: Vector3i, id: int) -> void:
	set_world_block(world_pos, id)
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return
	var chunk_node: Node3D = _chunks[coord]
	# Synchronous same-frame rebuild — `FallingBlock` relies on the
	# freshly-placed block being visible the moment the entity hides.
	# Chunk re-meshes otherwise go through the worker dispatch in
	# chunk_node._process; this bypasses it on purpose.
	chunk_node._apply_mesh_data(Mesher.mesh_chunk_fast(chunk_node.chunk))
	chunk_node.chunk.dirty = false


# Queue orphaned leaves for gradual decay instead of removing them
# instantly. Each queued leaf picks a random delay so the canopy falls
# apart visibly (Alpha-style) rather than popping out in one frame.
func _decay_orphaned_leaves(log_world_pos: Vector3i) -> void:
	var orphans: Array[Vector3i] = LeafDecay.find_orphan_leaves(get_world_block, log_world_pos)
	if orphans.is_empty():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	for p: Vector3i in orphans:
		# Exponential distribution: draw u ∈ (0, 1] and map to -mean·ln(u).
		# Clamped so no leaf either pops instantly or hangs forever. This
		# matches vanilla's "most decay in ~mean seconds, some linger" feel
		# better than the uniform window we used before.
		var u: float = maxf(randf(), 0.0001)
		var delay: float = clampf(
			-_LEAF_DECAY_MEAN_SEC * log(u), _LEAF_DECAY_MIN_SEC, _LEAF_DECAY_MAX_SEC
		)
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


# Walks the column above (local_x, from_y, local_z) inside the given
# chunk; for each contiguous gravity block found above the air gap, clear
# its cell and spawn a FallingBlock entity to handle the visible drop +
# physics + landing. Mirrors vanilla BlockFalling.m() in Bukkit/mc-dev —
# checks only that the block can fall (already true since the cell below
# just became AIR), then defers placement to the entity. Cross-chunk
# safe: lookups stay in this (x,z) chunk; the entity moves in world space
# and lands wherever physics takes it.
func _settle_gravity_above(coord: Vector2i, local_x: int, from_y: int, local_z: int) -> void:
	var chunk: Chunk = _chunks[coord].chunk
	var world_x: int = coord.x * Chunk.SIZE_X + local_x
	var world_z: int = coord.y * Chunk.SIZE_Z + local_z
	var scan_y: int = from_y + 1
	while scan_y < Chunk.SIZE_Y:
		var here_id: int = chunk.get_block(local_x, scan_y, local_z)
		if here_id == Blocks.AIR:
			scan_y += 1
			continue
		if not Blocks.has_gravity(here_id):
			return  # any non-gravity solid stops the cascade upward
		# Vanilla clears the source on the entity's first tick; same
		# end state, simpler bookkeeping to do it now.
		chunk.set_block(local_x, scan_y, local_z, Blocks.AIR)
		# Force an immediate remesh of the source chunk. Without this, the
		# chunk's own _process would pick up `dirty` next frame — but the
		# FallingBlock entity is added to the scene *this* frame at the exact
		# center of the just-cleared cell, so both render at the same spot
		# for one frame and z-fight, which the user sees as a flicker at the
		# start of the fall. Same issue for sand and gravel — same path.
		# Sync path because async dispatch reintroduces the 1-frame flicker.
		var chunk_node: Node3D = _chunks[coord]
		chunk_node.rebuild_mesh_immediate()
		_spawn_falling_block(Vector3i(world_x, scan_y, world_z), here_id)
		scan_y += 1


func _spawn_falling_block(world_pos: Vector3i, block_id: int) -> void:
	var fb := FallingBlock.new()
	fb.setup(block_id)
	add_child(fb)
	fb.global_position = Vector3(world_pos) + Vector3(0.5, 0.5, 0.5)


# Vanilla BlockPlant.e(world,i,j,k): if the support block is no longer
# valid, set the plant cell to AIR and drop the plant's item. We bound
# y by the chunk and only act when the cell holds a cross-quad shape —
# generalizes cleanly to torches/levers/buttons later, all of which use
# the same "support broke → pop off → drop self" pattern. local_y is
# the cell ABOVE the just-modified support; bail if it's out of range.
func _drop_plant_if_unsupported(coord: Vector2i, local_x: int, local_y: int, local_z: int) -> void:
	if local_y < 0 or local_y >= Chunk.SIZE_Y:
		return
	var chunk: Chunk = _chunks[coord].chunk
	var here_id: int = chunk.get_block(local_x, local_y, local_z)
	# Only cross-quad plants pop off on support change. Cubes (dirt on
	# stone, etc.) stay put. Future torches/levers will need a separate
	# attachment-shape check.
	if Blocks.mesh_shape(here_id) != Blocks.MESH_SHAPE_CROSS:
		return
	# Drop AIR over it via set_world_block so chunk dirty + persistence
	# bookkeeping fire the same as a player edit. The recursive call is
	# safe: AIR is a valid plant support test (false), so the cell above
	# the now-empty plant cell only sees a no-op (cross-quad above an
	# air column isn't a configuration we ever produce).
	var world_x: int = coord.x * Chunk.SIZE_X + local_x
	var world_z: int = coord.y * Chunk.SIZE_Z + local_z
	var plant_pos := Vector3i(world_x, local_y, world_z)
	set_world_block(plant_pos, Blocks.AIR)
	var dropped_id: int = Blocks.drops(here_id)
	if dropped_id != Blocks.AIR:
		_spawn_dropped_item(plant_pos, dropped_id)


# Mirrors interaction.gd._spawn_dropped_item. Local copy here so the
# detach path doesn't have to round-trip through the Player node, which
# may not exist (e.g. respawn frame) when the drop fires.
func _spawn_dropped_item(block_pos: Vector3i, dropped_id: int) -> void:
	var item := DroppedItem.new()
	add_child(item)
	item.global_position = Vector3(block_pos) + Vector3(0.5, 0.5, 0.5)
	item.setup(dropped_id)


# Schedule a sapling for a future growth tick. Same exponential-delay
# shape as leaf decay — most saplings grow within the mean, a few linger
# for several minutes. Vanilla random-tick rate is "one chance per random
# tick (rand(7)==0) when light >= 9"; the practical mean is ~1–5 minutes,
# which we approximate here.
func _enqueue_sapling_growth(pos: Vector3i) -> void:
	var u: float = maxf(randf(), 0.0001)
	var delay: float = clampf(
		-_SAPLING_GROW_MEAN_SEC * log(u), _SAPLING_GROW_MIN_SEC, _SAPLING_GROW_MAX_SEC
	)
	var now: float = Time.get_ticks_msec() / 1000.0
	_growing_saplings.append({"pos": pos, "grow_at": now + delay})


# Drain expired sapling-growth entries. For each one, re-check that the
# cell still holds a sapling, the support is still valid, and there's
# sky exposure (proxy for vanilla light >= 9 until lighting propagation
# lands). On success: place an oak tree centered at the sapling's cell.
# On a "blocked but still a sapling" outcome: re-queue with retry delay
# — vanilla just no-ops the random tick and rolls again later. Per-tick
# cap so a million simultaneous growths don't stall the main thread.
func _tick_sapling_growth() -> void:
	if _growing_saplings.is_empty():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var processed: int = 0
	for i in range(_growing_saplings.size() - 1, -1, -1):
		var entry: Dictionary = _growing_saplings[i]
		if entry.grow_at > now:
			continue
		_growing_saplings.remove_at(i)
		var pos: Vector3i = entry.pos
		var here_id: int = get_world_block(pos)
		if here_id != Blocks.SAPLING:
			# Player broke it (or it was overwritten by another block).
			processed += 1
			if processed >= _SAPLING_GROW_MAX_PER_TICK:
				return
			continue
		var support_id: int = get_world_block(pos + Vector3i(0, -1, 0))
		var support_ok: bool = Blocks.is_valid_plant_support(support_id)
		var sky_ok: bool = _is_sky_exposed(pos)
		if not support_ok:
			# Detach hook will (or did) fire from set_world_block; nothing
			# more to do here — let the sapling drop normally.
			processed += 1
			if processed >= _SAPLING_GROW_MAX_PER_TICK:
				return
			continue
		if not sky_ok:
			# Sheltered — no growth this round, try again later.
			_growing_saplings.append({"pos": pos, "grow_at": now + _SAPLING_GROW_RETRY_SEC})
			processed += 1
			if processed >= _SAPLING_GROW_MAX_PER_TICK:
				return
			continue
		grow_tree_at(pos)
		processed += 1
		if processed >= _SAPLING_GROW_MAX_PER_TICK:
			return


# Public entry point — also called by the bonemeal item once it lands.
# Replaces the sapling at `pos` with an oak tree (4–6 block trunk + 4
# canopy layers, matching worldgen). Caller is responsible for any
# pre-checks (support, sky exposure); this just paints the blocks.
func grow_tree_at(pos: Vector3i) -> void:
	# Trunk height + canopy variation are randomized per growth, matching
	# worldgen's range. Not deterministic across save/restore — vanilla
	# saplings don't reproduce the same tree shape if you wait again.
	var trunk_height: int = 4 + (randi() % 3)
	var t_hash: int = randi()
	var get_cb := func(p: Vector3i) -> int: return get_world_block(p)
	var set_cb := func(p: Vector3i, id: int) -> void: set_world_block(p, id)
	Worldgen.place_oak_tree(pos, trunk_height, t_hash, get_cb, set_cb)


# Vanilla growth requires light >= 9. We don't have lighting propagation
# yet, so use sky exposure as a proxy: walk up from pos+1 to SIZE_Y-1;
# if any opaque non-leaf block is in the way, the sapling is sheltered
# and shouldn't grow. Leaves count as transparent so a sapling under a
# tree's own canopy still reads as exposed (vanilla's BlockLeaves passes
# light through with a small attenuation; our sky-only proxy can't model
# that, so leaves stay non-blocking).
func _is_sky_exposed(pos: Vector3i) -> bool:
	for y in range(pos.y + 1, Chunk.SIZE_Y):
		var id: int = get_world_block(Vector3i(pos.x, y, pos.z))
		if id == Blocks.AIR or id == Blocks.LEAVES:
			continue
		if Blocks.is_opaque(id):
			return false
	return true


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


# World-coord block-metadata read. Used by BlockFluids to read flow level
# (0..7 spread, 8..15 falling) across chunk boundaries. Returns 0 for
# unloaded chunks — matches Chunk.get_block_meta's OOB rule.
func get_world_block_meta(world_pos: Vector3i) -> int:
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return 0
	var local_x: int = world_pos.x - chunk_x * Chunk.SIZE_X
	var local_z: int = world_pos.z - chunk_z * Chunk.SIZE_Z
	var chunk_node: Node3D = _chunks[coord]
	return chunk_node.chunk.get_block_meta(local_x, world_pos.y, local_z)


# World-coord setter that writes both block id and metadata in one call.
# Routes through set_world_block for all the side-effects (lighting, dirty,
# persistence, gravity, plant detach) and then overrides the meta, since
# set_world_block zeros meta by vanilla parity. Used by BlockFluids to
# place flowing fluid cells at specific levels.
func set_world_block_with_meta(world_pos: Vector3i, id: int, meta: int) -> void:
	set_world_block(world_pos, id)
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return
	var local_x: int = world_pos.x - chunk_x * Chunk.SIZE_X
	var local_z: int = world_pos.z - chunk_z * Chunk.SIZE_Z
	var chunk_node: Node3D = _chunks[coord]
	chunk_node.chunk.set_block_meta(local_x, world_pos.y, local_z, meta)


# World-coord sky-light read. Returns 15 (`Chunk.get_sky_light`'s OOB
# convention; vanilla EnumSkyBlock.SKY default) when the chunk is
# unloaded or y is out of range. Used by Lighting's bounded BFS so it
# can read across chunk borders without crashing.
func get_world_sky_light(world_pos: Vector3i) -> int:
	if world_pos.y < 0 or world_pos.y >= Chunk.SIZE_Y:
		return 15
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return 15
	var local_x: int = world_pos.x - chunk_x * Chunk.SIZE_X
	var local_z: int = world_pos.z - chunk_z * Chunk.SIZE_Z
	return _chunks[coord].chunk.get_sky_light(local_x, world_pos.y, local_z)


# World-coord sky-light write. No-op if the chunk isn't loaded — the
# bounded BFS only writes inside its loaded box; cells in unloaded chunks
# remain at the OOB default. Marks the touched chunk dirty so the next
# process tick re-meshes with the new lighting (see chunk_node._process).
# Also marks the chunk for persistence so the new sky_light survives the
# next unload/reload cycle (the player has effectively edited it).
func set_world_sky_light(world_pos: Vector3i, value: int) -> void:
	if world_pos.y < 0 or world_pos.y >= Chunk.SIZE_Y:
		return
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return
	var local_x: int = world_pos.x - chunk_x * Chunk.SIZE_X
	var local_z: int = world_pos.z - chunk_z * Chunk.SIZE_Z
	var chunk: Chunk = _chunks[coord].chunk
	if chunk.get_sky_light(local_x, world_pos.y, local_z) == value:
		return
	chunk.set_sky_light(local_x, world_pos.y, local_z, value)
	chunk.dirty = true
	_dirty_loaded[coord] = true


# World-coord block-light read. Returns 0 (`Chunk.get_block_light`'s OOB
# convention; vanilla EnumSkyBlock.BLOCK default — no torches in unknown
# chunks) when the chunk is unloaded or y is out of range. Used by
# Lighting's bounded BFS for the torch/lava channel so it can read across
# chunk borders without crashing.
func get_world_block_light(world_pos: Vector3i) -> int:
	if world_pos.y < 0 or world_pos.y >= Chunk.SIZE_Y:
		return 0
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return 0
	var local_x: int = world_pos.x - chunk_x * Chunk.SIZE_X
	var local_z: int = world_pos.z - chunk_z * Chunk.SIZE_Z
	return _chunks[coord].chunk.get_block_light(local_x, world_pos.y, local_z)


# World-coord block-light write. Same plumbing as set_world_sky_light:
# no-op on unloaded chunks (BFS only writes inside loaded box), marks the
# touched chunk dirty + flagged for persistence. Used by both the edit-time
# update_block_light_around_world BFS (when a torch is placed/broken) and
# the chunk-load relight_chunk_borders pass (when a chunk loads next to
# one with existing emitters).
func set_world_block_light(world_pos: Vector3i, value: int) -> void:
	if world_pos.y < 0 or world_pos.y >= Chunk.SIZE_Y:
		return
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return
	var local_x: int = world_pos.x - chunk_x * Chunk.SIZE_X
	var local_z: int = world_pos.z - chunk_z * Chunk.SIZE_Z
	var chunk: Chunk = _chunks[coord].chunk
	if chunk.get_block_light(local_x, world_pos.y, local_z) == value:
		return
	chunk.set_block_light(local_x, world_pos.y, local_z, value)
	chunk.dirty = true
	_dirty_loaded[coord] = true


# World-coord sky-exposed query — routes to the right chunk's cached
# heightmap (Chunk.is_sky_exposed → vanilla ha.java canSeeSkyAt). True for
# unloaded chunks (vanilla "unknown = fully sky-exposed" convention).
# O(1) per call once the heightmap is built.
func is_sky_exposed_at_world(world_pos: Vector3i) -> bool:
	if world_pos.y < 0 or world_pos.y >= Chunk.SIZE_Y:
		return world_pos.y >= Chunk.SIZE_Y
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return true
	var local_x: int = world_pos.x - chunk_x * Chunk.SIZE_X
	var local_z: int = world_pos.z - chunk_z * Chunk.SIZE_Z
	return (_chunks[coord].chunk as Chunk).is_sky_exposed(local_x, world_pos.y, local_z)


# Direct chunk accessor for the C++ lighting fast-path. Returns the
# Chunk RefCounted (containing blocks/sky_light/height_map arrays) or
# null if the chunk isn't loaded. Used by Lighting._update_sky_light_around_world_native
# to marshal up to 9 chunks' raw arrays into the BFS.
func get_chunk_at_coord(coord: Vector2i) -> Chunk:
	if not _chunks.has(coord):
		return null
	return _chunks[coord].chunk


# Called by Lighting after the C++ BFS has written modified sky_light back
# into a chunk. Mirrors what set_world_sky_light does for the per-cell
# GDScript path: mark dirty for re-mesh + persistence. Single notification
# per chunk replaces N per-cell calls; cuts overhead noticeably for the
# bulk-write fast path.
# chunk_node asks before each _apply_mesh_data; false → hold the result
# for next frame. Spreads multi-chunk apply bursts over multiple frames.
func try_consume_apply_budget() -> bool:
	if _applies_this_frame >= apply_budget_per_frame:
		return false
	_applies_this_frame += 1
	return true


func notify_chunk_lighting_updated(coord: Vector2i) -> void:
	if not _chunks.has(coord):
		return
	var chunk: Chunk = _chunks[coord].chunk
	chunk.dirty = true
	_dirty_loaded[coord] = true


# Lava→obsidian/cobble conversion FX — fizz SFX + 8 largesmoke puffs.
# Impl lives in FluidFx (scripts/world/fluid_fx.gd); this thin wrapper
# stays so BlockFluids can call `manager.spawn_fluid_fizz(pos)` without
# knowing about the helper class.
func spawn_fluid_fizz(pos: Vector3i) -> void:
	if _light_defer_depth > 0:
		_deferred_fizz.append(pos)
		return
	FluidFx.spawn_fizz(self, pos)


# --- Fluid flow hooks (Flow #3) ---


# Called whenever a block changes at `pos`. Demotes any STILL fluid in
# the 6-cell neighborhood + center to FLOWING so the spread algorithm
# re-checks. Mirrors vanilla World.applyPhysics fanning out to 6 neighbors
# after any setBlock, where each fluid's ir.java receives the neighborChange
# callback and converts itself.
func _notify_fluid_neighbors(pos: Vector3i) -> void:
	if _inside_fluid_notify:
		# Nested call from a set_world_block triggered inside the fanout.
		# The outer loop will finish; inner re-notifying is redundant
		# because each cell it touches is already in the outer's scope
		# or will be visited in the next tick's spread phase.
		return
	_inside_fluid_notify = true
	_light_defer_depth += 1
	for offset: Vector3i in [
		Vector3i(0, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1)
	]:
		BlockFluids.on_neighbor_changed(self, pos + offset)
	_light_defer_depth -= 1
	_inside_fluid_notify = false
	# Drain at depth 0: dedup sky-light BFS seeds, coalesce fizz cluster.
	# Vanilla's ld.java:256-261 `i()` fires per-cell, but collapsed into
	# one applyPhysics frame the audible result is one fizz anyway.
	if _light_defer_depth == 0:
		FluidFx.flush_deferred(self, _deferred_sky_seeds, _deferred_fizz)
		_deferred_sky_seeds.clear()
		_deferred_fizz.clear()


# Called when a fluid is freshly placed at `pos`. Ensures a first tick
# is scheduled — without this, a placed source block would never spread
# outward until something else nudged the system.
func _schedule_fluid_tick(pos: Vector3i, block_id: int) -> void:
	# Still variants don't tick (they only react to neighbor change) —
	# flip them to flowing first, which schedules automatically.
	if block_id == Blocks.WATER_STILL or block_id == Blocks.LAVA_STILL:
		BlockFluids.on_neighbor_changed(self, pos)
		return
	var rate: int = (
		BlockFluids.WATER_TICK_RATE if Blocks.is_water(block_id) else BlockFluids.LAVA_TICK_RATE
	)
	TickScheduler.schedule(pos, block_id, rate)
