# gdlint: disable=max-public-methods
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
const _SAVE_LOAD: GDScript = preload("res://scripts/persistence/save_load.gd")
# preload() instead of the class_name to dodge the editor class-index
# lag that bites new class_name registrations on first reload (same
# workaround as `_TICK_SCHEDULER` above).
const _PASSIVE_SPAWNER_SCRIPT: GDScript = preload("res://scripts/world/passive_spawner.gd")
# preload rather than class_name: PortalRenderer is new enough that the
# editor class index lags a reload behind, same as _BLOCK_FX above.
const _PORTAL_RENDERER: GDScript = preload("res://scripts/world/portal_renderer.gd")
# Redstone-triggered TNT ignition. Preload (not class_name) for the same
# editor-index reason as the scripts above.
const _PRIMED_TNT_SCRIPT: GDScript = preload("res://scripts/world/primed_tnt.gd")

# --- Block-update notification fanout (redstone-plan.md §7.2) ---
# The changed cell plus its 6 neighbours, matching vanilla
# World.applyPhysics.
const _NOTIFY_OFFSETS: Array[Vector3i] = [
	Vector3i(0, 0, 0),
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]
# Ceiling on positions dispatched per drain. A pathological network
# pauses and resumes next frame rather than stalling the frame; sized
# well above any hand-built Alpha circuit (there are no repeaters or
# pistons to build a large clock out of).
const _NOTIFY_BUDGET_PER_DRAIN: int = 4096
# Key under which an entity's last contact cell is cached, so
# `report_entity_contact` fires only on arrival. Node metadata rather
# than a member on each entity script: four unrelated entity types need
# it and none of them share a base class.
const _CONTACT_CELL_META: StringName = &"_block_contact_cell"
const _AUTOSAVE_INTERVAL_SEC: float = 300.0
# World-entry drain-boost window (see _entry_boost_until_msec).
const _ENTRY_BOOST_WINDOW_MSEC: int = 12000
const _AUTOSAVE_INDICATOR_VISIBLE_SEC: float = 3.0
const _AUTOSAVE_INDICATOR_FONT_SIZE: int = 22

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

# Workers can crash silently (uncaught exception, propagate_notification
# race on Node-creating noise constructors, etc.) and never write
# `_ready_results` → coord stays in `_pending` forever → chunk never
# materializes → visible 16×16 black void in the world. Reap stale
# entries each frame and re-enqueue them. 30s is generous (typical
# chunk gen ~30 ms).
const _PENDING_TIMEOUT_MS: int = 30000
# Retry delay when growth is blocked (no sky exposure yet).
const _SAPLING_GROW_RETRY_SEC: float = 30.0
const _SAPLING_GROW_MAX_PER_TICK: int = 4
# Sugar cane growth — vanilla BlockReed.b() ticks the meta counter on
# every random tick (~1/(16 × 16 × 16 × 4) per chunk per tick) and
# grows one block when meta hits 15. We compress that into a single
# delay between growth attempts; 60-180 s mirrors the rough vanilla
# wall-clock cadence (random tick rate × 16 ticks per growth).
const _CANE_GROW_MEAN_SEC: float = 90.0
const _CANE_GROW_MIN_SEC: float = 60.0
const _CANE_GROW_MAX_SEC: float = 180.0
const _CANE_GROW_RETRY_SEC: float = 60.0
const _CANE_GROW_MAX_PER_TICK: int = 4
const _CANE_MAX_HEIGHT: int = 3

@export var render_distance: int = 8
@export var chunk_scene: PackedScene
@export var player_path: NodePath = ^"../Player"
# 3 is the sweet spot on 8-core machines: enough to keep the chunk ring fed
# while flying at normal speeds, but leaves 4+ cores free for the main
# thread + render thread. Was 8 — caused FPS spikes down to 4-7 in new
# biomes because cave-gen workers (60 ms+ each in GDScript) burned every
# core, starving the main thread of scheduler time. Frame-time breakdown
# in those spikes showed ~90 ms of "other" (render + scheduler waits) on
# top of script-time ~50 ms. Dropping the cap lets workers finish in waves
# instead of all at once; per-frame budget stabilizes.
@export var max_concurrent_jobs: int = 3
# Cap on _apply_mesh_data calls per frame. Each apply = up to 3 ArrayMesh
# VBOs + trimesh; stacking them on one frame caused 120→70 fps spikes.
@export var apply_budget_per_frame: int = 1
# Chebyshev radius of the live-physics ring around the player. Saves
# ~1-2 MB × outer chunks of trimesh + BVH at FAR.
@export var collision_radius: int = 1

# Cumulative count of chunks fully materialized this session — never
# decremented when chunks unload. Read by the debug stats panel.
var chunks_generated_total: int = 0
# Worker results discarded because their dimension/epoch no longer
# matches the resident world. Surfaced in the debug overlay and
# asserted by tests/test_dimension_context.gd — a transition that
# leaks work shows up here rather than as corrupted terrain.
var stale_results_rejected: int = 0
# Non-reentrancy guard for transition_to_dimension. A transition that
# re-entered would free the scene it is mid-way through rebuilding.
var _in_dimension_transition: bool = false

var _player: Node3D
# Draws + animates every resident portal cell. Owned here because it
# reads blocks through this manager and has to survive a dimension
# switch (its contents do not — see transition_to_dimension).
var _portal_renderer: Node3D = null
var _chunks: Dictionary = {}  # Vector2i → Node3D (ChunkNode)
# Natural-spawning driver — Alpha bg.java port + Beta worldgen-spawn
# pass. Ticks at 20 Hz from `_process` for ongoing spawns;
# populate_chunk_at_gen() runs once per fresh chunk for the seed pass.
var _passive_spawner: RefCounted = _PASSIVE_SPAWNER_SCRIPT.new()
var _pending: Dictionary = {}  # Vector2i → dispatch_time_ms (currently being computed)
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
# Deferred relight-dispatch queue. _materialize_chunk used to call
# _dispatch_relight inline, which paid a 1-3 ms snapshot cost
# (prepare_relight_data: 5 chunks × 4 PackedByteArray.duplicate()) on
# the same frame as scene instantiate + add_child + 7 child node
# _ready calls. That stacked the materialize probe to 11-12 ms p95, over
# the 11.1 ms budget at 90 fps. Queueing the dispatch and popping one
# per frame from `_process` spreads the cost across consecutive frames.
var _pending_relight_dispatch: Array[Vector2i] = []
var _pending_relight_dispatch_set: Dictionary = {}  # dedupe
# Player-edited chunks compressed on unload, restored on re-entry.
# Shape: coord → { bytes, block_meta, sky_light, block_light, height_map,
# max_y, pending_ticks }, all FastLZ-compressed; ~50:1 on above-ground edits.
var _saved_chunks: Dictionary = {}
var _dirty_loaded: Dictionary = {}  # loaded edited chunks awaiting persist-on-unload
# Nodes outside the active ring whose last uploaded mesh remains briefly as a
# visual backing shell while surviving neighbors rebuild exposed edge faces.
# Retirees are absent from `_chunks`, so gameplay and lighting already treat
# them as unloaded. Shape: coord → {node, gates:[{coord,node,apply_revision}]}.
var _retiring_chunks: Dictionary = {}
# Orphaned leaves / saplings awaiting a timed callback. Entries:
#   _decaying_leaves: { pos, decay_at } — exponential delay; logs within
#     the grace window abort decay. Alpha random-tick approximation.
#   _growing_saplings: { pos, grow_at } — sky-exposure checked at grow
#     time (proxy for Alpha's light≥9), re-queues if blocked.
var _decaying_leaves: Array = []
var _growing_saplings: Array = []
# Sugar cane growth queue. Entries: { pos, grow_at }. Only the TOP cane
# of each column is enqueued (lower canes can't grow). On growth, the
# new top cell is enqueued; if blocked (column at max height, no air
# above, support gone) we re-queue with a longer delay.
var _growing_canes: Array = []
# Guard: prevents recursive STILL-water cell cascades via set_world_block
# from inside on_neighbor_changed. See BlockFluids for the fanout shape.
var _inside_fluid_notify: bool = false

# --- Block-update notification queue (redstone-plan.md §7.2) ---
# Queue + membership set (see _NOTIFY_OFFSETS above) so a cascade
# (lever → wire → wire → …) converges without recursion or lost events.
#
# Entries are Vector4i(x, y, z, source_id): the cell to notify plus the
# id of the block whose change caused it, which is vanilla's `n5`
# argument to onNeighborBlockChange. TNT (v.java:23) and rail junctions
# (jn.java:89) both refuse to act unless that source can provide power,
# so the id has to survive the queue. Dedup is on the whole pair — two
# different sources touching one cell are two different events.
var _notify_queue: Array[Vector4i] = []
var _notify_queued: Dictionary = {}
var _notify_draining: bool = false
# Vanilla `cy.i` (editingBlocks) — true while a multi-block structure is
# being written cell by cell, so no neighbour update can observe it
# half-built. x.java:65-71 brackets the portal fill with it and
# no.java:202-212 brackets portal construction; without it, the portal's
# own per-cell self-validation fired synchronously on the FIRST written
# cell — a one-tall column, invalid by definition — and erased every
# cell the moment it was born. The sheet never existed: walkable,
# invisible, no travel. Every unit test passed because FakeWorld doubles
# have no notification cascade.
var _editing_blocks: bool = false

# Per-world redstone-torch burnout entries ({pos, tick}); see
# redstone_burnout_log().
var _redstone_burnout_log: Array = []
# Deferred sky/block-light seeds + fizz during batch edits and fluid
# fanouts. The outermost unwind performs one multi-source pass per channel.
var _light_defer_depth: int = 0
var _deferred_sky_seeds: Dictionary = {}  # Vector3i → true
var _deferred_block_seeds: Dictionary = {}  # Vector3i → true
var _deferred_fizz: Array = []
# Frame-coalesced immediate-rebuild dedup. set_world_block_immediate
# accumulates chunk coords here; call_deferred flushes each unique
# chunk once per frame. See set_world_block_immediate for context.
var _pending_immediate_rebuild: Dictionary = {}
# Last player chunk we ran _update_collision_activity against. Skip the
# sweep until the player actually crosses a chunk boundary.
var _last_collision_center: Vector2i = Vector2i(2147483647, 2147483647)
var _applies_this_frame: int = 0  # reset each _process; see try_consume_apply_budget
# Ambient scanner timer — drives AmbientFx.tick at 10 Hz. Vanilla's
# cy.java randomDisplayTick runs per-frame; we sample less often.
var _ambient_scan_accum: float = 0.0
# Mobile web: 5 Hz ambient + tick load-shedding while chunks stream in.
# Cached once in _ready — the platform can't change mid-session.
var _is_mobile_web: bool = false
# Frames left to skip the fixed-cadence ticks (ambient scan + scheduled/
# random block ticks) after a chunk apply consumed the frame budget.
# A 6×-throttled phone proxy measured chunk_node.apply at 5-18 ms p95;
# stacking the ~9 ms of fixed ticks onto those same frames is what pushed
# streaming-while-walking under the 30 fps floor. The accumulators catch
# up on the next quiet frame (TickScheduler clamps catch-up at 2), so
# shedding costs a frame of growth/particle latency at most. Only ever
# set on mobile web — desktop frame composition is untouched.
var _shed_tick_frames: int = 0
# Scheduler delta banked across shed frames (see _process) so skipped
# frames still count toward the 20 Hz game-tick accumulator.
var _shed_sched_delta: float = 0.0
# World-entry drain boost deadline (ticks msec; 0 = inactive). The
# initial ring's neighbor re-mesh + border-relight waves land right
# after the loading screen drops — every materialized chunk dirties its
# loaded neighbors once for edge-culling/light seams, and relights
# drain 1/frame. On desktop web's 81-chunk ring that measured ~2 s of
# 8-40 fps immediately post-spawn before settling at 60. While boosted,
# the apply budget triples and relight drains double, clearing the
# backlog ~3× faster; steady-state budgets are untouched afterward.
# Mobile web keeps flat budgets — its ring is 25 chunks (small wave)
# and per-apply frame cost is its scarcest resource.
var _entry_boost_until_msec: int = 0
# Spiral-offsets cache + spawn-queue membership set: rebuilding the 1088
# offset array + sorting every frame at FAR cost ~1-2 ms; O(n) _spawn_queue.has
# inside the 1089-iteration loop compounds. Both keyed off render_distance.
var _spiral_offsets_cache: Array = []
var _spiral_offsets_r: int = -1
var _spawn_queue_set: Dictionary = {}
var _last_chunk_set_coord: Vector2i = Vector2i(2147483647, 2147483647)
var _cached_player_chunk: Vector2i = Vector2i.ZERO
# Center of the initial chunk-ring at world entry. Defaults to (0,0) for
# fresh worlds; ChunkManager._ready overwrites it from PlayerSave.peek
# so saved worlds load chunks around the player's destination.
var _initial_load_center: Vector2i = Vector2i.ZERO

# Autosave (step 7.4 — BETA exception per .claude/pre-mob-roadmap.md).
# Alpha 1.2.6 had no autosave — saved only on pause menu open + save-
# and-quit (jl.java + cy.java:250). Constants live at the top with the
# rest; the timer / label / session start live here.
var _autosave_timer: Timer
var _autosave_label: Label
# Wall-clock at session start, used to add session duration to the
# cumulative play_time_seconds field in world.json each autosave.
var _session_start_msec: int = 0


func _entry_boost_active() -> bool:
	if _is_mobile_web:
		return false
	# Never boost while the LoadingScreen is up — its per-frame
	# synchronous chunk gen is already the heaviest work in the session,
	# and stacking extra applies/relights onto those frames measurably
	# stretched total load time on heavy-biome seeds. Arm the window on
	# the first post-loading frame instead: the deferred wave then
	# drains at triple rate exactly when the player starts watching.
	if Game.is_loading:
		return false
	if _entry_boost_until_msec == 0:
		_entry_boost_until_msec = Time.get_ticks_msec() + _ENTRY_BOOST_WINDOW_MSEC
	return Time.get_ticks_msec() < _entry_boost_until_msec


func _ready() -> void:
	# Scope the diagnostic event log to this world session. ChunkManager
	# is the first node in the world scene (before Player), so resetting
	# here captures every subsequent load / spawn / recovery event.
	DebugLog.reset()
	_player = get_node_or_null(player_path) as Node3D
	_is_mobile_web = Game.is_mobile_web()
	if _is_mobile_web:
		# Phones have cores to spare (typically 8) while the MAIN thread
		# is the scarce resource — a deeper worker pool shrinks the
		# leading-edge pop-in ring while walking (reported as "missing
		# map, slow to load in"). The desktop cap stays 3 (see the
		# @export comment: cave-gen workers starved the main thread on
		# 8-core desktops at 8 workers; 5 is safe on mobile because the
		# per-worker chunks are also ~3× slower there, arriving spread).
		max_concurrent_jobs = 5
	# Wipe leftover tile-entity state from any prior world load in this
	# same engine process. Without this, the autoload Dictionaries keep
	# entries from World 1 when the player picks World 2 from the menu.
	# Most at-risk are WORLDGEN-placed tile entities (dungeon chests +
	# spawners today; mineshaft / village chests if/when added) — their
	# chunks may evict non-dirty and skip `forget_chunk`, leaving stale
	# entries indefinitely. If a coord collides between worlds, the new
	# world's chest would inherit the old world's loot via
	# `get_or_create`. Player-placed TEs are normally safe (their
	# chunks dirty on edit), but we wipe everything for uniformity.
	_clear_dimension_owned_state()
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
	_setup_autosave()
	# Push live foliage-tint updates to every loaded chunk + the overlay /
	# entity materials when the player toggles "Alpha 1.1.2 foliage" in
	# Settings. ChunkNode applies its per-instance pair at mesh-build, but
	# already-loaded chunks need the explicit re-push or the change won't
	# show up without a relog. See BlockAtlas.grass_tint / leaves_tint.
	Game.alpha_vintage_foliage_changed.connect(_on_alpha_vintage_foliage_changed)
	# Peek at the saved player position to pick where the initial chunk
	# ring lands. Without this, ChunkManager always spawns chunks around
	# (0,0) even when PlayerSave will teleport the player thousands of
	# blocks away — the teleport then lands in unloaded space and the
	# player falls through the world before the per-frame chunk loader
	# catches up. ZERO fallback covers fresh worlds + corrupt saves.
	# Peek the saved DIMENSION before the position, and before the ring is
	# built: a player saved in the Nether needs the Nether's provider
	# selected so the initial chunks come from the right generator and the
	# right region directory. v1 saves and fresh worlds answer Overworld.
	DimensionContext.set_active(PlayerSave.peek_dimension())
	# Portal hints for the resident dimension. Must follow set_active, and
	# must precede anything that could search for a portal.
	#
	# reset() first because this is world ENTRY: the static index would
	# otherwise carry World 1's portals into World 2, the same way the
	# tile-entity singletons would (see _clear_dimension_owned_state
	# above). load_index merges rather than clobbers, deliberately, so
	# this is the only place the slate gets wiped.
	PortalIndex.reset()
	PortalIndex.load_index()
	_portal_renderer = _PORTAL_RENDERER.new()
	_portal_renderer.name = "PortalRenderer"
	add_child(_portal_renderer)
	_portal_renderer.set_world(self)
	var saved_pos: Variant = PlayerSave.peek_position()
	if saved_pos is Vector3:
		var p: Vector3 = saved_pos as Vector3
		_initial_load_center = Vector2i(
			int(floor(p.x / float(Chunk.SIZE_X))), int(floor(p.z / float(Chunk.SIZE_Z)))
		)
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
	_spawn_chunk_sync(_initial_load_center)
	loaded += 1
	initial_chunks_ready.emit(loaded, total)
	# Spiral-out by squared distance so the player-ring lands first.
	# Offsets are relative; add _initial_load_center so the ring centers
	# on the saved player chunk (or (0,0) for fresh worlds).
	var order: Array = ChunkView.spiral_offsets(render_distance)
	for c: Vector2i in order:
		await get_tree().process_frame
		_spawn_chunk_sync(c + _initial_load_center)
		loaded += 1
		initial_chunks_ready.emit(loaded, total)
	Music.start_music()


func _process(_delta: float) -> void:
	if _player == null:
		return
	var probe_token := PerfProbe.begin("chunk_mgr.tick")
	_cached_player_chunk = _player_chunk_coord()
	_applies_this_frame = 0
	# Sub-probes: each step in _process gets its own ring so we can
	# isolate the 80+ ms tick spikes without guessing. Lightweight —
	# Time.get_ticks_usec is one syscall per begin/end and the ring
	# write is ~50 ns. Total overhead ~1-2 µs per frame.
	# Resume any block-update fanout that hit its per-drain budget last
	# frame. No-op (one array check) when the queue is empty, which is
	# the case for every frame that isn't mid-cascade.
	if not _notify_queue.is_empty():
		drain_block_notifications()
	# Same deal one level down: a wire burst too large for a single frame
	# pauses with its worklist intact and resumes here. Its deferred
	# zero-crossing notifications only reach the queue above once the
	# network has actually settled, so no consumer sees a half-lit line.
	if Redstone.has_pending_wire_work():
		var t_wire := PerfProbe.begin("redstone.update")
		Redstone.drain_wire_work(self, Redstone.WIRE_STEPS_PER_DRAIN, Redstone.WIRE_USEC_PER_DRAIN)
		PerfProbe.end("redstone.update", t_wire)
	_sweep_player_block_contact()
	var t_set := PerfProbe.begin("chunk_mgr.tick.update_chunk_set")
	_update_chunk_set()
	_drain_retiring_chunks()
	PerfProbe.end("chunk_mgr.tick.update_chunk_set", t_set)
	var t_coll := PerfProbe.begin("chunk_mgr.tick.collision_activity")
	_update_collision_activity()
	PerfProbe.end("chunk_mgr.tick.collision_activity", t_coll)
	var t_reap := PerfProbe.begin("chunk_mgr.tick.reap_pending")
	_reap_stale_pending()
	PerfProbe.end("chunk_mgr.tick.reap_pending", t_reap)
	var t_disp := PerfProbe.begin("chunk_mgr.tick.dispatch_workers")
	_dispatch_workers()
	PerfProbe.end("chunk_mgr.tick.dispatch_workers", t_disp)
	var t_mat := PerfProbe.begin("chunk_mgr.tick.materialize_one")
	_materialize_one_ready_chunk()
	PerfProbe.end("chunk_mgr.tick.materialize_one", t_mat)
	var t_relight_disp := PerfProbe.begin("chunk_mgr.tick.relight_dispatch")
	_drain_one_relight_dispatch()
	PerfProbe.end("chunk_mgr.tick.relight_dispatch", t_relight_disp)
	var t_relight_drain := PerfProbe.begin("chunk_mgr.tick.relight_drain")
	_drain_relight_results()
	PerfProbe.end("chunk_mgr.tick.relight_drain", t_relight_drain)
	# Load-shed window: right after a chunk apply, skip this frame's
	# ambient scan + block-tick pass (mobile web only — the flag is only
	# ever set there; see _shed_tick_frames). Skipped scheduler time is
	# banked in _shed_sched_delta so game-tick timing doesn't drift.
	var shed_this_frame: bool = _shed_tick_frames > 0
	if shed_this_frame:
		_shed_tick_frames -= 1
	_ambient_scan_accum += _delta
	# 5 Hz on mobile web (measured 3.5 ms/scan on a low-end phone proxy
	# even at the reduced 250-cell budget); 10 Hz everywhere else.
	var ambient_interval: float = 0.2 if _is_mobile_web else 0.1
	if not shed_this_frame and _ambient_scan_accum >= ambient_interval:
		_ambient_scan_accum = 0.0
		var t_ambient := PerfProbe.begin("chunk_mgr.tick.ambient")
		AmbientFx.tick(self, _chunks, _player.global_position)
		PerfProbe.end("chunk_mgr.tick.ambient", t_ambient)
	var t_leaf := PerfProbe.begin("chunk_mgr.tick.leaf_decay")
	_tick_leaf_decay()
	PerfProbe.end("chunk_mgr.tick.leaf_decay", t_leaf)
	var t_sap := PerfProbe.begin("chunk_mgr.tick.sapling_growth")
	_tick_sapling_growth()
	PerfProbe.end("chunk_mgr.tick.sapling_growth", t_sap)
	var t_cane := PerfProbe.begin("chunk_mgr.tick.cane_growth")
	_tick_cane_growth()
	PerfProbe.end("chunk_mgr.tick.cane_growth", t_cane)
	# Natural mob spawning — Alpha bg.java port. Driven from the main
	# tick loop so the spawner sees a consistent player position +
	# loaded-chunk set each frame. The spawner has its own 20 Hz
	# accumulator so this call is cheap on most frames (just an add +
	# threshold check).
	var t_spawn := PerfProbe.begin("chunk_mgr.tick.mob_spawn")
	_passive_spawner.tick(_delta, self, _player)
	PerfProbe.end("chunk_mgr.tick.mob_spawn", t_spawn)
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
	if shed_this_frame:
		# Bank the skipped delta — the next un-shed frame advances the
		# scheduler by the full elapsed time (catch-up stays clamped at
		# 2 ticks inside advance), so fluid/growth cadence doesn't drift.
		_shed_sched_delta += _delta
	else:
		var t_sched := PerfProbe.begin("chunk_mgr.tick.scheduler")
		_TICK_SCHEDULER.advance(_delta + _shed_sched_delta, self)
		_shed_sched_delta = 0.0
		PerfProbe.end("chunk_mgr.tick.scheduler", t_sched)
	PerfProbe.end("chunk_mgr.tick", probe_token)


# Decide which chunks should be loaded; enqueue missing ones, unload extras.
# Chunks the player has previously edited get re-loaded from `_saved_chunks`
# via the same worker path — no synchronous mesh hitch — so towers / mines /
# any block edits survive walking out of render distance and back.
func _update_chunk_set() -> void:
	var pc := _cached_player_chunk
	if pc == _last_chunk_set_coord:
		return
	_last_chunk_set_coord = pc
	var needed: Dictionary = {}
	# Mark the full ring needed, then enqueue misses in nearest-first order
	# so workers finish the player-ring before chasing far corners.
	for dx in range(-render_distance, render_distance + 1):
		for dz in range(-render_distance, render_distance + 1):
			needed[Vector2i(pc.x + dx, pc.y + dz)] = true
	# A quick direction reversal can make a not-yet-freed backing shell active
	# again. Restore that exact node instead of generating an overlapping
	# duplicate, then re-handshake its seams because neighbors may already be
	# rebuilding for the brief absent state.
	for coord: Vector2i in _retiring_chunks.keys():
		if not needed.has(coord):
			continue
		var record: Dictionary = _retiring_chunks[coord]
		# Validate before casting (see _drain_retiring_chunks) — a shell that
		# was freed while retired must not raise on the way back in.
		var returning_ref: Variant = record.get("node")
		_retiring_chunks.erase(coord)
		if not is_instance_valid(returning_ref):
			continue
		var returning: Node3D = returning_ref
		returning.process_mode = Node.PROCESS_MODE_INHERIT
		_chunks[coord] = returning
		var returning_chunk: Chunk = returning.get("chunk") as Chunk
		if returning_chunk != null:
			returning_chunk.dirty = true
		returning.set("_priority_apply", true)
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var neighbor_coord: Vector2i = coord + offset
			if not _chunks.has(neighbor_coord):
				continue
			var neighbor: Node3D = _chunks[neighbor_coord]
			var neighbor_chunk: Chunk = neighbor.get("chunk") as Chunk
			if neighbor_chunk != null:
				neighbor_chunk.dirty = true
			neighbor.set("_priority_apply", true)
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
	# Throttle evictions to bound the per-frame spike. Crossing a chunk
	# boundary makes ~17 chunks "not needed" at once; freeing all of them
	# in one frame triggers ConcavePolygonShape3D + ArrayMesh teardown
	# that ran ~170 ms in profiles. The to_remove set is rebuilt next
	# frame, so leftover evictions get picked up — at 4/frame and 60 fps
	# that's still 240 chunks/sec which dwarfs the boundary-cross rate.
	const _MAX_EVICTIONS_PER_FRAME: int = 4
	var evicted: int = 0
	for coord: Vector2i in to_remove:
		if evicted >= _MAX_EVICTIONS_PER_FRAME:
			break
		# If the chunk was edited while loaded, compress and persist its
		# blocks before freeing the ChunkNode.
		if _dirty_loaded.has(coord):
			_persist_chunk(coord, _chunks[coord].chunk)
			_dirty_loaded.erase(coord)
		# Faces previously culled against this chunk must reappear on every
		# surviving cardinal neighbor. Keep the outgoing rendered mesh as a
		# backing shell until those newer meshes actually APPLY; freeing here
		# exposed the skybox while their asynchronous workers were rebuilding.
		var retire_gates: Array = []
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var survivor_coord: Vector2i = coord + offset
			if not _chunks.has(survivor_coord):
				continue
			var survivor: Node3D = _chunks[survivor_coord]
			(
				retire_gates
				. append(
					{
						"coord": survivor_coord,
						"node": survivor,
						"apply_revision": int(survivor.get("_mesh_apply_revision")),
					}
				)
			)
			var survivor_chunk: Chunk = survivor.get("chunk") as Chunk
			if survivor_chunk != null:
				survivor_chunk.dirty = true
			survivor.set("_priority_apply", true)
		var outgoing: Node3D = _chunks[coord]
		outgoing.cancel_remesh_task()
		_chunks.erase(coord)
		if retire_gates.is_empty():
			outgoing.queue_free()
		else:
			# Stop simulation/remesh work on the shell. PROCESS_MODE_DISABLED
			# leaves its last GPU mesh visible while removing all update cost.
			outgoing.process_mode = Node.PROCESS_MODE_DISABLED
			_retiring_chunks[coord] = {"node": outgoing, "gates": retire_gates}
		evicted += 1
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
# chunk has saved player edits, we pop the compressed entry off main and
# pass it to the worker; the worker does the decompress + rescan. Used to
# decompress inline here (`_restore_saved_chunk` with 5 PackedByteArray
# decompresses + a 32 KB linear scan), which caused 80+ ms main-thread
# freezes when several saved chunks respawned in a single dispatch loop.
# Release backing shells once every neighbor that still survives in the active
# dictionary has presented a post-unload mesh. A neighbor that was itself
# evicted no longer gates anything—its own retirement protects its next live
# seam. Typical lifetime is one or two frames; there is no timer, synchronous
# meshing, or steady-state retained outer ring.
func _drain_retiring_chunks() -> void:
	if _retiring_chunks.is_empty():
		return
	var completed: Array[Vector2i] = []
	for coord: Vector2i in _retiring_chunks:
		var record: Dictionary = _retiring_chunks[coord]
		var ready: bool = true
		for gate: Dictionary in record.get("gates", []) as Array:
			var survivor_coord: Vector2i = gate["coord"]
			# is_instance_valid() BEFORE the cast. `as` on a freed instance
			# raises "Trying to cast a freed object" — the check has to run
			# on the raw Variant, which is the only form that tolerates a
			# dangling reference. A gate's survivor is freed out from under
			# us whenever that neighbor is itself evicted with no gates of
			# its own (see the queue_free below).
			var survivor_ref: Variant = gate["node"]
			if not is_instance_valid(survivor_ref):
				continue
			var survivor: Node3D = survivor_ref
			if not _chunks.has(survivor_coord) or _chunks[survivor_coord] != survivor:
				continue
			if int(survivor.get("_mesh_apply_revision")) <= int(gate["apply_revision"]):
				ready = false
				break
		if ready:
			# Same rule as the gate loop above — validate the raw Variant
			# before casting. The shell can already be gone here: scene
			# teardown frees our children while _process is still draining.
			var outgoing_ref: Variant = record.get("node")
			if is_instance_valid(outgoing_ref):
				(outgoing_ref as Node3D).queue_free()
			completed.append(coord)
	for coord: Vector2i in completed:
		_retiring_chunks.erase(coord)


func _reap_stale_pending() -> void:
	var now_ms: int = Time.get_ticks_msec()
	var stale: Array[Vector2i] = []
	for coord: Vector2i in _pending.keys():
		if now_ms - int(_pending[coord]) > _PENDING_TIMEOUT_MS:
			stale.append(coord)
	for coord: Vector2i in stale:
		push_warning("[chunk_mgr] reaping stale pending chunk %s — worker likely crashed" % coord)
		_pending.erase(coord)
		# Re-enqueue so dispatch retries it next tick.
		if not _spawn_queue_set.has(coord):
			_spawn_queue.append(coord)
			_spawn_queue_set[coord] = true


# Main-thread snapshot of every loaded neighbor's complete edge state, handed
# to the worker so a chunk's FIRST mesh both culls internal seam faces and
# lights surviving faces from real neighbor data. Every slice is a fresh
# PackedByteArray; workers never alias live chunks.
func _snapshot_neighbor_edge_planes(coord: Vector2i) -> Dictionary:
	var planes: Dictionary = {}
	var signature: Dictionary = {}
	var west: Chunk = get_chunk_at_coord(coord + Vector2i(-1, 0))
	if west != null:
		planes["west"] = west.east_edge_slices()
		signature["west"] = [west.get_instance_id(), west.lighting_revision]
	var east: Chunk = get_chunk_at_coord(coord + Vector2i(1, 0))
	if east != null:
		planes["east"] = east.west_edge_slices()
		signature["east"] = [east.get_instance_id(), east.lighting_revision]
	var north: Chunk = get_chunk_at_coord(coord + Vector2i(0, -1))
	if north != null:
		planes["north"] = north.south_edge_slices()
		signature["north"] = [north.get_instance_id(), north.lighting_revision]
	var south: Chunk = get_chunk_at_coord(coord + Vector2i(0, 1))
	if south != null:
		planes["south"] = south.north_edge_slices()
		signature["south"] = [south.get_instance_id(), south.lighting_revision]
	# A dimension with no sky has to spell that out at its frontier. Every
	# resident Nether cell is sky_light 0 (Lighting.fill_sky_light zeroes the
	# channel), but an ABSENT neighbour falls back to the OOB default of 15 —
	# "unloaded chunks are fully sky-lit", which is right for the Overworld
	# and maximally wrong here. The result is a full-bright face on every
	# chunk border against pitch-dark terrain: the lit grid standing out
	# across the Nether. Hand the mesher an explicitly dark sky plane instead.
	#
	# Only the sky plane is synthesised. Blocks and meta stay empty so
	# cross-chunk face culling is unchanged (an absent neighbour still reads
	# as AIR and the boundary face is still emitted), and block light already
	# defaults to 0. Both Chunk.get_sky_light and the native read_sky_light
	# consult these planes, so the two implementations stay byte-identical
	# without touching the GDExtension ABI.
	if not DimensionContext.active_provider().has_sky_light:
		var none := PackedByteArray()
		for side: String in ["west", "east", "north", "south"]:
			if planes.has(side):
				continue
			var dark := PackedByteArray()
			var across: int = Chunk.SIZE_Z if side == "west" or side == "east" else Chunk.SIZE_X
			dark.resize(Chunk.SIZE_Y * across)
			planes[side] = [none, none, dark, none]
	# Metadata only; _set_edge_planes iterates the four canonical side names
	# and ignores this key. The ready-result gate uses it to catch a neighbor
	# arriving, unloading, being replaced, or changing while worldgen/meshing
	# was in flight.
	planes["_signature"] = signature
	return planes


# Bind (or, with an empty dict, unbind) snapshotted neighbor edge planes.
static func _set_edge_planes(chunk: Chunk, planes: Dictionary) -> void:
	var none := PackedByteArray()
	for side: String in ["west", "east", "north", "south"]:
		var edge: Array = planes.get(side, []) as Array
		chunk.set("edge_blocks_" + side, edge[0] if edge.size() >= 4 else none)
		chunk.set("edge_meta_" + side, edge[1] if edge.size() >= 4 else none)
		chunk.set("edge_sky_light_" + side, edge[2] if edge.size() >= 4 else none)
		chunk.set("edge_block_light_" + side, edge[3] if edge.size() >= 4 else none)


func _dispatch_workers() -> void:
	while not _spawn_queue.is_empty() and _pending.size() < max_concurrent_jobs:
		var coord: Vector2i = _spawn_queue.pop_front()
		_spawn_queue_set.erase(coord)
		if _chunks.has(coord) or _pending.has(coord):
			continue
		_pending[coord] = Time.get_ticks_msec()
		# Pop the compressed save entry (microseconds — dict has + erase).
		# Worker does decompress + rescan; main thread applies the side
		# effects (sapling enqueue, pending-tick restore) in _materialize_chunk.
		# Cache miss falls back to disk via SaveLoad (step 7.1 — disk read
		# is one var_to_bytes-decoded region per first access, cached after).
		# Empty dict from both means "this is fresh worldgen, no saved data".
		var saved_entry: Dictionary = {}
		if _saved_chunks.has(coord):
			saved_entry = _saved_chunks[coord]
			_saved_chunks.erase(coord)
		else:
			saved_entry = _SAVE_LOAD.load_chunk(coord)
		# Snapshot the loaded neighbors' light planes HERE, on the main
		# thread, so the worker's first mesh lights its seam faces from real
		# data instead of the OOB sky=15 default.
		var edge_planes: Dictionary = _snapshot_neighbor_edge_planes(coord)
		# Tag the job with the dimension and epoch it was dispatched
		# under. WorkerThreadPool has no cancel API, so a task queued just
		# before a portal transition WILL run to completion and try to
		# publish afterwards; carrying the tags is what lets the
		# main-thread drain reject it. See DimensionContext.accepts_result.
		WorkerThreadPool.add_task(
			_compute_chunk_data.bind(
				coord, saved_entry, edge_planes, DimensionContext.active(), DimensionContext.epoch()
			)
		)


# Worker-thread function — runs off the main thread. Uses the supplied
# saved entry (decompress + rescan in-worker) if non-empty; otherwise
# runs worldgen. Either way, builds the mesh arrays and stores the result
# behind a mutex. Lighting fill runs after worldgen but before mesh:
# vanilla mesher reads sky_light per face for the chunk shader (slice 5),
# so the data must be in place before the mesh arrays are baked. We
# ALWAYS re-run the fill (even on restore) — saved sky_light from earlier
# sessions can be stale if the player saved before the lighting code
# shipped (everything reads as default 15 and caves render lit). With
# the C++ port this costs ~30-50ms per chunk vs the old 380ms, so the
# wasted-work argument no longer holds and correctness wins.
func _compute_chunk_data(
	coord: Vector2i, saved_entry: Dictionary, edge_planes: Dictionary, dimension: int, epoch: int
) -> void:
	var probe_token := PerfProbe.begin("chunk_mgr.worker_total")
	var chunk: Chunk
	var sapling_positions: Array[Vector3i] = []
	if saved_entry.is_empty():
		# Route through the provider rather than calling Worldgen
		# directly, and use the dimension passed IN — reading
		# DimensionContext.active() here would race a transition that
		# happens while this worker runs. The Overworld provider is a
		# straight call to Worldgen, so dimension 0 output is unchanged.
		chunk = DimensionContext.provider(dimension).generate_chunk(coord.x, coord.y)
	else:
		var decoded: Array = _decode_saved_entry(coord, saved_entry)
		chunk = decoded[0] as Chunk
		sapling_positions = decoded[1]
	Lighting.fill_sky_light(chunk)
	Lighting.fill_block_light(chunk)
	# Warm the heightmap on the worker. Fresh chunks come out of worldgen
	# with _height_map_dirty=true (set_block_unchecked only maintains max_y,
	# not the per-column heightmap). Without this, the first main-thread
	# is_sky_exposed call — fired by prepare_relight_data right after
	# materialize — pays a 15-27 ms _rebuild_height_map walk (32 KB scan
	# × Blocks.light_opacity lookup). Forcing it here moves the cost off
	# the main-thread frame budget.
	chunk.is_sky_exposed(0, 0, 0)
	# Neighbor light for the seam faces. Attached AFTER the fill (so the
	# lighting BFS keeps today's OOB semantics) and cleared immediately
	# after the mesh bakes, so the chunk this worker publishes is
	# byte-identical to what it publishes today — relight, later re-meshes
	# and save all keep seeing empty planes.
	_set_edge_planes(chunk, edge_planes)
	var mesh_data := Mesher.mesh_chunk_fast(chunk)
	_set_edge_planes(chunk, {})
	_result_mutex.lock()
	_ready_results[coord] = {
		"chunk": chunk,
		"mesh": mesh_data,
		"dimension": dimension,
		"epoch": epoch,
		"from_save": not saved_entry.is_empty(),
		"saplings": sapling_positions,
		"pending_ticks": saved_entry.get("pending_ticks", []),
		"tile_entities": saved_entry.get("tile_entities", {}),
		"edge_signature": edge_planes.get("_signature", {}),
	}
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
	# Stale-work gate. A worker dispatched before a dimension transition
	# finishes after it, and its chunk belongs to a world that is no
	# longer resident. Applying it would splice Overworld terrain into the
	# Nether. Drop the result and clear the pending slot so the coord can
	# be re-dispatched under the current epoch.
	if not DimensionContext.accepts_result(
		int(data.get("dimension", DimensionContext.OVERWORLD)), int(data.get("epoch", -1))
	):
		_pending.erase(coord)
		stale_results_rejected += 1
		return
	# Player may have moved away while the worker was running — drop the result.
	var pc := _cached_player_chunk
	if absi(coord.x - pc.x) > render_distance or absi(coord.y - pc.y) > render_distance:
		_pending.erase(coord)
		return
	if _chunks.has(coord):
		_pending.erase(coord)
		return
	# A mesh can spend tens of milliseconds in a worker while adjacent chunks
	# materialize on the main thread. Never present that now-stale boundary
	# geometry: re-mesh the already-generated Chunk off-thread with the current
	# edge snapshot, then run this same gate again. This removes the one-frame
	# cave/skybox crack without adding a synchronous mesher call or draw work.
	var current_edges: Dictionary = _snapshot_neighbor_edge_planes(coord)
	var current_signature: Dictionary = current_edges.get("_signature", {}) as Dictionary
	var meshed_signature: Dictionary = data.get("edge_signature", {}) as Dictionary
	if meshed_signature != current_signature:
		_pending[coord] = Time.get_ticks_msec()
		WorkerThreadPool.add_task(_remesh_ready_chunk.bind(coord, data, current_edges))
		return
	_pending.erase(coord)
	_materialize_chunk(coord, data)


# Worker-only correction for a generated/restored chunk whose neighbor set
# changed before presentation. The Chunk is not live yet, so it has no main-
# thread writers. Reuse it instead of regenerating or re-decoding, and publish
# the refreshed result through the same mutex-protected ready queue.
func _remesh_ready_chunk(coord: Vector2i, data: Dictionary, edge_planes: Dictionary) -> void:
	var chunk: Chunk = data.get("chunk") as Chunk
	if chunk == null:
		return
	_set_edge_planes(chunk, edge_planes)
	data["mesh"] = Mesher.mesh_chunk_fast(chunk)
	_set_edge_planes(chunk, {})
	data["edge_signature"] = edge_planes.get("_signature", {})
	_result_mutex.lock()
	_ready_results[coord] = data
	_result_mutex.unlock()


func _materialize_chunk(coord: Vector2i, data: Dictionary) -> void:
	var probe_token := PerfProbe.begin("chunk_mgr.materialize")
	var t_inst := PerfProbe.begin("chunk_mgr.materialize.instantiate")
	var node: Node3D = chunk_scene.instantiate()
	node.position = Vector3(coord.x * Chunk.SIZE_X, 0, coord.y * Chunk.SIZE_Z)
	node.set("chunk_data", data.chunk)
	node.set("precomputed_mesh_data", data.mesh)
	PerfProbe.end("chunk_mgr.materialize.instantiate", t_inst)
	var t_add := PerfProbe.begin("chunk_mgr.materialize.add_child")
	add_child(node)
	PerfProbe.end("chunk_mgr.materialize.add_child", t_add)
	_chunks[coord] = node
	chunks_generated_total += 1
	_index_portals_in_chunk(coord, data.chunk)
	# A chunk that came from `_saved_chunks` is already player-edited;
	# mark it so any further edits (or just the next unload) re-persist.
	# Re-enqueue saplings + pending block ticks from the worker decode here
	# (main thread) — those mutate _growing_saplings + TickScheduler state
	# which the worker couldn't touch safely.
	if data.get("from_save", false):
		_dirty_loaded[coord] = true
		for sap_pos: Vector3i in data.get("saplings", []) as Array:
			_enqueue_sapling_growth(sap_pos)
		var ticks: Array = data.get("pending_ticks", []) as Array
		if not ticks.is_empty():
			TickScheduler.restore_ticks(ticks)
		# Tile entities (chests, furnaces). Split the worker's flat
		# tile_entities dict back into per-type buckets and route to the
		# respective singleton's restore_chunk. Empty dict = no TEs to
		# restore (fresh worldgen chunks always land here).
		var tile_entities: Dictionary = data.get("tile_entities", {}) as Dictionary
		if not tile_entities.is_empty():
			var chests: Dictionary = {}
			var furnaces: Dictionary = {}
			var signs: Dictionary = {}
			var jukeboxes: Dictionary = {}
			var spawners: Dictionary = {}
			for local_pos: Vector3i in tile_entities:
				var te: Dictionary = tile_entities[local_pos]
				match te.get("type", ""):
					"chest":
						chests[local_pos] = te.get("items", [])
					"furnace":
						furnaces[local_pos] = te.get("data", {})
					"sign":
						signs[local_pos] = te.get("lines", [])
					"jukebox":
						jukeboxes[local_pos] = te.get("disc", 0)
					"spawner":
						spawners[local_pos] = te.get("mob", "")
			if not chests.is_empty():
				ChestStorage.restore_chunk(coord, chests)
			if not furnaces.is_empty():
				FurnaceManager.restore_chunk(coord, furnaces)
			if not signs.is_empty():
				SignStorage.restore_chunk(coord, signs)
			if not jukeboxes.is_empty():
				JukeboxStorage.restore_chunk(coord, jukeboxes)
			if not spawners.is_empty():
				MobSpawnerManager.restore_chunk(coord, spawners)
	# Drain cane tops collected during worldgen / decode (worker thread).
	# Was a 32k-cell column walk on every materialize before — now a small
	# list iteration (typical chunks: 0-4 entries).
	for cane_pos: Vector3i in data.chunk.cane_tops:
		_enqueue_cane_growth(cane_pos)
	data.chunk.cane_tops.clear()
	# Drain pending tile-entity registrations queued by worldgen (e.g.
	# dungeon spawners + chest loot). Done HERE on main thread because
	# MobSpawnerManager / ChestStorage / TickScheduler aren't worker-safe.
	# Empty for saved chunks (their tile entities went through the
	# tile_entities restore path above).
	if not data.chunk.pending_tile_entities.is_empty():
		var origin_x: int = coord.x * Chunk.SIZE_X
		var origin_z: int = coord.y * Chunk.SIZE_Z
		for te: Dictionary in data.chunk.pending_tile_entities:
			var local_pos: Vector3i = te.get("pos", Vector3i.ZERO)
			var world_pos := Vector3i(origin_x + local_pos.x, local_pos.y, origin_z + local_pos.z)
			match te.get("type", ""):
				"spawner":
					MobSpawnerManager.configure(world_pos, str(te.get("mob", "")))
				"chest_fill":
					# Skip if this chest already holds any items. Worldgen
					# determinism + ChestStorage entries surviving non-dirty
					# chunk eviction means a revisit would otherwise APPEND
					# another fresh roll's items into the empty slots,
					# producing duplicate stacks across visits (two of the
					# same music disc, two stacks of bone, etc). Also
					# preserves player-modified chest contents.
					var slots: Array = ChestStorage.get_or_create(world_pos)
					var already_filled: bool = false
					for s: ItemStack in slots:
						if not s.is_empty():
							already_filled = true
							break
					if already_filled:
						continue
					var items: Array = te.get("items", []) as Array
					var slot_idx: int = 0
					for pick: Array in items:
						while slot_idx < slots.size() and not slots[slot_idx].is_empty():
							slot_idx += 1
						if slot_idx >= slots.size():
							break
						slots[slot_idx].item_id = int(pick[0])
						slots[slot_idx].count = int(pick[1])
		data.chunk.pending_tile_entities.clear()
	# Worldgen-time animal spawn pass — only for fresh chunks. Re-loaded
	# chunks already had their entities saved via EntitySave, so a second
	# pass would duplicate them. The spawner reads voxels through
	# get_world_block so we must call it AFTER the chunk is in `_chunks`.
	if not data.get("from_save", false):
		_passive_spawner.populate_chunk_at_gen(self, coord)
	# Re-dirty loaded neighbors AND this new chunk so later changes to
	# either side of a seam converge in both meshes. The ready-result gate
	# above has already guaranteed this chunk's FIRST presented mesh used
	# the current complete edge snapshot; this handshake now covers the
	# reciprocal neighbor mesh and any change after that snapshot.
	#
	# Reciprocal seam heals ride the PRIORITY apply lane. They are bounded
	# (once per arrival, both sides) and correct an older neighbor whose mesh
	# predates this chunk; the new chunk itself never presents stale boundary
	# geometry. See docs/lighting-chunk-seams.md Phase 3.
	var had_neighbor: bool = false
	for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var neighbor_coord: Vector2i = coord + offset
		if _chunks.has(neighbor_coord):
			_chunks[neighbor_coord].chunk.dirty = true
			_chunks[neighbor_coord].set("_priority_apply", true)
			had_neighbor = true
	# Set initial collision activity from distance so far-ring chunks
	# don't waste a trimesh + BVH between materialize and the next
	# boundary-crossing sweep.
	var pc := _cached_player_chunk
	var near: bool = (
		absi(coord.x - pc.x) <= collision_radius and absi(coord.y - pc.y) <= collision_radius
	)
	node.call("set_collision_active", near)
	if had_neighbor:
		data.chunk.dirty = true
		# The new chunk's own seam heal shares the priority lane — same
		# rationale as the neighbor re-dirty above.
		node.set("_priority_apply", true)
		# Redstone edge reconciliation (redstone-plan.md §7.2). Persisted
		# metadata is a SNAPSHOT, not proof the power is still valid: a
		# lever on this seam may have been flipped while the neighbouring
		# chunk was unloaded, so wire arriving from disk can hold a stale
		# level. Re-seed every wire cell on the four seams and let the
		# propagation fixpoint sort it out — a network that is already
		# correct costs a scan and zero writes.
		_reconcile_redstone_edges(coord, data.chunk)
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
		# Queue rather than dispatch inline — `prepare_relight_data` snapshots
		# 5 chunks × 4 PackedByteArrays which is another 1-3 ms on top of the
		# scene-instantiate cost here. `_drain_one_relight_dispatch` pops one
		# per frame so the snapshot lands on a quieter frame.
		if not _pending_relight_dispatch_set.has(coord):
			_pending_relight_dispatch.append(coord)
			_pending_relight_dispatch_set[coord] = true
	PerfProbe.end("chunk_mgr.materialize", probe_token)


# Synchronous startup spawn — runs once per chunk in the initial ring
# during _spawn_initial_chunks (the spiral-out load that fills the
# loading screen's progress bar).
#
# IMPORTANT: must check disk for saved data BEFORE regenerating. Audit
# miss originally: this path called Worldgen.generate_chunk directly,
# so every chunk in the initial ring (the chunks closest to spawn where
# the player has actually been editing) silently regenerated on world
# load. Only chunks beyond the initial ring went through the disk-
# fallback path in _dispatch_workers / _compute_chunk_data.
#
# Decode runs on the main thread here (the worker-thread decode lives
# in _compute_chunk_data). That's a 1-3 ms hit per saved chunk during
# the loading screen, well inside its budget.
# Load the 3×3 patch around `center` synchronously. The player's
# capsule (radius 0.3) can straddle a chunk boundary at any cell-edge
# spawn coord — e.g. spawn at world (16, 92, 15) lives on the X-axis
# boundary and the capsule overlaps chunks (0,0) AND (1,0). Loading
# only the center leaves an unloaded neighbor where collision is
# absent, so the player falls through. The 3×3 is overkill in interior
# cases but cheap (each call sync-generates ~9 chunks if all uncached;
# ~100 ms one-off respawn hit, acceptable).
func _spawn_chunk_sync_neighborhood(center: Vector2i) -> void:
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			_spawn_chunk_sync(Vector2i(center.x + dx, center.y + dz))


# Materialize one chunk right now, blocking until it is fully usable.
#
# Public because the portal transition has to guarantee ground under the
# destination before it places the player — the per-frame streamer would
# get there eventually, but "eventually" is a player falling through the
# Nether. Behind a loading screen, so the frame cost is expected.
func spawn_chunk_now(coord: Vector2i) -> void:
	# _spawn_chunk_sync force-applies pending mesh+collision on both its
	# branches — "now" means live collision, not a queued apply.
	_spawn_chunk_sync(coord)


func _spawn_chunk_sync(coord: Vector2i) -> void:
	if _chunks.has(coord):
		# Already materialized — but chunk_node defers the first
		# mesh+collision apply through _pending_apply (drained 1/frame via
		# try_consume_apply_budget). The whole point of "sync" is to
		# guarantee the chunk is fully usable BEFORE the caller places an
		# entity on it; if we leave pending_apply queued, safe_teleport
		# drops the player onto a StaticBody3D with a null shape and they
		# fall through. Force-flush so the contract holds.
		var existing: Node3D = _chunks[coord]
		if existing != null and existing.has_method("force_apply_pending"):
			existing.call("force_apply_pending")
		return
	var saved_entry: Dictionary = {}
	if _saved_chunks.has(coord):
		saved_entry = _saved_chunks[coord]
		_saved_chunks.erase(coord)
	else:
		saved_entry = _SAVE_LOAD.load_chunk(coord)
	var chunk: Chunk
	var saplings: Array[Vector3i] = []
	if saved_entry.is_empty():
		# Route through the provider, exactly as the worker path does. This
		# is the SYNCHRONOUS spawn — initial world entry and the portal
		# transition's destination ring — so calling Worldgen directly here
		# would hand a player who saved in the Nether a ring of Overworld
		# terrain to stand on. Safe to read the active dimension on this
		# path (unlike the worker) because it runs on the main thread and
		# cannot be racing a transition.
		chunk = DimensionContext.provider(DimensionContext.active()).generate_chunk(
			coord.x, coord.y
		)
	else:
		var decoded: Array = _decode_saved_entry(coord, saved_entry)
		chunk = decoded[0] as Chunk
		saplings = decoded[1]
	Lighting.fill_sky_light(chunk)
	Lighting.fill_block_light(chunk)
	# Warm the heightmap (same reason as _compute_chunk_data — avoids the
	# 15 ms is_sky_exposed rebuild firing on the next main-thread tick).
	chunk.is_sky_exposed(0, 0, 0)
	var edge_planes: Dictionary = _snapshot_neighbor_edge_planes(coord)
	_set_edge_planes(chunk, edge_planes)
	var mesh_data := Mesher.mesh_chunk_fast(chunk)
	_set_edge_planes(chunk, {})
	_materialize_chunk(
		coord,
		{
			"chunk": chunk,
			"mesh": mesh_data,
			"from_save": not saved_entry.is_empty(),
			"saplings": saplings,
			"pending_ticks": saved_entry.get("pending_ticks", []),
			"tile_entities": saved_entry.get("tile_entities", {}),
			"edge_signature": edge_planes.get("_signature", {}),
		}
	)
	# Same contract as the resident branch above: "sync" must mean live
	# collision, not a queued _pending_apply. Without this, a portal
	# arrival regained control on a chunk with a null collision shape —
	# the ground guard froze the player inside the portal and the
	# exposure meter bounced them straight back: the enter/leave loop.
	var fresh_node: Node3D = _chunks.get(coord)
	if fresh_node != null and fresh_node.has_method("force_apply_pending"):
		fresh_node.call("force_apply_pending")


# Snapshot the {target + cardinal neighbors} chunks and dispatch the
# native cross-chunk relight to a worker thread. Replaces the synchronous
# `Lighting.relight_chunk_borders` main-thread call. Result is drained
# one-per-frame in `_drain_relight_results` and applied via
# `Lighting.apply_relight_result`.
#
# Race handling:
#   * `_pending_relights[coord]` blocks double-dispatch for the same target.
#   * every participating chunk carries a captured lighting revision;
#   * apply validates the complete revision set before replacing any array;
#   * stale/overlapping/unloaded results are discarded and the target requeued.
# Pop one queued relight per frame from `_pending_relight_dispatch` and
# run the snapshot + worker dispatch. Chunks that unloaded between
# materialize and drain are skipped (get_chunk_at_coord returns null).
func _drain_one_relight_dispatch() -> void:
	var budget: int = 2 if _entry_boost_active() else 1
	while not _pending_relight_dispatch.is_empty() and budget > 0:
		var coord: Vector2i = _pending_relight_dispatch.pop_front()
		_pending_relight_dispatch_set.erase(coord)
		if get_chunk_at_coord(coord) == null:
			continue
		_dispatch_relight(coord)
		budget -= 1


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
	var revisions: Dictionary = Lighting.relight_revisions(chunk_data)
	_pending_relights[coord] = true
	WorkerThreadPool.add_task(_relight_worker.bind(coord, chunk_data, revisions))


# Worker-thread entry — runs the native BFS on the snapshotted slabs and
# stashes the result for the main thread to apply.
func _relight_worker(coord: Vector2i, chunk_data: Array, revisions: Dictionary) -> void:
	var result: Dictionary = Lighting.compute_relight_borders_native(coord, chunk_data)
	_result_mutex.lock()
	_relight_results[coord] = {"lighting": result, "revisions": revisions}
	_result_mutex.unlock()


# Main-thread drain — at most one relight result per frame keeps the apply
# spike bounded. Apply itself is cheap (a few PackedByteArray pointer
# assigns + dirty marks) but each one re-meshes the touched chunks, so
# spreading them out reads as smoother frames.
func _drain_relight_results() -> void:
	var budget: int = 2 if _entry_boost_active() else 1
	for _i in range(budget):
		if not _drain_one_relight_result():
			return


# Pops and applies a single relight result. Returns false when the
# queue was empty (caller stops draining this frame).
func _drain_one_relight_result() -> bool:
	_result_mutex.lock()
	var coord: Vector2i = Vector2i.ZERO
	var job_result: Dictionary = {}
	var has_one: bool = false
	for c: Vector2i in _relight_results:
		coord = c
		job_result = _relight_results[c]
		has_one = true
		break
	if has_one:
		_relight_results.erase(coord)
	_result_mutex.unlock()
	if not has_one:
		return false
	_pending_relights.erase(coord)
	var result: Dictionary = job_result.get("lighting", {}) as Dictionary
	var revisions: Dictionary = job_result.get("revisions", {}) as Dictionary
	var accepted: bool = Lighting.apply_relight_result(result, self, revisions)
	if not accepted and get_chunk_at_coord(coord) != null:
		# Re-snapshot on a later frame. Dedupe against an already queued
		# neighbor-arrival retry.
		if not _pending_relight_dispatch_set.has(coord):
			_pending_relight_dispatch.append(coord)
			_pending_relight_dispatch_set[coord] = true
	return true


# --- Autosave (step 7.4) ---


# Build the 5-min autosave timer + the "Auto-saving..." overlay label.
# Called from _ready. The label lives on a dedicated CanvasLayer so it
# renders above the 3D world without being affected by camera or HUD
# layout. Visible for 1 second per autosave, low-contrast white so it's
# noticeable but not distracting.
func _setup_autosave() -> void:
	_session_start_msec = Time.get_ticks_msec()
	# Headless sessions are READ-ONLY. Game._ready pins the worldgen
	# seed to the GUT test default under headless (game.gd), so any
	# chunk generated in a headless boot of a real world has the WRONG
	# terrain — an autosave firing in that state fossilizes it into the
	# region files. This happened: World1 chunk (1,1) was persisted as
	# seed-12345 terrain by a headless validation boot and surfaced as a
	# chunk-shaped tower. The pause-menu save path is unreachable
	# headless, so skipping the timer makes headless fully non-writing.
	if DisplayServer.get_name() == "headless":
		return
	_autosave_timer = Timer.new()
	_autosave_timer.wait_time = _AUTOSAVE_INTERVAL_SEC
	_autosave_timer.one_shot = false
	_autosave_timer.autostart = true
	_autosave_timer.timeout.connect(_on_autosave_tick)
	add_child(_autosave_timer)
	var layer := CanvasLayer.new()
	layer.layer = 8  # above HUD (default 1) and pause menu (4-ish)
	add_child(layer)
	_autosave_label = Label.new()
	_autosave_label.text = "Auto-saving..."
	# Vanilla MC's "Saving chunks..." message — yellow with black drop
	# shadow. Bigger font + drop shadow to read clearly over any terrain.
	_autosave_label.add_theme_color_override("font_color", Color(1, 1, 0.4, 1.0))
	_autosave_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	_autosave_label.add_theme_constant_override("shadow_offset_x", 2)
	_autosave_label.add_theme_constant_override("shadow_offset_y", 2)
	_autosave_label.add_theme_font_size_override("font_size", _AUTOSAVE_INDICATOR_FONT_SIZE)
	# Anchor top-right — away from the hotbar at the bottom and the F3
	# debug overlay at the top-left. Hovering 24 px in from each edge so
	# it's clearly inside the frame.
	_autosave_label.anchor_left = 1.0
	_autosave_label.anchor_right = 1.0
	_autosave_label.anchor_top = 0.0
	_autosave_label.anchor_bottom = 0.0
	_autosave_label.offset_left = -260
	_autosave_label.offset_top = 24
	_autosave_label.offset_right = -16
	_autosave_label.offset_bottom = 60
	_autosave_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_autosave_label.visible = false
	layer.add_child(_autosave_label)


# Autosave fire callback. Flushes dirty regions, player, entities, and
# world.json. Synchronous — at ~25 dirty chunks max in a render-distance-
# 8 ring, the total cost is bounded (~50ms worst case from FastLZ +
# var_to_bytes work). Indicator label appears for 1s so the player
# notices the brief hitch isn't a freeze.
func _on_autosave_tick() -> void:
	if _autosave_label != null:
		_autosave_label.visible = true
	# Persist dirty live chunks before flushing the region cache —
	# otherwise edits to chunks that haven't evicted yet are missed.
	var t_start_msec: int = Time.get_ticks_msec()
	flush_dirty_loaded()
	SaveLoad.flush_all_regions()
	# Portal hints (audit finding #6) — dirty-checked, so the common
	# autosave writes nothing extra.
	if PortalIndex.is_dirty(DimensionContext.active()):
		PortalIndex.save()
	if _player != null:
		PlayerSave.save_player(_player)
	EntitySave.save_all(self)
	var meta: Dictionary = WorldMeta.load_meta()
	if meta.is_empty():
		meta = WorldMeta.make_initial(
			Worldgen.WORLD_SEED, Vector3i(0, 70, 0), WorldTime.current_tick()
		)
	meta["seed"] = Worldgen.WORLD_SEED
	meta["time_ticks"] = WorldTime.current_tick()
	var session_seconds: int = (Time.get_ticks_msec() - _session_start_msec) / 1000
	meta["play_time_seconds"] = int(meta.get("play_time_seconds", 0)) + session_seconds
	_session_start_msec = Time.get_ticks_msec()  # avoid double-counting on the next tick
	WorldMeta.save_meta(meta)
	# Terminal log — visible in the Godot output panel even if the
	# player blinked through the on-screen indicator. Reports the
	# end-to-end autosave duration so frame-hitch regressions are
	# obvious if they appear.
	var elapsed_ms: int = Time.get_ticks_msec() - t_start_msec
	print("[Autosave] saved in %d ms" % elapsed_ms)
	if _autosave_label != null:
		# Hide the indicator after a short visibility window. SceneTreeTimer
		# is fire-and-forget; if the label was freed before timeout (shutdown
		# race), is_instance_valid guards it.
		var fade: SceneTreeTimer = get_tree().create_timer(_AUTOSAVE_INDICATOR_VISIBLE_SEC)
		fade.timeout.connect(
			func() -> void:
				if is_instance_valid(_autosave_label):
					_autosave_label.visible = false
		)


# Compress a chunk's blocks and stash them in `_saved_chunks`. Called only
# when an edited chunk is about to be unloaded, so the per-edit hot path
# never pays for compression. Light arrays compress cheaply (long runs of
# 15s above ground, 0s in caves) so adding them ~doubles the payload but
# stays under a couple KB per typical edited chunk.
# Self-healing portal index (audit finding #6). The index used to be
# written only by dimension transitions, so a portal lit and then saved
# via autosave or the pause menu was lost on reload — travel still found
# it (the raw scan reads real blocks) but the renderer, which is
# index-driven, drew nothing. Re-deriving entries as chunks stream in
# means a lost, stale or never-written index converges back to truth the
# moment the player can see the portal.
#
# PackedByteArray.find is a native memchr, so the 99.9% of chunks with
# no portal pay one 32 KB scan and nothing else.
func _index_portals_in_chunk(coord: Vector2i, chunk: Chunk) -> void:
	var idx: int = chunk.blocks.find(Blocks.PORTAL)
	if idx == -1:
		return
	var dimension: int = DimensionContext.active()
	while idx != -1:
		# Y-major layout: idx = y*256 + z*16 + x. Shifts, because this
		# runs inside the materialize hot path when a portal IS present.
		var y: int = idx >> 8
		var rem: int = idx & 255
		# Only column BOTTOMS become entries — the same normalisation the
		# search and the renderer both use.
		if y == 0 or chunk.blocks[idx - 256] != Blocks.PORTAL:
			PortalIndex.record(
				dimension,
				Vector3i(
					coord.x * Chunk.SIZE_X + (rem & 15), y, coord.y * Chunk.SIZE_Z + (rem >> 4)
				)
			)
		idx = chunk.blocks.find(Blocks.PORTAL, idx + 1)


# A headless session must never write to the world on disk.
#
# `Game._ready` pins the worldgen seed to the GUT test default under
# headless, so every chunk generated in a headless boot of a REAL world
# has the wrong terrain. Persisting one fossilizes it into the region
# files — this happened to World1 chunk (1,1), which came back as a
# chunk-shaped tower.
#
# The autosave timer was already skipped for this reason (_setup_autosave),
# but that was only one of the write paths: the streaming ring evicts
# edited chunks as the player-shaped centre moves, and eviction
# write-throughs are not on the timer. A headless `godot main.tscn` boot
# therefore still rewrote a region file. The guard belongs on every
# ChunkManager path that reaches disk, which is what this is.
#
# NOT a guard on SaveLoad itself: the GUT suite legitimately writes and
# reads back throwaway worlds through SaveLoad's own API, and only the
# LIVE STREAMING paths here can produce wrong-seed terrain.
func _disk_writes_allowed() -> bool:
	return DisplayServer.get_name() != "headless"


func _persist_chunk(coord: Vector2i, chunk: Chunk) -> void:
	# Eviction path: builds the destructive entry (pulls TE state into the
	# entry + clears it from singletons, takes pending ticks out of the
	# scheduler). The chunk node is about to be freed so the live state
	# would be lost anyway — moving it to disk is exactly right.
	var entry: Dictionary = _build_chunk_save_entry(coord, chunk, true)
	_saved_chunks[coord] = entry
	if not _disk_writes_allowed():
		return
	# Write-through to disk (step 7.1). The in-memory cache stays as a fast
	# layer in front; on next dispatch we'll hit it before disk. SaveLoad's
	# region cache means subsequent edits in the same region only pay one
	# file rewrite per evict, not one full deserialize + reserialize cycle.
	_SAVE_LOAD.save_chunk(coord, entry)


# Persist every dirty live chunk to disk WITHOUT freeing it. Called by
# autosave + save-and-quit so player edits made between evictions don't
# get lost (which they were — _dirty_loaded chunks live in _chunks[]
# only, never in _saved_chunks or disk until eviction). Non-destructive:
# TickScheduler ticks stay in the queue, chest/furnace state stays in
# the singletons. The chunk_manager keeps running normally afterward.
# Returns the count of chunks written.
# --- Dimension ownership (Nether plan §3.3 / §7.2, Batch 1) ---


# Drop every piece of runtime state that belongs to ONE dimension.
#
# Called on world load and on every dimension transition. The plan allows
# either clearing these structures or keying them by dimension; clearing
# is the honest choice here because exactly one dimension is resident at
# a time (§3.3), so a keyed structure would only ever hold one key.
#
# Everything world-position-keyed has to go. A chest at (10, 64, 10) in
# the Overworld and a chest at (10, 64, 10) in the Nether are different
# chests, and the tile-entity singletons key on position alone — leaving
# an entry behind means the Nether chest opens holding Overworld loot.
# Same argument for scheduled ticks, light queues and the saved-chunk
# cache.
func _clear_dimension_owned_state() -> void:
	# Tile entities. These are autoload singletons keyed by world
	# position, with no dimension component of their own.
	MobSpawnerManager.clear_all()
	ChestStorage.clear_all()
	FurnaceManager.clear_all()
	SignStorage.clear_all()
	JukeboxStorage.clear_all()
	# Scheduled block ticks — fluid flow, falling blocks, redstone.
	_TICK_SCHEDULER.clear_all()
	# Generation + meshing pipeline. _ready runs before any of these has
	# content; a transition runs when they may be full.
	_spawn_queue.clear()
	_spawn_queue_set.clear()
	_pending.clear()
	_result_mutex.lock()
	_ready_results.clear()
	_relight_results.clear()
	_result_mutex.unlock()
	_pending_relights.clear()
	_pending_relight_dispatch.clear()
	_pending_relight_dispatch_set.clear()
	_pending_immediate_rebuild.clear()
	# Persisted-chunk caches. _saved_chunks holds compressed blocks keyed
	# by chunk coord with no dimension in the key.
	_saved_chunks.clear()
	_dirty_loaded.clear()
	# Deferred block-update bookkeeping.
	_notify_queue.clear()
	_notify_queued.clear()
	_deferred_sky_seeds.clear()
	_deferred_block_seeds.clear()
	_deferred_fizz.clear()
	# Growth/decay work lists, all world-position-keyed.
	_decaying_leaves.clear()
	_growing_saplings.clear()
	_growing_canes.clear()
	# Force the next _update_chunk_set to rebuild from scratch rather
	# than trusting a cached centre from the previous dimension.
	_last_chunk_set_coord = Vector2i(2147483647, 2147483647)
	_last_collision_center = Vector2i(2147483647, 2147483647)


# Free every resident chunk node and every persisted entity child.
#
# Bypasses the normal retire path deliberately: retirement is a graceful
# multi-frame fade for chunks the player walked away from, and a
# dimension switch has no "away" to fade toward. Everything goes now, so
# the assertion that only one dimension's scene is resident holds the
# moment the transition returns.
func _free_dimension_scene() -> int:
	var freed: int = 0
	for coord: Vector2i in _chunks.keys():
		var node: Node = _chunks[coord] as Node
		if is_instance_valid(node):
			remove_child(node)
			node.queue_free()
			freed += 1
	_chunks.clear()
	for coord: Vector2i in _retiring_chunks.keys():
		var record: Dictionary = _retiring_chunks[coord]
		var shell: Variant = record.get("node")
		if shell is Node and is_instance_valid(shell as Node):
			(shell as Node).queue_free()
	_retiring_chunks.clear()
	# Persisted entities (dropped items, mobs, carts, boats, paintings)
	# were just written to the SOURCE dimension's entities.bin; the live
	# nodes must not follow the player through.
	for child: Node in get_children():
		if EntitySave.is_persistable(child):
			remove_child(child)
			child.queue_free()
			freed += 1
	# Transient projectiles (audit finding #5) are deliberately
	# NON-persistable — vanilla drops them across dimensions too — which
	# also meant nothing here swept them: a fireball mid-flight crossed a
	# portal as a live node and detonated in the destination dimension at
	# its source coordinates. Group membership is declared in each
	# projectile's _ready, and the sweep is global rather than
	# children-of-this-node because spawn parents vary.
	for node: Node in get_tree().get_nodes_in_group("transient_projectile"):
		if is_instance_valid(node):
			node.queue_free()
			freed += 1
	return freed


# Persist everything the resident dimension owns. Split out of the
# autosave path so a transition can save the SOURCE dimension explicitly,
# before DimensionContext switches and the default dimension argument
# starts resolving to the destination.
func save_dimension(dimension: int) -> void:
	if not _disk_writes_allowed():
		return
	flush_dirty_loaded()
	SaveLoad.flush_all_regions()
	EntitySave.save_all(self, "", dimension)
	# The portal hint cache. Losing it costs a slower first search, never
	# a wrong destination — but persisting it is what stops every reload
	# from re-walking the world to find portals the player already built.
	if PortalIndex.is_dirty(dimension):
		PortalIndex.save("", dimension)


# Move the world from one dimension to another as a single transaction.
#
# Batch 1 wires no gameplay caller: the portal drives this in Batch 7.
# What exists now is the transaction itself, so the persistence and
# isolation guarantees can be proven before anything depends on them.
#
# Ordering follows plan §7.2. The epoch bump comes FIRST, before any
# teardown, so a worker that lands mid-unload is already rejectable
# rather than racing the clear.
#
# Returns false and restores the source dimension if the destination has
# no provider — the plan requires a failure to leave a coherent world
# rather than a half-switched one.
func transition_to_dimension(target_dimension: int, arrival_position: Vector3) -> bool:
	if _in_dimension_transition:
		push_warning("[ChunkManager] dimension transition already in progress")
		return false
	var source: int = DimensionContext.active()
	if target_dimension == source:
		return true
	if not DimensionContext.is_registered(target_dimension):
		push_error("[ChunkManager] no provider for dimension %d" % target_dimension)
		return false
	_in_dimension_transition = true

	# 1. Invalidate in-flight work before anything else changes.
	DimensionContext.begin_transition()
	# 2. Persist the source while its dimension is still the active one.
	save_dimension(source)
	if _player != null and _disk_writes_allowed():
		PlayerSave.save_player(_player)
	# 3. Tear down the source scene and every dimension-owned structure.
	_free_dimension_scene()
	_clear_dimension_owned_state()
	# 4. Switch. From here the default dimension argument resolves to the
	#    destination, so every path/cache lookup lands in the new
	#    namespace.
	DimensionContext.set_active(target_dimension)
	# 5. Region cache entries are dimension-keyed, but dropping them keeps
	#    the memory profile of a transition flat rather than cumulative.
	SaveLoad.clear_cache()
	#    The destination's portal hints, on the other hand, are exactly
	#    what the next step needs — load them before anything searches.
	PortalIndex.load_index("", target_dimension)
	# 6. Place the player and rebuild the streaming centre around them, so
	#    the first ring generates where they actually land.
	if _player != null:
		_player.global_position = arrival_position
		if _player is CharacterBody3D:
			(_player as CharacterBody3D).velocity = Vector3.ZERO
	_initial_load_center = Vector2i(
		int(floor(arrival_position.x / float(Chunk.SIZE_X))),
		int(floor(arrival_position.z / float(Chunk.SIZE_Z)))
	)
	_cached_player_chunk = _initial_load_center
	# 7. Load the destination's entities, then let the normal per-frame
	#    streaming fill the ring.
	EntitySave.load_all(self, "", target_dimension)
	_update_chunk_set()
	# The renderer's instance list names cells in the dimension we just
	# left. Rebuilding against the destination's index clears it and picks
	# up whatever portal the player arrived through.
	if _portal_renderer != null and is_instance_valid(_portal_renderer):
		_portal_renderer.call("rebuild")
	_in_dimension_transition = false
	return true


func flush_dirty_loaded() -> int:
	if not _disk_writes_allowed():
		return 0
	# Union _dirty_loaded with chunks that have live tile entities.
	# Chest / furnace content changes mutate the singletons directly via
	# the inventory UI — there's no set_world_block hook to flag the
	# chunk dirty. So we'd miss content-only edits if we only looked at
	# _dirty_loaded. get_active_chunks() on each singleton is O(N) over
	# its entries; small for realistic worlds.
	var coords_to_flush: Dictionary = {}
	for coord: Vector2i in _dirty_loaded.keys():
		coords_to_flush[coord] = true
	for coord: Vector2i in ChestStorage.get_active_chunks():
		coords_to_flush[coord] = true
	for coord: Vector2i in FurnaceManager.get_active_chunks():
		coords_to_flush[coord] = true
	for coord: Vector2i in SignStorage.get_active_chunks():
		coords_to_flush[coord] = true
	for coord: Vector2i in JukeboxStorage.get_active_chunks():
		coords_to_flush[coord] = true
	var written: int = 0
	for coord: Vector2i in coords_to_flush.keys():
		if not _chunks.has(coord):
			continue
		var chunk: Chunk = _chunks[coord].chunk
		var entry: Dictionary = _build_chunk_save_entry(coord, chunk, false)
		_SAVE_LOAD.save_chunk(coord, entry)
		written += 1
	# Clear the dirty set — these chunks are now in sync with disk. If
	# the player edits more cells later, set_world_block re-flags them.
	_dirty_loaded.clear()
	return written


# Build the saved entry dict for a chunk. `destructive=true` (eviction
# path) takes pending ticks out of the scheduler and clears chest /
# furnace state from the singletons. `destructive=false` (autosave +
# save-and-quit) copies pending ticks (peek) and leaves singletons
# alone so the live chunk keeps working after the save.
func _build_chunk_save_entry(coord: Vector2i, chunk: Chunk, destructive: bool) -> Dictionary:
	var tile_entities: Dictionary = {}
	# serialize_chunk is read-only on both singletons — safe to call in
	# either mode. Only the forget_chunk calls below distinguish.
	var chest_data: Dictionary = ChestStorage.serialize_chunk(coord)
	for local_pos: Vector3i in chest_data:
		tile_entities[local_pos] = {"type": "chest", "items": chest_data[local_pos]}
	var furnace_data: Dictionary = FurnaceManager.serialize_chunk(coord)
	for local_pos: Vector3i in furnace_data:
		tile_entities[local_pos] = {"type": "furnace", "data": furnace_data[local_pos]}
	var sign_data: Dictionary = SignStorage.serialize_chunk(coord)
	for local_pos: Vector3i in sign_data:
		tile_entities[local_pos] = {"type": "sign", "lines": sign_data[local_pos]}
	var jukebox_data: Dictionary = JukeboxStorage.serialize_chunk(coord)
	for local_pos: Vector3i in jukebox_data:
		tile_entities[local_pos] = {"type": "jukebox", "disc": jukebox_data[local_pos]}
	var spawner_data: Dictionary = MobSpawnerManager.serialize_chunk(coord)
	for local_pos: Vector3i in spawner_data:
		tile_entities[local_pos] = {"type": "spawner", "mob": spawner_data[local_pos]}
	if destructive:
		ChestStorage.forget_chunk(coord)
		FurnaceManager.forget_chunk(coord)
		SignStorage.forget_chunk(coord)
		JukeboxStorage.forget_chunk(coord)
		MobSpawnerManager.forget_chunk(coord)
	var pending_ticks: Array
	if destructive:
		pending_ticks = TickScheduler.take_for_chunk(coord.x, coord.y)
	else:
		pending_ticks = TickScheduler.peek_for_chunk(coord.x, coord.y)
	return {
		"bytes": chunk.blocks.compress(_COMPRESS_MODE),
		"block_meta": chunk.block_meta.compress(_COMPRESS_MODE),
		"sky_light": chunk.sky_light.compress(_COMPRESS_MODE),
		"block_light": chunk.block_light.compress(_COMPRESS_MODE),
		"height_map": chunk.height_map.compress(_COMPRESS_MODE),
		"max_y": chunk.max_y,
		"pending_ticks": pending_ticks,
		"tile_entities": tile_entities,
	}


# Worker-thread decoder for a saved entry: decompresses + rescans into a
# Chunk and collects sapling positions for main-thread re-enqueue. Returns
# [chunk: Chunk, saplings: Array[Vector3i]]. The main-thread side effects
# (TickScheduler.restore_ticks + _enqueue_sapling_growth) are applied later
# in _materialize_chunk; this function only touches the local Chunk it
# constructs, so it's safe to run off the main thread.
static func _decode_saved_entry(coord: Vector2i, entry: Dictionary) -> Array:
	var c := Chunk.new()
	var blocks: PackedByteArray = (entry.bytes as PackedByteArray).decompress(
		Chunk.TOTAL_BLOCKS, _COMPRESS_MODE
	)
	# Torn/corrupt save entry — decompress returns a short (usually
	# empty) array on failure. Seen in the wild on web: closing the tab
	# mid-IndexedDB sync tears the region write. The old behavior
	# materialized the chunk as a permanent all-air hole AND re-persisted
	# it on evict, making the damage permanent. Deterministic worldgen
	# means we can do better: regenerate the chunk from the seed — only
	# that chunk's player edits are lost, and the world self-heals on
	# the next load instead of keeping a void pit.
	if blocks.size() != Chunk.TOTAL_BLOCKS:
		push_warning("[chunk_mgr] corrupt saved chunk %s — regenerating from seed" % coord)
		DebugLog.add(
			DebugLog.CHUNK,
			(
				"corrupt saved chunk (%d,%d) — regenerated from seed (edits in that chunk lost)"
				% [coord.x, coord.y]
			)
		)
		return [Worldgen.generate_chunk(coord.x, coord.y), []]
	c.blocks = blocks
	c.max_y = entry.max_y
	# Light arrays — older save entries (from before slice 1 lighting
	# landed) won't have these keys; fall through to Chunk._init's defaults
	# (sky=15 everywhere, block=0) for backward compatibility with any
	# in-memory caches still holding pre-lighting payloads.
	if entry.has("sky_light"):
		var sky: PackedByteArray = (entry.sky_light as PackedByteArray).decompress(
			Chunk.TOTAL_BLOCKS, _COMPRESS_MODE
		)
		if sky.size() == Chunk.TOTAL_BLOCKS:
			c.sky_light = sky
	if entry.has("block_light"):
		var blk: PackedByteArray = (entry.block_light as PackedByteArray).decompress(
			Chunk.TOTAL_BLOCKS, _COMPRESS_MODE
		)
		if blk.size() == Chunk.TOTAL_BLOCKS:
			c.block_light = blk
	# Block metadata — required once flow-fluid landed in Flow #1. Older
	# saves without the key fall through to Chunk._init's zero defaults,
	# which is still correct for any block that was ID-only (pre-flow).
	if entry.has("block_meta"):
		var meta: PackedByteArray = (entry.block_meta as PackedByteArray).decompress(
			Chunk.TOTAL_BLOCKS, _COMPRESS_MODE
		)
		if meta.size() == Chunk.TOTAL_BLOCKS:
			c.block_meta = meta
	# Heightmap — restore when present, else flag dirty so the next
	# is_sky_exposed call rebuilds from raw blocks. Saves a 32 KB rescan
	# on every chunk reload from save cache.
	if entry.has("height_map"):
		var hm: PackedByteArray = (entry.height_map as PackedByteArray).decompress(
			Chunk.SIZE_X * Chunk.SIZE_Z, _COMPRESS_MODE
		)
		if hm.size() == Chunk.SIZE_X * Chunk.SIZE_Z:
			c.height_map = hm
			c._height_map_dirty = false
		else:
			c._height_map_dirty = true
	else:
		c._height_map_dirty = true
	# Rescan non-cube + chest flags, collect sapling positions, and pick
	# the topmost SUGAR_CANE per column for the cane growth queue. All four
	# bookkeeping passes fold into one linear walk so worker decode stays
	# O(N) over chunk.blocks.
	var saplings: Array[Vector3i] = []
	var cane_top_y: Dictionary = {}  # Vector2i(lx, lz) -> highest ly seen
	var found_non_cube: bool = false
	var found_chest: bool = false
	var found_sign: bool = false
	for i in range(c.blocks.size()):
		var b: int = c.blocks[i]
		if b == Blocks.CHEST:
			found_chest = true
		if b == Blocks.SIGN_STANDING or b == Blocks.SIGN_WALL:
			found_sign = true
		if Blocks.needs_gdscript_mesher(b):
			found_non_cube = true
			var lx: int = i % Chunk.SIZE_X
			var lz: int = (i / Chunk.SIZE_X) % Chunk.SIZE_Z
			var ly: int = i / (Chunk.SIZE_X * Chunk.SIZE_Z)
			if b == Blocks.SAPLING:
				saplings.append(
					Vector3i(coord.x * Chunk.SIZE_X + lx, ly, coord.y * Chunk.SIZE_Z + lz)
				)
			elif b == Blocks.SUGAR_CANE:
				var key := Vector2i(lx, lz)
				if not cane_top_y.has(key) or int(cane_top_y[key]) < ly:
					cane_top_y[key] = ly
	c.has_non_cube_blocks = found_non_cube
	c.has_chest_blocks = found_chest
	# Without this rescan, chunks loaded from disk had has_sign_blocks=false
	# even when the blocks array contained sign cells, so chunk_node's
	# `if chunk.has_sign_blocks` gate skipped _sync_sign_entities entirely
	# → no SignNode children spawned → labels never rendered, even though
	# SignStorage had the text (which is why the editor still showed it).
	c.has_sign_blocks = found_sign
	# Materialize the per-column cane tops into world coords.
	for key: Vector2i in cane_top_y:
		c.cane_tops.append(
			Vector3i(
				coord.x * Chunk.SIZE_X + key.x, int(cane_top_y[key]), coord.y * Chunk.SIZE_Z + key.y
			)
		)
	return [c, saplings]


# Re-enable physics only on chunks within collision_radius of the player
# (Chebyshev / square ring). Skips unless the player actually crossed a
# chunk boundary, so cost is O(loaded) at most once per crossing.
# Re-run the collision-activation sweep against the player's CURRENT
# position, immediately. The per-frame path only sweeps when the cached
# player chunk changes, and a portal arrival moves the player and needs
# the ground under them active on the same frame control is returned.
func refresh_collision_activity() -> void:
	if _player == null:
		return
	_cached_player_chunk = _player_chunk_coord()
	_last_collision_center = Vector2i(2147483647, 2147483647)
	_update_collision_activity()


func _update_collision_activity() -> void:
	var pc := _cached_player_chunk
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


# Batch begin — defers per-edit lighting so a multi-block operation
# (explosion, fluid cascade, future area-fill commands) converges through
# one shared multi-source queue per channel. Calls nest safely: only the
# outermost flush drains the seeds.
func begin_batch() -> void:
	_light_defer_depth += 1


# Batch end — drains accumulated sky/block-light seeds through exactly one
# multi-source convergence pass per non-empty channel.
func end_batch() -> void:
	if _light_defer_depth <= 0:
		push_error("ChunkManager.end_batch called without matching begin_batch")
		_light_defer_depth = 0
		return
	_light_defer_depth -= 1
	if _light_defer_depth > 0:
		return
	_flush_deferred_updates()


# Snapshot and clear deferred state before propagation. Clearing first keeps
# nested callbacks safe: any new edits triggered during the flush become a
# fresh batch instead of mutating the dictionaries being iterated.
func _flush_deferred_updates() -> void:
	var sky_positions: Array[Vector3i] = []
	var block_positions: Array[Vector3i] = []
	for world_pos: Vector3i in _deferred_sky_seeds:
		sky_positions.append(world_pos)
	for world_pos: Vector3i in _deferred_block_seeds:
		block_positions.append(world_pos)
	var fizz_positions: Array = _deferred_fizz.duplicate()
	_deferred_sky_seeds.clear()
	_deferred_block_seeds.clear()
	_deferred_fizz.clear()
	Lighting.update_sky_light_around_world_many(sky_positions, self)
	Lighting.update_block_light_around_world_many(block_positions, self)
	FluidFx.flush_deferred_fizz(self, fizz_positions)


# World-coord block edit. Looks up the right chunk, converts to local coords,
# applies. Silently no-ops if the target is outside the currently loaded area.
# Marks the chunk as "modified" so it's preserved across unload/reload.
func set_world_block(world_pos: Vector3i, id: int, meta: int = -1) -> void:
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return
	var local_x: int = world_pos.x - chunk_x * Chunk.SIZE_X
	var local_z: int = world_pos.z - chunk_z * Chunk.SIZE_Z
	var chunk_node: Node3D = _chunks[coord]
	var old_id: int = chunk_node.chunk.get_block(local_x, world_pos.y, local_z)
	var old_meta: int = chunk_node.chunk.get_block_meta(local_x, world_pos.y, local_z)
	chunk_node.chunk.set_block(local_x, world_pos.y, local_z, id)
	# `meta >= 0` commits metadata in the SAME step as the id, before any
	# side effect below runs. Chunk.set_block zeros meta by vanilla
	# parity, so the old set_world_block_with_meta patched it afterwards —
	# which meant every callback in this function (lighting, gravity,
	# fluid notify, and now redstone) observed meta 0 on a block whose
	# real state was already different. A redstone torch changing id
	# on↔off would have looked floor-mounted to its own neighbors for the
	# duration of the fanout. Default -1 preserves the zeroing behavior
	# for the many callers that don't care.
	if meta >= 0:
		chunk_node.chunk.set_block_meta(local_x, world_pos.y, local_z, meta & 0xF)
	_dirty_loaded[coord] = true
	# Priority-apply flag — the upcoming worker re-mesh result skips the
	# 1-per-frame apply budget queue. Without this, player edits at FAR
	# render distance can hang behind background relight-driven re-meshes
	# for many seconds (ghost-block bug). chunk_node clears the flag on
	# apply.
	#
	# NOT during a batch. A batch is by definition a bulk edit — an
	# explosion, a fluid cascade, an area fill — and it can dirty several
	# chunks in one call. Forcing every one of them past the budget lands
	# all their re-meshes AND their collision cooks in a single frame, and
	# a cook alone is 3-8 ms, so a ghast fireball straddling four chunks
	# becomes a multi-frame stall. Bulk edits ride the budget and spread
	# over consecutive frames instead; the interactive single-block edit
	# the flag was written for still jumps the queue.
	if _light_defer_depth == 0:
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
	# Gravity — when a block becomes air OR fluid, settle anything gravity-
	# affected (sand, gravel) sitting above. Single-pass column scan, no
	# recursion. Then notify the 6 direct neighbors so gravel floating from
	# worldgen (air already below it) collapses on the first adjacent break
	# — same trigger as vanilla BlockFalling.doPhysics neighbor updates.
	# The fluid arm covers water flowing INTO the cell under a sand block:
	# fluid writes route through set_world_block_with_meta → here, and
	# without it the sand kept treating the new water as support.
	if id == Blocks.AIR or Blocks.is_fluid(id):
		_settle_gravity_above(coord, local_x, world_pos.y, local_z)
		_notify_gravity_neighbors(world_pos)
	# Vanilla BlockSand.onBlockAdded — a gravity block PLACED over a non-
	# supporting cell (air, fire, liquid) starts falling immediately;
	# without this, placed sand floats until some neighbor update. The
	# settle helper clears the just-written cell and hands it to a
	# FallingBlock. The light BFS below recomputes from the live grid
	# (which holds AIR again by then), so the transient write costs one
	# extra — still correct — relight, nothing more. MUST use the
	# entity's own passability here: is_replaceable includes saplings,
	# which STOP a fall, so triggering on them spawned an entity that
	# landed straight back into this cell and re-triggered forever.
	elif Blocks.has_gravity(id) and world_pos.y > 0:
		var support_id: int = get_world_block(world_pos + Vector3i(0, -1, 0))
		if FallingBlock.is_passable_for_fall(support_id):
			_settle_gravity_above(coord, local_x, world_pos.y - 1, local_z)
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
	# Deferred during a batch (begin_batch / end_batch) so an N-block
	# explosion runs the BFS once per unique seed at flush time instead
	# of N times inline.
	var em_diff: bool = Blocks.light_emission(old_id) != Blocks.light_emission(id)
	var op_diff: bool = Blocks.light_opacity(old_id) != Blocks.light_opacity(id)
	if old_id != id and (em_diff or op_diff):
		if _light_defer_depth > 0:
			_deferred_block_seeds[world_pos] = true
		else:
			Lighting.update_block_light_around_world(world_pos, self)
	# Plant detach — vanilla BlockPlant.doPhysics fires when a neighbor
	# changes; if the support directly below is no longer grass/dirt/
	# farmland, the plant pops off and drops itself. We trigger on any
	# write at world_pos that invalidates the support of a plant in the
	# cell directly above. Cheap: one lookup, one is_valid check.
	if not Blocks.is_valid_plant_support(id):
		_drop_plant_if_unsupported(coord, local_x, world_pos.y + 1, local_z)
	# Ladder / torch neighbor update — when a block becomes non-opaque,
	# attached ladders and torches on the 4 horizontal faces lose their
	# support and should pop off (vanilla ca.java:a / ob.java:a).
	if old_id != id and Blocks.is_opaque(old_id) and not Blocks.is_opaque(id):
		_drop_unsupported_wall_blocks(world_pos)
	# Sapling growth queue — when a sapling is placed (player drop or
	# bonemeal-spawn later), schedule it for a future tree growth tick.
	if id == Blocks.SAPLING:
		_enqueue_sapling_growth(world_pos)
	# Sugar cane growth — only enqueue when a NEW top is being created
	# (no cane above), which covers worldgen scatter, player placement,
	# and the recursive enqueue from _tick_cane_growth itself.
	if id == Blocks.SUGAR_CANE:
		var above_id: int = get_world_block(world_pos + Vector3i(0, 1, 0))
		if above_id != Blocks.SUGAR_CANE:
			_enqueue_cane_growth(world_pos)
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
	# Redstone fanout for ANY id change, however it was caused — player
	# edit, explosion, fluid washout, falling block. Without this an
	# explosion could take out a lever and leave the door it was driving
	# stuck open. Cheap when no redstone is nearby: the drain dispatches
	# one match per cell.
	if old_id != id:
		# A switch that goes away while still ON has to push one last
		# update around the block it was mounted on — vanilla's
		# Block.onBlockRemoval (pl.java:160-175). The seven cells above
		# cover its own neighbourhood; this covers the mount's, which is
		# where its strong power was actually going. Without it, blowing
		# up or washing away a lever leaves whatever it drove THROUGH its
		# mount stuck in the powered state.
		Redstone.on_block_removed(self, world_pos, old_id, old_meta)
		enqueue_block_notification(world_pos)
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
	# Coalesce per-frame: many FallingBlocks landing in the same chunk
	# (TNT on a sand pile lands 50+ entities the same frame) used to
	# trigger N full-chunk mesh rebuilds inline — each ~10–50 ms. We
	# now mark the chunk for deferred rebuild and dedup via the dict;
	# call_deferred fires before the frame renders, so the "block
	# appears same frame as entity hides" guarantee still holds and a
	# burst pays one rebuild per chunk instead of N.
	if not _pending_immediate_rebuild.has(coord):
		_pending_immediate_rebuild[coord] = true
		call_deferred("_flush_immediate_rebuild", coord)


# Public same-frame rebuild — mesh AND collision, synchronously. The
# portal teleporter carves its arrival structure with bare
# set_world_block calls, which mark flags but leave the actual remesh to
# the caller; without this, the carved doorway existed only in block
# data while the chunk's mesh and collision stayed virgin solid rock —
# the player arrived entombed in terrain that was no longer really
# there (field report #3: frozen in the Nether, zero displacement under
# full walk velocity).
func rebuild_chunk_now(coord: Vector2i) -> void:
	_flush_immediate_rebuild(coord)


# Drained at end of frame for each unique chunk that received an
# immediate write. See set_world_block_immediate.
func _flush_immediate_rebuild(coord: Vector2i) -> void:
	_pending_immediate_rebuild.erase(coord)
	if not _chunks.has(coord):
		return
	var chunk_node: Node3D = _chunks[coord]
	chunk_node._apply_mesh_data(Mesher.mesh_chunk_fast(chunk_node.chunk))
	# Same-frame collision is this path's contract (falling-block landings
	# swap entity → block mid-frame), so flush the deferred cook now.
	chunk_node._cook_pending_collision()
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
	var to_spawn: Array[Vector2i] = []  # (y, block_id) pairs
	while scan_y < Chunk.SIZE_Y:
		var here_id: int = chunk.get_block(local_x, scan_y, local_z)
		if here_id == Blocks.AIR:
			scan_y += 1
			continue
		if not Blocks.has_gravity(here_id):
			break
		chunk.set_block(local_x, scan_y, local_z, Blocks.AIR)
		to_spawn.append(Vector2i(scan_y, here_id))
		scan_y += 1
	if to_spawn.is_empty():
		return
	# Single rebuild for the entire column instead of one per block.
	var chunk_node: Node3D = _chunks[coord]
	chunk_node.rebuild_mesh_immediate()
	for pair: Vector2i in to_spawn:
		_spawn_falling_block(Vector3i(world_x, pair.x, world_z), pair.y)


# Vanilla BlockFalling.doPhysics — when any neighbor changes, a gravity
# block rechecks its own support. We fire this after a block becomes AIR
# so adjacent gravel/sand that was already floating (worldgen caves) gets
# its first neighbor update and collapses. Cheap: 6 block lookups + 6
# below-neighbor lookups.
func _notify_gravity_neighbors(world_pos: Vector3i) -> void:
	const OFFSETS: Array[Vector3i] = [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1),
	]
	for offset: Vector3i in OFFSETS:
		var np: Vector3i = world_pos + offset
		var nid: int = get_world_block(np)
		if not Blocks.has_gravity(nid):
			continue
		var below_id: int = get_world_block(np + Vector3i(0, -1, 0))
		# Same passability as the falling entity (vanilla canFallBelow:
		# air/fire/liquids). is_replaceable was too wide — saplings are
		# replaceable but stop a falling block, so triggering on them
		# spawned an entity that landed straight back into its own cell.
		if not FallingBlock.is_passable_for_fall(below_id):
			continue
		var cx: int = int(floor(float(np.x) / float(Chunk.SIZE_X)))
		var cz: int = int(floor(float(np.z) / float(Chunk.SIZE_Z)))
		var coord := Vector2i(cx, cz)
		if not _chunks.has(coord):
			continue
		var lx: int = np.x - cx * Chunk.SIZE_X
		var lz: int = np.z - cz * Chunk.SIZE_Z
		_settle_gravity_above(coord, lx, np.y - 1, lz)


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
	# Cross-quad plants AND the snow-layer slab pop off on support change
	# (vanilla BlockSnow drops + dies if the cell below isn't a solid top).
	# Other shapes (cubes, fences, doors) stay put.
	var ms: int = Blocks.mesh_shape(here_id)
	if ms != Blocks.MESH_SHAPE_CROSS and ms != Blocks.MESH_SHAPE_SNOW_LAYER:
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


# Vanilla ca.java:a / ob.java:a — when a block becomes non-opaque, scan
# the 4 horizontal neighbors for ladders/torches that used it as their
# support wall. If found and the support is gone, pop them off as drops.
func _drop_unsupported_wall_blocks(removed_pos: Vector3i) -> void:
	# Ladder meta → support offset: meta 2 → +Z, 3 → -Z, 4 → +X, 5 → -X.
	# Torch meta → support offset: meta 1 → -X, 2 → +X, 3 → -Z, 4 → +Z, 5 → floor.
	const HORIZ_OFFSETS: Array[Vector3i] = [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1),
	]
	for off: Vector3i in HORIZ_OFFSETS:
		var np: Vector3i = removed_pos + off
		var nid: int = get_world_block(np)
		if nid == Blocks.LADDER:
			var meta: int = get_world_block_meta(np)
			var support_off: Vector3i
			match meta:
				2:
					support_off = Vector3i(0, 0, 1)
				3:
					support_off = Vector3i(0, 0, -1)
				4:
					support_off = Vector3i(1, 0, 0)
				5:
					support_off = Vector3i(-1, 0, 0)
				_:
					continue
			if np + support_off == removed_pos:
				set_world_block(np, Blocks.AIR)
				_spawn_dropped_item(np, Blocks.LADDER)
		elif nid == Blocks.TORCH:
			var meta: int = get_world_block_meta(np)
			var support_off: Vector3i
			match meta:
				1:
					support_off = Vector3i(-1, 0, 0)
				2:
					support_off = Vector3i(1, 0, 0)
				3:
					support_off = Vector3i(0, 0, -1)
				4:
					support_off = Vector3i(0, 0, 1)
				_:
					continue
			if np + support_off == removed_pos:
				set_world_block(np, Blocks.AIR)
				_spawn_dropped_item(np, Blocks.TORCH)


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
# cell still holds a sapling, the support is still valid, and Alpha's
# combined light above the sapling is at least 9 (ej.java). On success:
# place an oak tree centered at the sapling's cell.
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
		var light_ok: bool = get_world_effective_light(pos + Vector3i(0, 1, 0)) >= 9
		if not support_ok:
			# Detach hook will (or did) fire from set_world_block; nothing
			# more to do here — let the sapling drop normally.
			processed += 1
			if processed >= _SAPLING_GROW_MAX_PER_TICK:
				return
			continue
		if not light_ok:
			# Too dark — no growth this round, try again later.
			_growing_saplings.append({"pos": pos, "grow_at": now + _SAPLING_GROW_RETRY_SEC})
			processed += 1
			if processed >= _SAPLING_GROW_MAX_PER_TICK:
				return
			continue
		grow_tree_at(pos)
		processed += 1
		if processed >= _SAPLING_GROW_MAX_PER_TICK:
			return


# Sugar cane growth — vanilla BlockReed.b(). On growth, replaces the
# AIR cell above the cane with another SUGAR_CANE if the column is
# under max height (3) and water is adjacent at the BASE of the
# column. Re-enqueues the new top so it can grow further later. If
# blocked (no air, max height, support gone), re-enqueues with retry
# delay; eventually drops out when the cane is broken.
func _enqueue_cane_growth(pos: Vector3i) -> void:
	var u: float = maxf(randf(), 0.0001)
	var delay: float = clampf(-_CANE_GROW_MEAN_SEC * log(u), _CANE_GROW_MIN_SEC, _CANE_GROW_MAX_SEC)
	var now: float = Time.get_ticks_msec() / 1000.0
	_growing_canes.append({"pos": pos, "grow_at": now + delay})


# Walk down from `pos` to find the base of the cane column.
func _cane_column_base(pos: Vector3i) -> Vector3i:
	var p := pos
	while p.y > 0 and get_world_block(p + Vector3i(0, -1, 0)) == Blocks.SUGAR_CANE:
		p.y -= 1
	return p


# Cane needs water at the base column-1 (per BlockReed.canPlace), one
# of the 4 cardinal cells at base.y - 1. Mirrors vanilla's placement
# check, applied at growth time too.
func _cane_base_has_water(base_pos: Vector3i) -> bool:
	var below_y: int = base_pos.y - 1
	for off: Vector3i in [
		Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)
	]:
		var p: Vector3i = Vector3i(base_pos.x + off.x, below_y, base_pos.z + off.z)
		if Blocks.is_water(get_world_block(p)):
			return true
	return false


# gdlint: disable=max-returns
func _tick_cane_growth() -> void:
	if _growing_canes.is_empty():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var processed: int = 0
	for i in range(_growing_canes.size() - 1, -1, -1):
		var entry: Dictionary = _growing_canes[i]
		if entry.grow_at > now:
			continue
		_growing_canes.remove_at(i)
		var pos: Vector3i = entry.pos
		var here: int = get_world_block(pos)
		if here != Blocks.SUGAR_CANE:
			# Player broke the top cane — drop the entry; if a lower
			# cane is now the top, the next set_world_block on its
			# placement re-enqueues.
			processed += 1
			if processed >= _CANE_GROW_MAX_PER_TICK:
				return
			continue
		# Only the topmost cane in a column grows.
		if get_world_block(pos + Vector3i(0, 1, 0)) == Blocks.SUGAR_CANE:
			# Stale top — the column grew above this cell already.
			processed += 1
			if processed >= _CANE_GROW_MAX_PER_TICK:
				return
			continue
		# Column height check.
		var base: Vector3i = _cane_column_base(pos)
		var height: int = pos.y - base.y + 1
		if height >= _CANE_MAX_HEIGHT:
			# Already at max — give up on this stalk; vanilla random
			# tick would also no-op forever.
			processed += 1
			if processed >= _CANE_GROW_MAX_PER_TICK:
				return
			continue
		# Air above?
		var above: Vector3i = pos + Vector3i(0, 1, 0)
		if get_world_block(above) != Blocks.AIR:
			_growing_canes.append({"pos": pos, "grow_at": now + _CANE_GROW_RETRY_SEC})
			processed += 1
			if processed >= _CANE_GROW_MAX_PER_TICK:
				return
			continue
		# Base must still have water adjacent (vanilla BlockReed.canPlace).
		if not _cane_base_has_water(base):
			processed += 1
			if processed >= _CANE_GROW_MAX_PER_TICK:
				return
			continue
		set_world_block(above, Blocks.SUGAR_CANE)
		_enqueue_cane_growth(above)
		processed += 1
		if processed >= _CANE_GROW_MAX_PER_TICK:
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


# True when the chunk owning this world X/Z is resident.
#
# Callers that scan a volume need this because get_world_block cannot
# distinguish "air" from "not loaded" — both read as AIR. The portal
# search uses it to skip whole 128-deep columns it could never see into,
# and PortalIndex uses it to tell a stale entry from an absent chunk.
func has_chunk_at(world_x: int, world_z: int) -> bool:
	return _chunks.has(
		Vector2i(
			int(floor(float(world_x) / float(Chunk.SIZE_X))),
			int(floor(float(world_z) / float(Chunk.SIZE_Z)))
		)
	)


# Coords of every resident chunk. Used by PortalIndex.rebuild_from_loaded.
func loaded_chunk_coords() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for coord: Vector2i in _chunks.keys():
		out.append(coord)
	return out


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
	# Now a thin wrapper over the atomic path so existing callers (fluids,
	# doors, rails, beds…) stop exposing the transient meta-0 window.
	set_world_block(world_pos, id, meta)


# --- Authoritative world-state write (redstone-plan.md §7.2) ---
#
# One path for "this cell's id and/or metadata changed". Redstone
# components mutate meta WITHOUT changing id (lever bit 3, wire power
# 0-15, plate pressed), which the plain setters handle badly: a same-id
# meta change marks nothing dirty and notifies nobody, so the mesh keeps
# the stale texture and downstream consumers never re-evaluate.
#
# Contract:
#   1. No-op when neither id nor masked meta actually changes.
#   2. id + meta commit together; callbacks never see a half-applied cell.
#   3. Persistence, local mesh, and seam neighbours go dirty on either
#      kind of change.
#   4. Lighting runs off the final id (inside set_world_block) before any
#      block notification is dispatched.
#   5. Metadata-only changes still notify.
# Returns true when something actually changed.
func set_world_block_state(
	world_pos: Vector3i, new_id: int, new_meta: int, notify: bool = true
) -> bool:
	var chunk_x: int = int(floor(float(world_pos.x) / float(Chunk.SIZE_X)))
	var chunk_z: int = int(floor(float(world_pos.z) / float(Chunk.SIZE_Z)))
	var coord := Vector2i(chunk_x, chunk_z)
	if not _chunks.has(coord):
		return false
	var local_x: int = world_pos.x - chunk_x * Chunk.SIZE_X
	var local_z: int = world_pos.z - chunk_z * Chunk.SIZE_Z
	var chunk_node: Node3D = _chunks[coord]
	var chunk: Chunk = chunk_node.chunk
	var old_id: int = chunk.get_block(local_x, world_pos.y, local_z)
	var old_meta: int = chunk.get_block_meta(local_x, world_pos.y, local_z)
	var masked: int = new_meta & 0xF
	if old_id == new_id and old_meta == masked:
		return false
	if old_id != new_id:
		# Full path — every existing side effect (lighting, gravity,
		# plant detach, fluid notify) plus the atomic meta commit.
		# set_world_block already enqueues the block-update fanout for an
		# id change, so returning here avoids running it a second time.
		# `notify` therefore governs metadata-only writes; an id change
		# always fans out, which is right — the cell genuinely became
		# something else.
		set_world_block(world_pos, new_id, masked)
		return true
	# Metadata-only from here. Emission and opacity are keyed by block
	# id, so light cannot move; skip the BFS and just re-render.
	chunk.set_block_meta(local_x, world_pos.y, local_z, masked)
	_dirty_loaded[coord] = true
	chunk.dirty = true
	chunk_node.set("_priority_apply", true)
	_dirty_seam_neighbors(coord, local_x, local_z)
	if notify:
		enqueue_block_notification(world_pos)
	return true


# Mark the cardinal/diagonal chunk neighbours of a seam cell dirty so
# their meshes rebuild against the new state. Same shape as the
# edge-edit refresh inside set_world_block.
func _dirty_seam_neighbors(coord: Vector2i, local_x: int, local_z: int) -> void:
	var nx: int = -1 if local_x == 0 else (1 if local_x == Chunk.SIZE_X - 1 else 0)
	var nz: int = -1 if local_z == 0 else (1 if local_z == Chunk.SIZE_Z - 1 else 0)
	for off: Vector2i in [Vector2i(nx, 0), Vector2i(0, nz), Vector2i(nx, nz)]:
		if off == Vector2i.ZERO:
			continue
		var target: Vector2i = coord + off
		if _chunks.has(target):
			_chunks[target].chunk.dirty = true


# Queue the changed cell + its 6 neighbours for block-update dispatch.
# Deduplicated on "currently queued", NOT "already processed": a cell
# whose inputs change again must be eligible for re-evaluation or a
# network can settle on a stale value. Unlike the fluid guard, a nested
# write during the drain does not drop its fanout — it lands in the same
# queue and the outer loop keeps going to a fixpoint.
# `source_id` defaults to whatever now occupies the changed cell, which
# is what vanilla passes (setBlockWithNotify → notifyBlockChange with the
# new id). Breaking a component therefore reports AIR, and the consumers
# that demand a power-capable source correctly decline.
# Bracket a multi-cell structure write — vanilla `cy.i = true/false`.
# Callers that may receive a test double check has_method first.
func begin_block_edit() -> void:
	_editing_blocks = true


func end_block_edit() -> void:
	_editing_blocks = false


func enqueue_block_notification(world_pos: Vector3i, source_id: int = -1) -> void:
	# Vanilla `cy.h()` checks editingBlocks before notifying — writes and
	# lighting proceed; only the neighbour fanout is held. See
	# _editing_blocks for why the portal cannot survive without this.
	if _editing_blocks:
		return
	var source: int = get_world_block(world_pos) if source_id < 0 else source_id
	for offset: Vector3i in _NOTIFY_OFFSETS:
		var cell: Vector3i = world_pos + offset
		var event := Vector4i(cell.x, cell.y, cell.z, source)
		if _notify_queued.has(event):
			continue
		_notify_queued[event] = true
		_notify_queue.append(event)
	if not _notify_draining:
		drain_block_notifications()


# Drain up to `_NOTIFY_BUDGET_PER_DRAIN` positions. Hitting the budget
# PAUSES — the remainder stays queued and `_process` resumes it next
# frame. Work is never discarded; a partially-updated network would be
# worse than a late one.
func drain_block_notifications() -> void:
	if _notify_draining:
		return
	_notify_draining = true
	var budget: int = _NOTIFY_BUDGET_PER_DRAIN
	while not _notify_queue.is_empty() and budget > 0:
		var event: Vector4i = _notify_queue.pop_front()
		_notify_queued.erase(event)
		budget -= 1
		var cell := Vector3i(event.x, event.y, event.z)
		Redstone.on_neighbor_changed(self, cell, event.w)
		# x.java:75 — a portal cell re-validates its frame on every
		# neighbour change and clears only ITSELF when the frame is gone.
		# Riding the same queue is what makes the sheet dissolve one cell
		# at a time: each clear enqueues its own neighbourhood, so breaking
		# one obsidian block propagates outward without a flood fill and
		# without touching an unrelated portal one block away. Costs a
		# single block read per event on the overwhelming majority of
		# worlds that contain no portal at all.
		NetherPortal.on_neighbor_change(self, cell)
	_notify_draining = false


func pending_notification_count() -> int:
	return _notify_queue.size()


# Redstone's contract check: this manager pumps paused wire bursts from
# `_process`, so `Redstone.update_wire` may hand back a partially drained
# network instead of blocking the frame until it settles.
func redstone_defers_wire_bursts() -> bool:
	return true


# Re-run wire propagation for every wire cell on a freshly materialised
# chunk's four seams. Cheap in the common case (no wire on the border →
# no work at all) and the only thing that can repair a circuit whose
# source changed while this chunk was on disk.
func _reconcile_redstone_edges(coord: Vector2i, chunk: Chunk) -> void:
	# Fast bail: one native scan of the 32 KB block array. Chunk
	# streaming materialises many chunks per second and virtually none of
	# them contain wire, so this keeps the seam walk off the hot path
	# entirely rather than paying 8192 bounds-checked reads per chunk.
	if chunk.blocks.find(Blocks.REDSTONE_WIRE) == -1:
		return
	var origin_x: int = coord.x * Chunk.SIZE_X
	var origin_z: int = coord.y * Chunk.SIZE_Z
	for y in range(Chunk.SIZE_Y):
		for i in range(Chunk.SIZE_X):
			# West/east columns, then north/south rows. Corners are
			# visited twice; update_wire is idempotent so that's fine.
			for cell: Vector3i in [
				Vector3i(origin_x, y, origin_z + i),
				Vector3i(origin_x + Chunk.SIZE_X - 1, y, origin_z + i),
				Vector3i(origin_x + i, y, origin_z),
				Vector3i(origin_x + i, y, origin_z + Chunk.SIZE_Z - 1),
			]:
				var local_x: int = cell.x - origin_x
				var local_z: int = cell.z - origin_z
				if chunk.get_block(local_x, y, local_z) != Blocks.REDSTONE_WIRE:
					continue
				Redstone.update_wire(self, cell, true)


# --- Callbacks the redstone model dispatches back into the world ---
#
# Redstone.gd is a pure static module taking `manager` first, so it can
# run against a fake world in tests. Anything needing the scene tree
# (entities, audio) is invoked through has_method, which those fakes
# simply don't implement.


# Drop a broken component as an item. Public because Redstone calls it
# when a mounted block loses its support.
func spawn_block_drop(block_pos: Vector3i, dropped_id: int) -> void:
	if dropped_id == Blocks.AIR:
		return
	_spawn_dropped_item(block_pos, dropped_id)


# Redstone-triggered TNT ignition (v.java:23). Same primed-entity setup
# the fire-spread path uses, so a redstone detonation and a flint-and-
# steel detonation are indistinguishable downstream.
func prime_tnt(block_pos: Vector3i) -> void:
	var primed = _PRIMED_TNT_SCRIPT.new()
	add_child(primed)
	primed.global_position = Vector3(block_pos) + Vector3(0.5, 0.5, 0.5)
	primed.setup()
	SFX.play_fuse()


func play_door_sound(_block_pos: Vector3i) -> void:
	SFX.play_door_toggle()


# Redstone-torch burnout history for THIS world (vanilla's static
# RedstoneUpdateInfo list). Owned here rather than in Redstone so it
# dies with the world — a static one would carry a burnt-out torch's
# history into the next save you load.
func redstone_burnout_log() -> Array:
	return _redstone_burnout_log


# Entity-overlap query for pressure plates (redstone-plan.md §7.3).
# `living_only` distinguishes the two plate sensitivities: a stone plate
# takes vanilla's lg.b (players + mobs), a wooden plate lg.a (every
# physical entity — dropped items, projectiles and minecarts included).
#
# Walks the mob registry, the player, and our own entity children. The
# counts here are small (a plate box is under one cubic metre and only
# runs on contact or a 20-tick recheck), so a direct scan beats keeping
# another spatial index in sync.
func entities_overlap_box(box: AABB, living_only: bool) -> bool:
	# Vanilla asks `entity.boundingBox.intersectsWith(plateBox)`
	# (ap.java:110). Sampling an origin POINT instead is not a rounding
	# difference, it is a different test: the player's `global_position`
	# is the centre of a 1.8 m capsule, roughly 0.9 m above the feet,
	# while a plate's detection box is 0.25 m tall — so a normally
	# standing player never has their origin inside it, and no plate
	# would ever fire.
	if _player != null and is_instance_valid(_player):
		if EntityBounds.overlaps(box, _player):
			return true
	for mob: Variant in MobBase._active_mobs.keys():
		if not is_instance_valid(mob):
			continue
		if EntityBounds.overlaps(box, mob as Node3D):
			return true
	if living_only:
		return false
	# `lg.a` (wooden) takes EVERY entity; `lg.b` (stone) only living
	# ones. Scanning our children is O(loaded chunk nodes), but this only
	# runs on a wooden plate's arrival event and its 1 Hz recheck.
	for child: Node in get_children():
		if not (child is DroppedItem or child is Arrow or child is Minecart or child is Boat):
			continue
		if EntityBounds.overlaps(box, child as Node3D):
			return true
	return false


# World-space collision bounds for any entity — see `EntityBounds`, which
# owns the derivation so it can be tested against real node conventions.
func entity_world_aabb(node: Node3D) -> AABB:
	return EntityBounds.world_aabb(node)


# The player's own contact sweep. `player.gd` already fires the hook on
# its footstep cadence, but that only covers WALKING onto a cell —
# falling, jumping or riding onto a plate and then standing still fires
# no footstep, and the plate would never wake. Keyed on the occupied
# cell so a stationary player costs one Vector3i compare per frame, and
# so lit redstone ore still reverts underfoot exactly as vanilla.
func _sweep_player_block_contact() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	report_entity_contact(_player)


# Contact hook for entities that are not the player and not mobs —
# dropped items, arrows, minecarts and boats all call this from their
# own step. Fires only when the entity's bounds move into a new cell,
# because that is the event a plate actually needs: arrival wakes it,
# and its own 20-tick recheck notices the departure.
func report_entity_contact(node: Node3D) -> void:
	var box: AABB = EntityBounds.world_aabb(node)
	var cell: Vector3i = EntityBounds.contact_cell(box)
	if node.get_meta(_CONTACT_CELL_META, Vector3i(0, -9999, 0)) == cell:
		return
	node.set_meta(_CONTACT_CELL_META, cell)
	notify_entity_block_contact(node)


# Fire the shared block-contact hook for every cell this entity's bounds
# touch — vanilla `Entity.moveEntity` does the same sweep before running
# `Block.onEntityCollidedWithBlock`. Callers throttle to cell CHANGES,
# which is all a plate needs: arrival wakes it, and its own 20-tick
# recheck handles the release.
func notify_entity_block_contact(node: Node3D) -> void:
	var box: AABB = EntityBounds.world_aabb(node)
	var lo := Vector3i(floori(box.position.x), floori(box.position.y), floori(box.position.z))
	var end: Vector3 = box.position + box.size
	var hi := Vector3i(floori(end.x), floori(end.y), floori(end.z))
	for y in range(lo.y, hi.y + 1):
		for z in range(lo.z, hi.z + 1):
			for x in range(lo.x, hi.x + 1):
				Blocks.on_entity_walking(self, Vector3i(x, y, z), node)


# Vanilla plays `random.click` at volume 0.3 for every redstone
# component transition: pitch 0.6 switching on, 0.5 switching off
# (pl.java:145, iy.java:137, ap.java:96).
func play_redstone_click(_block_pos: Vector3i, on: bool) -> void:
	SFX.play_click(0.6 if on else 0.5, 0.3)


# Torch burnout effect — vanilla plays random.fizz at volume 0.5 with a
# wide pitch jitter and puffs five smoke particles.
func play_torch_burnout(block_pos: Vector3i) -> void:
	SFX.play_fizz()
	# Five motes spread over the faces around the torch, standing in for
	# vanilla's smoke puff — we have no generic smoke emitter yet, and
	# the reddust mote reads correctly at the torch tip.
	for normal: Vector3 in [
		Vector3(0, 1, 0),
		Vector3(1, 0, 0),
		Vector3(-1, 0, 0),
		Vector3(0, 0, 1),
		Vector3(0, 0, -1),
	]:
		_BLOCK_FX.spawn_reddust(self, block_pos, normal)


# Reports whether the chunk at the given chunk-space coord has fully
# loaded (live ChunkNode in the scene). Used by Player's spawn-settle
# pass so it can distinguish "AIR because the cell is genuinely empty"
# from "AIR because the chunk hasn't streamed in yet" — OOB / unloaded
# reads both return the AIR / sky=15 defaults, which without this gate
# false-positives the settle and lets a spawn-in-terrain save stay
# embedded once chunks actually arrive.
# True when the chunk under `world_pos` exists AND its collision shape
# is live. The player freezes (velocity zero, like the F2 teleport
# hold) while this is false so no load-order race — world entry,
# save-position restore, corrupt-chunk regeneration, streaming lag —
# can drop them through terrain that hasn't physically landed yet.
func is_ground_ready_at(world_pos: Vector3) -> bool:
	var coord := Vector2i(
		int(floor(world_pos.x / float(Chunk.SIZE_X))), int(floor(world_pos.z / float(Chunk.SIZE_Z)))
	)
	var node: Node3D = _chunks.get(coord)
	if node == null:
		return false
	return bool(node.call("has_live_collision"))


func is_chunk_loaded(chunk_coord: Vector2i) -> bool:
	return _chunks.has(chunk_coord)


# World-coord raw sky-light read. Horizontal unloaded chunks retain vanilla's
# sky=15 default; below the world is dark and above it is open sky.
func get_world_sky_light(world_pos: Vector3i) -> int:
	if world_pos.y < 0:
		return 0
	if world_pos.y >= Chunk.SIZE_Y:
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
	_dirty_light_border_neighbors(coord, local_x, local_z)


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


# Time-adjusted combined light for gameplay and entity rendering. Raw sky and
# block accessors remain public for propagation and direct-sky mechanics.
func get_world_effective_light(world_pos: Vector3i, sky_subtraction: int = -1) -> int:
	return WorldTime.effective_light_level(
		get_world_sky_light(world_pos), get_world_block_light(world_pos), sky_subtraction
	)


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
	_dirty_light_border_neighbors(coord, local_x, local_z)


# Border-column light writes also re-mesh the ADJACENT chunk: its seam
# faces sample this cell through the edge-light slices attached at
# re-mesh time, so without the extra dirty a torch placed/broken next
# to a seam left the neighbor's border faces at stale brightness
# (docs/lighting-chunk-seams.md, Phase 2). Cardinal only — the light
# planes don't cover diagonals. Coalesced by the per-chunk dirty flag,
# so a BFS touching many border cells costs one re-mesh per neighbor.
func _dirty_light_border_neighbors(coord: Vector2i, local_x: int, local_z: int) -> void:
	var nx: int = -1 if local_x == 0 else (1 if local_x == Chunk.SIZE_X - 1 else 0)
	var nz: int = -1 if local_z == 0 else (1 if local_z == Chunk.SIZE_Z - 1 else 0)
	for off: Vector2i in [Vector2i(nx, 0), Vector2i(0, nz)]:
		if off == Vector2i.ZERO:
			continue
		var target: Vector2i = coord + off
		if _chunks.has(target):
			_chunks[target].chunk.dirty = true


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


# Public read-only view of the loaded-chunk dict. Returns the live
# Dictionary (Vector2i → ChunkNode), NOT a copy — callers must NOT
# mutate. Used by `Blocks.run_random_tick_pass` to iterate every
# loaded chunk without depending on the private `_chunks` member.
# Cheap (no allocation); the dict is owned by ChunkManager.
func iter_loaded_chunks() -> Dictionary:
	return _chunks


# Player's current chunk coordinate, refreshed once per tick in _process.
# Used by `Blocks.run_random_tick_pass` to cap the random-tick simulation
# to a radius around the player (vanilla-style simulation distance) rather
# than ticking every loaded chunk.
func get_player_chunk_coord() -> Vector2i:
	return _cached_player_chunk


# Called by Lighting after the C++ BFS has written modified sky_light back
# into a chunk. Mirrors what set_world_sky_light does for the per-cell
# GDScript path: mark dirty for re-mesh + persistence. Single notification
# per chunk replaces N per-cell calls; cuts overhead noticeably for the
# bulk-write fast path.
# chunk_node asks before each _apply_mesh_data; false → hold the result
# for next frame. Spreads multi-chunk apply bursts over multiple frames.
func try_consume_apply_budget() -> bool:
	var budget: int = apply_budget_per_frame
	if _entry_boost_active():
		budget = apply_budget_per_frame * 3
	if _applies_this_frame >= budget:
		return false
	_applies_this_frame += 1
	# A chunk apply (ArrayMesh upload, 5-18 ms p95 on a low-end phone
	# proxy) is landing this frame — shed the next couple of tick passes
	# so the fixed costs don't stack on the same frames. Mobile web only.
	if _is_mobile_web:
		_shed_tick_frames = 2
	return true


# Drain every queued chunk_node._pending_apply NOW, ignoring the per-frame
# budget. Called by LoadingScreen right before clearing Game.is_loading so
# the entire initial-load ring has collision attached before physics
# resumes. Without this, the apply budget (1/frame) leaves ~render_distance²
# chunks with null collision shapes the moment the player drops out of
# safe_teleport — they fall through, hit y<-20, void-recovery, and re-emerge
# at world spawn ("fell through the world" on reload).
func flush_all_pending_applies() -> void:
	for coord: Vector2i in _chunks:
		var node: Node3D = _chunks[coord]
		if node != null and node.has_method("force_apply_pending"):
			node.call("force_apply_pending")


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
	# Drain at depth 0: converge both channels once, coalesce fizz cluster.
	# Vanilla's ld.java:256-261 `i()` fires per-cell, but collapsed into
	# one applyPhysics frame the audible result is one fizz anyway.
	if _light_defer_depth == 0:
		_flush_deferred_updates()


# Settings → Alpha 1.1.2 foliage toggled. Tints are material-level
# (shared chunk + overlay + entity materials), so one BlockAtlas push
# covers every loaded chunk. No re-mesh; the shader's UV gates already
# isolate the affected fragments.
func _on_alpha_vintage_foliage_changed(_enabled: bool) -> void:
	BlockAtlas.apply_foliage_tints()


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
