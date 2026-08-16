class_name PlayerSave
extends RefCounted

# Per-world player state — step 7.4 of the save/load plan (see
# .claude/save-load-plan.md §4.6). Persists position, head rotation,
# health, and the full 45-slot inventory (hotbar + main + armor + craft
# grid + result) so quitting + relaunching resumes the player exactly
# where they were.
#
# On-disk layout:
#   user://<world>/player.bin
#
# Format (var_to_bytes blob with explicit header):
#   [4 bytes]  magic "MCAP"
#   [4 bytes]  u32 format_version = 1
#   [variable] var_to_bytes-serialized Dictionary {
#                pos: Vector3,
#                yaw: float, pitch: float,    -- head rotation only
#                health: int,
#                hotbar_selected: int,
#                inventory: Array[Array[3 ints]]
#                              -- per slot: [item_id, count, damage]
#              }
#
# Fire / lava state IS persisted — vanilla MC stores `fireTicks` in
# the player NBT so saving mid-burn picks up where it left off on
# reload. Without this, saving while on fire effectively extinguished
# the timer (a free-escape exploit), even though health damage from
# the same burn was preserved. The 4 fields below cover the active
# timer, the per-second damage accumulator, the in-lava edge flag (so
# we don't double-emit the lava-entry fizz on the first frame post-
# load), and the lava damage accumulator.
#
# Transient fields skipped on save (rebuilt fresh on load):
#   velocity, _fall_peak_y, all mining/swing state, creative_mode,
#   perspective. These either reset cleanly or are debug toggles a
#   saved load shouldn't pick up across sessions.
#
# Vec3i spawn point lives in world.json (it's per-world, not per-player —
# beds in §2.10 of pre-mob-roadmap will move it to per-player later).

const _MAGIC_BYTES: Array[int] = [0x4D, 0x43, 0x41, 0x50]  # "MCAP"
# v2 (Nether, Batch 1) adds "dimension" to the payload. v1 saves are read
# unchanged and migrate to dimension 0 in memory — nothing on disk is
# rewritten until the player's next save, so opening an old world and
# quitting without playing leaves its bytes alone.
const _FORMAT_VERSION: int = 2
const _VERSION_WITHOUT_DIMENSION: int = 1
const _SUPPORTED_VERSIONS: Array[int] = [1, 2]
const _HEADER_SIZE: int = 8

# "MCAP" magic — same const-expression workaround as the other persistence modules.
static var _magic: PackedByteArray = PackedByteArray(_MAGIC_BYTES)

# --- Path ---


static func player_path(world_name: String = "") -> String:
	return "%s/player.bin" % SaveLoad.world_dir(world_name)


# Lightweight read of just the saved XZ — used by ChunkManager._ready so
# initial chunks spawn around where the player will teleport to (instead
# of (0,0)). Without this, a saved player far from origin lands in
# unloaded space the moment _apply_payload runs and falls through. Y is
# ignored because chunk selection is XZ-only; out-of-bounds Y is fixed up
# separately in _apply_payload. Returns null on missing or malformed.
static func peek_position(world_name: String = "") -> Variant:
	var d: Dictionary = _peek_payload(world_name)
	if not d.has("pos"):
		return null
	return d["pos"] as Vector3


# Which dimension the player was last in. ChunkManager._ready needs this
# BEFORE it builds the initial chunk ring — otherwise a player saved in
# the Nether has an Overworld ring generated around them, and the chunks
# they actually land in arrive late (the same class of bug peek_position
# exists to prevent).
#
# Returns dimension 0 for v1 saves, for a fresh world, and for anything
# unreadable: the Overworld is the only safe place to put a player whose
# save we cannot interpret.
static func peek_dimension(world_name: String = "") -> int:
	var d: Dictionary = _peek_payload(world_name)
	return _dimension_from_payload(d)


# Shared decode for the two peek helpers. Returns {} when the file is
# missing, truncated, wrong-magic, or written by a version this build
# does not understand.
static func _peek_payload(world_name: String) -> Dictionary:
	var path: String = player_path(world_name)
	var bytes: PackedByteArray = SaveLoad.read_with_recovery(path)
	if bytes.size() < _HEADER_SIZE:
		return {}
	if bytes.slice(0, 4) != _magic:
		return {}
	if not _SUPPORTED_VERSIONS.has(int(bytes.decode_u32(4))):
		return {}
	var parsed: Variant = bytes_to_var(bytes.slice(_HEADER_SIZE, bytes.size()))
	if not parsed is Dictionary:
		return {}
	return parsed as Dictionary


# The v1 -> v2 migration, such as it is: a payload with no "dimension"
# key was written before the Nether existed, so its player was in the
# Overworld by definition. An unregistered id is treated the same way
# rather than trusted, so a save hand-edited to dimension 7 cannot strand
# the player in a world with no provider.
static func _dimension_from_payload(payload: Dictionary) -> int:
	if not payload.has("dimension"):
		return DimensionContext.OVERWORLD
	var dim: int = int(payload["dimension"])
	if not DimensionContext.is_registered(dim):
		push_warning("[PlayerSave] unknown dimension %d in save; falling back to Overworld" % dim)
		return DimensionContext.OVERWORLD
	return dim


# --- Save ---


# Snapshot the player's persistent state and write it to disk. Returns
# true on success.
static func save_player(player: Node3D, world_name: String = "") -> bool:
	if player == null:
		return false
	_ensure_world_dir(world_name)
	var payload: Dictionary = _build_payload(player)
	var body: PackedByteArray = var_to_bytes(payload)
	return SaveLoad.pack_and_write(player_path(world_name), _magic, _FORMAT_VERSION, body)


static func _build_payload(player: Node3D) -> Dictionary:
	var inv: Inventory = player.get("inventory") as Inventory
	var slots_out: Array = []
	if inv != null:
		slots_out.resize(Inventory.TOTAL_SIZE)
		for i in range(Inventory.TOTAL_SIZE):
			var stack: ItemStack = inv.slots[i]
			if stack == null:
				slots_out[i] = [0, 0, 0]
			else:
				slots_out[i] = [stack.item_id, stack.count, stack.damage]
	# Camera pitch lives on the player's "Camera3D" child (see player.gd's
	# _apply_mouse_motion + the @onready _camera). Yaw is on the player
	# Node3D itself (rotate_y in _apply_mouse_motion).
	var camera: Camera3D = player.get_node_or_null("Camera3D") as Camera3D
	var yaw: float = player.rotation.y
	var pitch: float = camera.rotation.x if camera != null else 0.0
	# Bed-respawn point — vanilla `EntityPlayer.spawnX/Y/Z + spawnSet`.
	# Optional fields; default to no-bed-spawn on first save and on
	# loads from older format-version-1 files (Dictionary.get with a
	# missing key returns the default we pass).
	var bed_spawn_pos: Vector3 = (
		player.get("bed_spawn_pos") as Vector3 if "bed_spawn_pos" in player else Vector3.ZERO
	)
	var has_bed_spawn: bool = (
		bool(player.get("has_bed_spawn")) if "has_bed_spawn" in player else false
	)
	# Fire + lava state — vanilla MC persists fireTicks (and the
	# adjacent lava-contact accumulator). Without these, a save during
	# a burn extinguishes the timer on reload while health damage
	# stays — an inconsistency + a free escape exploit. Default 0/false
	# fallbacks below let saves predating this field load cleanly.
	var fire_remaining_sec: float = (
		float(player.get("_fire_remaining_sec")) if "_fire_remaining_sec" in player else 0.0
	)
	var fire_burn_tick: float = (
		float(player.get("_fire_burn_tick")) if "_fire_burn_tick" in player else 0.0
	)
	var was_in_lava: bool = bool(player.get("_was_in_lava")) if "_was_in_lava" in player else false
	var lava_tick: float = float(player.get("_lava_tick")) if "_lava_tick" in player else 0.0
	# Death snapshot guard. If autosave (or quit-to-title) fires while the
	# death screen is showing, the raw snapshot captures health=0 + an
	# active fire timer; the next world load then drops the player into
	# "dead, still on fire" before they can respawn. Sanitize: write a
	# fresh-respawn snapshot pinned to the bed/world spawn instead. Cheap
	# defensive guard — should never fire on a normal session, but
	# recovers gracefully if it does.
	var health_now: int = int(player.get("health")) if "health" in player else 20
	var dying: bool = bool(player.get("_dying")) if "_dying" in player else false
	if health_now <= 0 or dying:
		var respawn_pos: Vector3
		if has_bed_spawn:
			respawn_pos = bed_spawn_pos
		else:
			var meta: Dictionary = WorldMeta.load_meta()
			var spawn_dict: Dictionary = meta.get("spawn", {}) as Dictionary
			respawn_pos = Vector3(
				float(spawn_dict.get("x", 8.0)),
				float(spawn_dict.get("y", 100.0)),
				float(spawn_dict.get("z", 8.0))
			)
		return {
			"pos": respawn_pos,
			"yaw": 0.0,
			"pitch": 0.0,
			"health": 20,
			"hotbar_selected": inv.selected_slot if inv != null else 0,
			"inventory": slots_out,
			"bed_spawn_pos": bed_spawn_pos,
			"has_bed_spawn": has_bed_spawn,
			"fire_remaining_sec": 0.0,
			"fire_burn_tick": 0.0,
			"was_in_lava": false,
			"lava_tick": 0.0,
		}
	return {
		"pos": player.global_position,
		# v2: which dimension this position belongs to. Written from the
		# resident dimension rather than anything on the player, because
		# DimensionContext is the single authority on what is loaded.
		"dimension": DimensionContext.active(),
		"yaw": yaw,
		"pitch": pitch,
		"health": health_now,
		"hotbar_selected": inv.selected_slot if inv != null else 0,
		"inventory": slots_out,
		"bed_spawn_pos": bed_spawn_pos,
		"has_bed_spawn": has_bed_spawn,
		"fire_remaining_sec": fire_remaining_sec,
		"fire_burn_tick": fire_burn_tick,
		"was_in_lava": was_in_lava,
		"lava_tick": lava_tick,
	}


# --- Load ---


# Restore the player from disk. Mutates the passed Node3D in-place.
# Returns true on success, false on missing/malformed file (leaves the
# player at its default-spawn position so the caller can detect fresh
# worlds with player_save.load_player(...) == false).
static func load_player(player: Node3D, world_name: String = "") -> bool:
	if player == null:
		return false
	var path: String = player_path(world_name)
	# Crash-recovery aware read via SaveLoad.read_with_recovery (same
	# .new/.old fallback the region loader uses).
	var bytes: PackedByteArray = SaveLoad.read_with_recovery(path)
	if bytes.is_empty():
		return false
	if bytes.size() < _HEADER_SIZE:
		push_warning("[PlayerSave] %s shorter than header" % path)
		return false
	if bytes.slice(0, 4) != _magic:
		push_warning("[PlayerSave] %s: bad magic, skipping" % path)
		return false
	var version: int = bytes.decode_u32(4)
	if not _SUPPORTED_VERSIONS.has(version):
		push_warning("[PlayerSave] %s: unknown format_version=%d, skipping" % [path, version])
		return false
	var body: PackedByteArray = bytes.slice(_HEADER_SIZE, bytes.size())
	var parsed: Variant = bytes_to_var(body)
	if not parsed is Dictionary:
		push_warning("[PlayerSave] %s: payload not Dictionary, skipping" % path)
		return false
	_apply_payload(player, parsed as Dictionary)
	return true


static func _apply_payload(player: Node3D, payload: Dictionary) -> void:
	# Dimension first: the Y-clamp below consults world spawn metadata,
	# and every later system that asks "where am I?" needs the right
	# answer. ChunkManager has already peeked this to centre the initial
	# chunk ring; setting it again here is what makes a direct
	# load_player call (tests, future respawn paths) self-contained.
	DimensionContext.set_active(_dimension_from_payload(payload))
	# Sanitize saved Y. The autosave loop persists position unconditionally,
	# so if the player ever falls into open space (e.g. a chunk-load race
	# at world entry, or a creative-mode void plunge) the disk Y can land
	# arbitrarily far below the world (y=-2727 seen in the wild). Clamp
	# any Y outside the world's vertical range back to the world spawn
	# altitude (or 100 if no spawn metadata yet) so the player respawns
	# above terrain instead of falling forever again on reload.
	var saved_pos: Vector3 = payload.get("pos", Vector3.ZERO) as Vector3
	if saved_pos.y < 1.0 or saved_pos.y > 127.0:
		var meta: Dictionary = WorldMeta.load_meta()
		var spawn_y: float = 100.0
		if not meta.is_empty():
			var spawn_dict: Dictionary = meta.get("spawn", {}) as Dictionary
			spawn_y = float(spawn_dict.get("y", 100.0))
		var msg: String = (
			"[PlayerSave] saved Y=%.1f out of world bounds; restoring to spawn altitude %.1f"
			% [saved_pos.y, spawn_y]
		)
		push_warning(msg)
		saved_pos.y = maxf(spawn_y, 64.0)
	# Route through `Player.safe_teleport` so the 3×3 chunk neighborhood
	# around the saved coord is sync-loaded before the capsule lands.
	# Otherwise the player drops through unloaded space into the void
	# before per-frame streaming catches up — see `safe_teleport` docs.
	if player.has_method("safe_teleport"):
		player.call("safe_teleport", saved_pos)
	else:
		player.global_position = saved_pos
	player.rotation.y = float(payload.get("yaw", 0.0))
	var camera: Camera3D = player.get_node_or_null("Camera3D") as Camera3D
	if camera != null:
		camera.rotation.x = float(payload.get("pitch", 0.0))
	if "health" in player:
		player.set("health", int(payload.get("health", 20)))
	# Bed-respawn restore — defaults preserve the no-bed-spawn state for
	# saves written before bed support landed (format_version 1 saves
	# don't have these keys; Dictionary.get falls back to the defaults).
	if "bed_spawn_pos" in player:
		player.set("bed_spawn_pos", payload.get("bed_spawn_pos", Vector3.ZERO))
	if "has_bed_spawn" in player:
		player.set("has_bed_spawn", bool(payload.get("has_bed_spawn", false)))
	# Fire + lava state restore. Missing keys → 0 / false (the same
	# defaults the Player node initializes to), so older saves load
	# cleanly with no fire active. Saves written mid-burn put the
	# player back on fire with the timer where they left off.
	if "_fire_remaining_sec" in player:
		player.set("_fire_remaining_sec", float(payload.get("fire_remaining_sec", 0.0)))
	if "_fire_burn_tick" in player:
		player.set("_fire_burn_tick", float(payload.get("fire_burn_tick", 0.0)))
	if "_was_in_lava" in player:
		player.set("_was_in_lava", bool(payload.get("was_in_lava", false)))
	if "_lava_tick" in player:
		player.set("_lava_tick", float(payload.get("lava_tick", 0.0)))
	var inv: Inventory = player.get("inventory") as Inventory
	if inv != null:
		var slots_in: Array = payload.get("inventory", []) as Array
		for i in range(min(slots_in.size(), Inventory.TOTAL_SIZE)):
			var entry: Array = slots_in[i]
			var stack := ItemStack.new(int(entry[0]), int(entry[1]))
			stack.damage = int(entry[2])
			inv.slots[i] = stack
		inv.selected_slot = int(payload.get("hotbar_selected", 0))
		# Direct slot mutation bypasses Inventory's normal setters, which
		# would emit `changed` themselves. Emit once here so subscribers
		# (hotbar UI, held-item mesh, armor overlay) repaint after load.
		inv.changed.emit()


# --- Cleanup ---


static func delete_player_file(world_name: String = "") -> bool:
	var path: String = player_path(world_name)
	if not FileAccess.file_exists(path):
		return true
	return DirAccess.remove_absolute(path) == OK


static func _ensure_world_dir(world_name: String) -> void:
	var path: String = SaveLoad.world_dir(world_name)
	if DirAccess.dir_exists_absolute(path):
		return
	DirAccess.make_dir_recursive_absolute(path)
