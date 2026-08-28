extends SceneTree

# End-to-end Nether trip probe — boots the REAL game headless and plays a
# round trip with injected input, asserting the player can actually MOVE
# at every stage.
#
# Why this exists: every Nether bug that reached a playtest passed the
# unit suite first. FakeWorld doubles have no notification cascade, so a
# portal that erased itself on creation tested clean; driving
# PortalExposure directly bypassed the detector that was lying to it, so
# the infinite enter/leave loop tested clean; and the landing-position
# tests pinned the buggy `cell.y + 0.5` as expected truth, so the
# arrival that buried the player 0.4 m inside the floor tested clean.
# Three separate bugs, all in the seams BETWEEN units.
#
# This probe spans those seams by construction: it uses the real
# ChunkManager, the real exposure meter, the real teleporter and the
# real physics body, and its only assertion is the one the player cares
# about — "can I walk?".
#
# Usage:
#   godot --headless --path . -s scripts/dev/nether_trip_probe.gd
#
# Exit codes: 0 pass, 1 harness failure, 2 frozen in the Nether,
# 3 return trip broken.
#
# Writes only to a throwaway world (see _PROBE_WORLD) which it deletes on
# the way out — never a real save. See the World1 fossil incident.

const _PROBE_WORLD: String = "NetherTripProbe"
# Displacement that counts as "the player can move". A walk of 180
# frames at WALK_SPEED covers metres; anything under this is a freeze.
const _MOVED_THRESHOLD: float = 0.5

var _player: CharacterBody3D = null
var _cm: Node = null
# Autoload singletons are NOT compile-time globals for a `-s` script —
# it replaces the MainLoop, so the autoload list has not been processed
# when this file is parsed. Resolved from the tree at runtime instead.
# (`class_name` statics like Blocks and DimensionContext do resolve.)
var _game: Node = null
# Same reason, one step further: a `-s` script cannot compile ANY script
# that references an autoload, which transitively covers most of the
# project (save_load.gd reads Game, world_time.gd is itself an autoload,
# and so on). So every project type below is resolved with a runtime
# load() instead of a compile-time class_name reference.
var _dim: GDScript = null
var _travel: GDScript = null
var _teleporter: GDScript = null
var _blocks: GDScript = null


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	_game = root.get_node("/root/Game")
	_game.set("active_world", _PROBE_WORLD)
	_dim = load("res://scripts/world/dimension_context.gd")
	_travel = load("res://scripts/world/portal_travel.gd")
	_teleporter = load("res://scripts/world/nether_teleporter.gd")
	_blocks = load("res://scripts/world/blocks.gd")
	_wipe_probe_world()
	root.add_child(load("res://main.tscn").instantiate())

	if not await _await_world_entry():
		_finish(1, "world never finished loading")
		return
	_diag("overworld")

	# Sanity gate: if injected input does not move the player in the
	# Overworld, the harness is broken and every result below is noise.
	if await _walk("overworld", 90) < _MOVED_THRESHOLD:
		_finish(1, "input injection dead in the Overworld — harness invalid")
		return

	var base: Vector3i = _build_portal_beside_player()
	print("[PROBE] portal built at %s" % str(base))
	if not await _await_dimension(_dim.NETHER, 1800):
		_diag("no-travel")
		_finish(1, "the exposure meter never fired travel")
		return
	if not await _await_arrival():
		_finish(1, "arrival never settled")
		return
	_diag("nether-arrival")

	# The bug that reached three playtests: arrival buried the capsule in
	# the frame floor, so input worked and displacement was exactly zero.
	if await _walk("nether", 240) < _MOVED_THRESHOLD:
		_dump_encasement()
		_finish(2, "FROZEN IN THE NETHER — cannot walk out of the arrival portal")
		return

	await _run_return_leg()


# The return trip: the seam no unit test and no successful playtest has
# ever covered. Split from _run so each stage stays readable.
func _run_return_leg() -> void:
	var cell: Variant = _find_portal_near(_player.global_position)
	if cell == null:
		_finish(3, "no portal cell near the arrival — the player cannot get home")
		return
	print("[PROBE] re-entering portal at %s" % str(cell))
	_player.global_position = Vector3(cell) + Vector3(0.5, 0.401, 0.5)
	if not await _await_dimension(_dim.OVERWORLD, 2400):
		_diag("stuck-in-nether")
		_finish(3, "never travelled back to the Overworld")
		return
	if not await _await_arrival():
		_finish(3, "return arrival never settled")
		return
	_diag("overworld-return")
	if await _walk("overworld-return", 180) < _MOVED_THRESHOLD:
		_dump_encasement()
		_finish(3, "FROZEN after returning to the Overworld")
		return
	_finish(0, "round trip complete — walked at every stage")


# --- stages ---


func _await_world_entry() -> bool:
	for _i: int in range(7200):
		await physics_frame
		if bool(_game.get("is_loading")):
			continue
		_player = root.find_child("Player", true, false) as CharacterBody3D
		_cm = root.find_child("ChunkManager", true, false)
		if _player != null and _cm != null:
			# Let the spawn settle passes finish before measuring.
			for _j: int in range(120):
				await physics_frame
			return true
	return false


func _await_dimension(target: int, frames: int) -> bool:
	for _i: int in range(frames):
		await physics_frame
		if _dim.active() == target:
			return true
	return false


func _await_arrival() -> bool:
	for _i: int in range(7200):
		await physics_frame
		if not bool(_game.get("is_loading")) and not _travel.in_progress():
			for _j: int in range(30):
				await physics_frame
			return true
	return false


# Try every direction and report the BEST horizontal displacement.
#
# One fixed direction is not a movement test, it is a geometry test: an
# arrival lands the player INSIDE the portal with an obsidian column a
# cell away, so "walk forward" can read 0.2 m simply because forward is
# a wall. The player's question is "can I move at all", and only the
# best of the four answers it. Vertical is ignored throughout: a player
# falling is not a player walking.
func _walk(tag: String, frames: int) -> float:
	var per_leg: int = maxi(30, frames / 4)
	var best: float = 0.0
	var best_dir: String = "none"
	for action: String in ["move_forward", "move_back", "move_left", "move_right"]:
		var start: Vector3 = _player.global_position
		Input.action_press(action)
		for _i: int in range(per_leg):
			await physics_frame
		Input.action_release(action)
		var moved: Vector3 = _player.global_position - start
		var horizontal: float = Vector2(moved.x, moved.z).length()
		if horizontal > best:
			best = horizontal
			best_dir = action
		# Settle so the next leg measures from rest rather than momentum.
		for _i: int in range(10):
			await physics_frame
	print("[WALK %s] best %.2f m (%s), %d frames per direction" % [tag, best, best_dir, per_leg])
	return best


func _build_portal_beside_player() -> Vector3i:
	var here := Vector3i(
		floori(_player.global_position.x),
		floori(_player.global_position.y),
		floori(_player.global_position.z)
	)
	var base: Vector3i = here + Vector3i(4, 0, 0)
	_teleporter._build_platform(_cm, base)
	_teleporter.build_frame(_cm, base)
	_player.global_position = Vector3(
		float(base.x) + 1.0, float(base.y) + 0.401, float(base.z) + 0.5
	)
	return base


func _find_portal_near(origin: Vector3) -> Variant:
	var centre := Vector3i(floori(origin.x), floori(origin.y), floori(origin.z))
	for radius: int in range(0, 12):
		for dx: int in range(-radius, radius + 1):
			for dy: int in range(-2, 4):
				for dz: int in range(-radius, radius + 1):
					var cell: Vector3i = centre + Vector3i(dx, dy, dz)
					if _cm.call("get_world_block", cell) == _blocks.PORTAL:
						return cell
	return null


# --- reporting ---


func _diag(tag: String) -> void:
	print(
		(
			"[DIAG %s] pos=%v vel=%v dim=%d loading=%s ui_open=%s move_vec=%v ground=%s floor=%s"
			% [
				tag,
				_player.global_position,
				_player.velocity,
				_dim.active(),
				str(_game.get("is_loading")),
				str(_player.call("_any_ui_screen_open")),
				_player.call("_move_vector"),
				str(_cm.call("is_ground_ready_at", _player.global_position)),
				str(_player.is_on_floor())
			]
		)
	)


# What is actually touching the capsule, and what the block data says
# should be there. A disagreement between the two is the signature of a
# chunk whose mesh and collision were never rebuilt after an edit.
func _dump_encasement() -> void:
	var pos: Vector3 = _player.global_position
	var feet := Vector3i(floori(pos.x), floori(pos.y), floori(pos.z))
	for dy: int in [0, 1]:
		for dx: int in range(-1, 2):
			for dz: int in range(-1, 2):
				var cell: Vector3i = feet + Vector3i(dx, dy, dz)
				var id: int = _cm.call("get_world_block", cell)
				if id != _blocks.AIR:
					print("[BLOCKS] %s = %d" % [str(cell), id])
	for child: Node in _player.get_children():
		if not child is CollisionShape3D:
			continue
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = (child as CollisionShape3D).shape
		query.transform = (child as CollisionShape3D).global_transform
		query.collision_mask = 0xFFFFFFFF
		for hit: Dictionary in _player.get_world_3d().direct_space_state.intersect_shape(query, 16):
			var collider: Object = hit.get("collider")
			if collider is Node and collider != _player:
				print("[OVERLAP] %s" % str((collider as Node).get_path()))
		break


func _finish(code: int, message: String) -> void:
	print("[PROBE %s] %s" % ["PASS" if code == 0 else "FAIL", message])
	_wipe_probe_world()
	quit(code)


# Remove the throwaway world directly rather than through SaveLoad,
# which cannot be compiled from this context (see _game). Scoped to the
# probe's own world name so a real save can never be the target.
func _wipe_probe_world() -> void:
	var path: String = "user://" + _PROBE_WORLD
	if not DirAccess.dir_exists_absolute(path):
		return
	var removed: int = OS.move_to_trash(ProjectSettings.globalize_path(path))
	if removed != OK:
		push_warning("[probe] could not remove %s" % path)
